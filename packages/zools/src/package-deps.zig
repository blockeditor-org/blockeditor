// bundle types:

const std = @import("std");

const DependencyId = enum(usize) { _ };

// stages:
// 1. explore and parse zon files:
//     - abs_path -> exists?
//     - dependency_id -> bzz
// 2. sort in dependency order:
//     - dependency_id[]
//     - dependency_id -> bzz
//     - dependency_id -> enum{no, cyclic, yes}
//     + ideally we will produce an order that allows us to do as much concurrently as possible:
//        - this means producing an array of just those dependencies with no dependencies themselves
// 3. emit
//     - dependency_order[]
//     - dependency_id -> bzz
//     + in a thread pool? dependency_id -> atomic(ready_count: u32)
//     + dependency_id -> dependents[]
//     + on completion, decrement ready counts of everything that depends on us and append the task

const DepQueue = struct {
    gpa: std.mem.Allocator,
    dependency_abspath_to_zon: std.StringArrayHashMapUnmanaged(BuildZigZonParseResult) = .empty,
    finalized: bool = false,

    pub fn addAbsolutePath(self: *DepQueue, path: []const u8) !DependencyId {
        std.debug.assert(!self.finalized);
        const gpres = try self.dependency_abspath_to_zon.getOrPut(self.gpa, path);
        if (!gpres.found_existing) {
            gpres.value_ptr.* = undefined;
            gpres.value_ptr.defined = false;
        }
        return @enumFromInt(gpres.index);
    }
    pub fn getAbsolutePath(self: *DepQueue, id: DependencyId) []const u8 {
        return self.dependency_abspath_to_zon.keys()[@intFromEnum(id)];
    }
    pub fn getZon(self: *DepQueue, id: DependencyId) *BuildZigZonParseResult {
        return &self.dependency_abspath_to_zon.values()[@intFromEnum(id)];
    }
    pub fn setZon(self: *DepQueue, id: DependencyId, value: BuildZigZonParseResult) void {
        const ptr = &self.dependency_abspath_to_zon.values()[@intFromEnum(id)];
        std.debug.assert(!ptr.defined); // tried to overwrite package zon
        std.debug.assert(value.defined);
        ptr.* = value;
    }
    pub fn len(self: *DepQueue) usize {
        return self.dependency_abspath_to_zon.keys().len;
    }

    pub fn deinit(self: *DepQueue) void {
        for (self.dependency_abspath_to_zon.values()) |*item| if (item.defined) item.deinit();
        self.dependency_abspath_to_zon.deinit(self.gpa);
    }

    pub fn finalize(self: *DepQueue) !DepList {
        // 1. ensure fully completed
        for (self.dependency_abspath_to_zon.values()) |*bzz| {
            if (!bzz.defined) {
                return error.Errored;
            }
        }

        var dependents_count: TypesafeSlice(DependencyId, usize) = try .alloc(self.gpa, self.len());
        defer dependents_count.free(self.gpa);
        dependents_count.memset(0);

        var root_dependencies: usize = 0;
        var dependents_total: usize = 0;

        for (self.dependency_abspath_to_zon.values()) |*bzz| {
            for (bzz.dependencies.keys()) |dep| {
                dependents_count.ptr(dep).* += 1;
                dependents_total += 1;
            }
            if (bzz.dependencies.count() == 0) {
                root_dependencies += 1;
                dependents_total += 1;
            }
        }

        const dependents = try self.gpa.alloc(DependencyId, dependents_total);
        errdefer self.gpa.free(dependents);

        var running_total = root_dependencies;
        for (self.dependency_abspath_to_zon.values(), 0..) |*bzz, i| {
            const dep_id: DependencyId = @enumFromInt(i);
            bzz.dependents.start = running_total;
            running_total += dependents_count.get(dep_id);
        }

        var root: TypesafeSlice(DependentsListIndex, DependencyId).Subslice = .{ .start = 0, .len = 0 };
        for (self.dependency_abspath_to_zon.values(), 0..) |*bzz, i| {
            const dependent_id: DependencyId = @enumFromInt(i);
            if (bzz.dependencies.keys().len == 0) {
                dependents[root.start + root.len] = dependent_id;
                root.len += 1;
            } else for (bzz.dependencies.keys()) |dependency_id| {
                const zon = self.getZon(dependency_id);
                dependents[zon.dependents.start + zon.dependents.len] = dependent_id;
                zon.dependents.len += 1;
            }
        }

        var dependencies_count: TypesafeSlice(DependencyId, std.atomic.Value(usize)) = try .alloc(self.gpa, self.len());
        errdefer dependencies_count.free(self.gpa);
        for (self.dependency_abspath_to_zon.values(), dependencies_count.value) |*bzz, *dc| {
            dc.* = .init(bzz.dependencies.count());
        }

        std.debug.assert(!self.finalized);
        self.finalized = true;

        return .{
            .gpa = self.gpa,
            .dependents = .wrap(dependents),
            .dependencies_count = dependencies_count,
            .root_dependencies = root,
            .abspaths = .wrap(self.dependency_abspath_to_zon.keys()),
            .bzzs = .wrap(self.dependency_abspath_to_zon.values()),
        };
    }
};
const DependentsListIndex = enum(u32) { _ };
const DepList = struct {
    gpa: std.mem.Allocator,
    dependents: TypesafeSlice(DependentsListIndex, DependencyId),
    dependencies_count: TypesafeSlice(DependencyId, std.atomic.Value(usize)), // when you decrement this to 0, spawn a new task
    root_dependencies: TypesafeSlice(DependentsListIndex, DependencyId).Subslice,
    abspaths: TypesafeSlice(DependencyId, []const u8),
    bzzs: TypesafeSlice(DependencyId, BuildZigZonParseResult), // interestingly, these are already known to not be null

    pub fn deinit(self: *DepList) void {
        self.dependents.free(self.gpa);
        self.dependencies_count.free(self.gpa);
    }
};

pub const options: std.Options = .{ .log_level = .debug };

pub fn printError(comptime msg: []const u8, args: anytype) error{Errored} {
    std.log.err(msg, args);
    return error.Errored;
}

const Opts = struct {
    src_pkgs: []const []const u8,
    zig_bin: []const u8,
    dst_dir: []const u8,
    url_prefix: []const u8,
    include_global_packages: bool,
    override_global_packages_dir: ?[]const u8,
    mode: Mode,

    const Mode = enum { multi_file, single_file };

    pub fn deinit(self: *Opts, gpa: std.mem.Allocator) void {
        gpa.free(self.src_pkgs);
    }
    pub fn parse(gpa: std.mem.Allocator, args: []const []const u8) !Opts {
        const usage =
            \\Usage:
            \\  zig run package-deps.zig -- ...args
            \\
            \\Example:
            \\  zig run package-deps.zig -- --src-dir=. --zig-bin=zig --dst-dir=dst --url-prefix=https://github.com/org/repo/releases/tag/release-id/
            \\
            \\Flags:
            \\  --src-pkg=[src_dir]  / specifies the source directory to search for packages.
            \\                                 you may specify multiple by repeating this flag.
            \\  --zig-bin=[zig_bin]  / specifies the path to the zig 
        ++ @import("builtin").zig_version_string ++
            \\ binary on the system
            \\  --include-global-packages  / specifies that packages in the global package cache should be included
            \\  --include-global-packages=[dir]  / manually specify global package dir
            \\
            \\For multi-file output:
            \\  --dst-dir=[dst]  / specifies the output folder. will non-recursively create if it does not exist.
            \\  --url-prefix=[url-prefix]  / specifies the 
            \\
            \\For single-file output:
            \\  --dst-file=[file].tar  / specifies the output file
        ;
        var src_pkgs: std.ArrayList([]const u8) = .empty;
        defer src_pkgs.deinit(gpa);
        var zig_bin_opt: ?[]const u8 = null;
        var dst_dir_opt: ?[]const u8 = null;
        var url_prefix_opt: ?[]const u8 = null;
        var include_global_packages = false;
        var override_global_packages_dir: ?[]const u8 = null;
        for (args[1..]) |arg| {
            if (std.mem.startsWith(u8, arg, "--src-pkg=")) {
                try src_pkgs.append(gpa, arg["--src-pkg=".len..]);
            } else if (std.mem.startsWith(u8, arg, "--zig-bin=")) {
                zig_bin_opt = arg["--zig-bin=".len..];
            } else if (std.mem.startsWith(u8, arg, "--dst-dir=")) {
                dst_dir_opt = arg["--dst-dir=".len..];
            } else if (std.mem.startsWith(u8, arg, "--url-prefix=")) {
                url_prefix_opt = arg["--url-prefix=".len..];
            } else if (std.mem.startsWith(u8, arg, "--dst-file")) {
                return printError("todo implement single-file output mode", .{});
            } else if (std.mem.eql(u8, arg, "--include-global-packages")) {
                include_global_packages = true;
            } else if (std.mem.startsWith(u8, arg, "--include-global-packages=")) {
                include_global_packages = true;
                override_global_packages_dir = arg["--include-global-packages=".len..];
            } else {
                return printError("unexpected arg \"{f}\". usage:\n{s}", .{ std.zig.fmtString(arg), usage });
            }
        }

        if (src_pkgs.items.len == 0) {
            return printError("missing --src-pkg, usage:\n{s}", .{usage});
        }
        const zig_arg = zig_bin_opt orelse {
            return printError("missing --zig-bin, usage:\n{s}", .{usage});
        };
        const dst_dir = dst_dir_opt orelse {
            return printError("missing --dst-dir, usage:\n{s}", .{usage});
        };
        const url_prefix = url_prefix_opt orelse {
            return printError("missing --url-prefix, usage:\n{s}", .{usage});
        };
        const mode: Mode = .multi_file;

        const src_pkgs_owned = try src_pkgs.toOwnedSlice(gpa);
        errdefer gpa.free(src_pkgs_owned);

        return .{
            .src_pkgs = src_pkgs_owned,
            .zig_bin = zig_arg,
            .dst_dir = dst_dir,
            .url_prefix = url_prefix,
            .include_global_packages = include_global_packages,
            .override_global_packages_dir = override_global_packages_dir,
            .mode = mode,
        };
    }
};

pub fn exec(gpa: std.mem.Allocator, progress: std.Progress.Node, args: []const []const u8) ![:0]const u8 {
    var zig_env_proc = std.process.Child.init(args, gpa);
    zig_env_proc.stdout_behavior = .Pipe;
    zig_env_proc.progress_node = progress;
    try zig_env_proc.spawn();
    const zig_env_output = try zig_env_proc.stdout.?.readToEndAllocOptions(gpa, std.math.maxInt(usize), null, .of(u8), 0);
    errdefer gpa.free(zig_env_output);
    const zig_env_proc_term = try zig_env_proc.wait();
    if (zig_env_proc_term != .Exited or zig_env_proc_term.Exited != 0) {
        return printError("zig_env_proc_term {any}", .{zig_env_proc_term});
    }
    return zig_env_output;
}

pub fn main() !u8 {
    var gpa_backing = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa_backing.deinit() == .ok);
    const gpa = gpa_backing.allocator();
    var arena_backing = std.heap.ArenaAllocator.init(gpa);
    defer arena_backing.deinit();
    const arena = arena_backing.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var opts = try Opts.parse(gpa, args);
    defer opts.deinit(gpa);

    var progress = std.Progress.start(.{});
    defer progress.end();

    const zig_env_output = try exec(gpa, progress, &.{ opts.zig_bin, "env" });
    defer gpa.free(zig_env_output);

    const zig_env_parsed = try std.zon.parse.fromSlice(struct {
        global_cache_dir: []const u8,
        version: []const u8,
    }, arena, zig_env_output, null, .{ .free_on_error = false, .ignore_unknown_fields = true });
    if (!std.mem.eql(u8, zig_env_parsed.version, @import("builtin").zig_version_string)) {
        return printError("expected zig version {s}, got version {s}", .{ @import("builtin").zig_version_string, zig_env_parsed.version });
    }

    var deps: DepQueue = .{ .gpa = gpa };
    defer deps.deinit();

    {
        const find_root = progress.start("find_root", opts.src_pkgs.len);
        defer find_root.end();

        for (opts.src_pkgs) |src_pkg| {
            const find_one_root = find_root.start(src_pkg, 0);
            defer find_one_root.end();

            const fullpath = try std.fs.cwd().realpathAlloc(arena, src_pkg);
            _ = try deps.addAbsolutePath(fullpath);
        }
    }
    var has_error = false;

    {
        const queue_node = progress.start("explore", deps.dependency_abspath_to_zon.keys().len);
        defer queue_node.end();
        var queue_idx: usize = 0;
        while (queue_idx < deps.len()) : (queue_idx += 1) {
            const package_abs_path = deps.getAbsolutePath(@enumFromInt(queue_idx));
            const queue_sub_node = queue_node.start(package_abs_path, 0);
            defer queue_sub_node.end();

            parseBuildZigZon(gpa, arena, @enumFromInt(queue_idx), &deps, if (opts.include_global_packages) opts.override_global_packages_dir orelse zig_env_parsed.global_cache_dir else null) catch |e| {
                has_error = true;
                std.log.err("{s}: error: {s}", .{ package_abs_path, @errorName(e) });
                continue;
            };
        }
    }

    var df = try deps.finalize();
    defer df.deinit();

    std.fs.cwd().makeDir(".zig-cache") catch {};
    std.fs.cwd().makeDir(".zig-cache/tmp") catch {};
    const tmp_global_cache_dir_name = ".zig-cache/tmp/package-deps-" ++ std.fmt.hex(std.crypto.random.int(u64));
    std.fs.cwd().makeDir(tmp_global_cache_dir_name) catch {};
    std.fs.cwd().makeDir(opts.dst_dir) catch {};

    // now, we loop over each dependency
    // for each dependency we will generate a tar.gz file for it and we will rerender its build.zig.zon and then we will generate its hash and save that
    {
        const generate_output_node = progress.start("generate output", df.abspaths.len());
        defer generate_output_node.end();

        var generate_queue: std.ArrayList(DependencyId) = try .initCapacity(gpa, df.bzzs.len());
        defer generate_queue.deinit(gpa);
        var generate_queue_index: usize = 0;

        generate_queue.appendSliceAssumeCapacity(df.root_dependencies.view(&df.dependents));

        while (generate_queue_index < generate_queue.items.len) : (generate_queue_index += 1) {
            const dep = generate_queue.items[generate_queue_index];
            try emitFile(dep, &df, generate_output_node, gpa, &has_error, &opts, tmp_global_cache_dir_name, &generate_queue);
        }
    }

    if (has_error) return 1;
    return 0;
}

fn emitFile(dep: DependencyId, df: *DepList, generate_output_node: std.Progress.Node, gpa: std.mem.Allocator, has_error: *bool, opts: *const Opts, tmp_global_cache_dir_name: []const u8, generate_queue: *std.ArrayList(DependencyId)) !void {
    const dep_abspath = df.abspaths.get(dep);
    const render_dep_node = generate_output_node.start(dep_abspath, 4);
    defer render_dep_node.end();

    const dep_bzz = df.bzzs.ptr(dep);

    // so we will iterate over all the files in the paths
    // exluding exclude_paths
    // modifying the root build.zig.zon to update urls
    // and at each file we will write it to the tar writer
    // -> which will write to an xz writer (std.compress.flate)
    // -> which will write to the output file

    const rand_int = std.crypto.random.int(u64);
    const tmp_name = ".zig-cache/tmp/package-deps-" ++ std.fmt.hex(rand_int) ++ ".tar";
    {
        var out_file = try std.fs.cwd().createFile(tmp_name, .{});
        defer out_file.close();
        var out_file_buf: [1024]u8 = undefined;
        var out_file_writer = out_file.writer(&out_file_buf);

        if (comptime !std.mem.eql(u8, @import("builtin").zig_version_string, "0.15.2")) {
            // TODO: enable compression. it looks like it will be in 0.16.0:
            // https://codeberg.org/ziglang/zig/src/commit/56253d9e31c0576f024d95929a8fe26428b35176/lib/std/compress/flate/Compress.zig
            // in 0.15.0, it doesn't work: https://github.com/ziglang/zig/issues/24973
            @compileError("TODO: enable compression");
        }

        var tar: std.tar.Writer = .{ .underlying_writer = &out_file_writer.interface };

        var seen_paths: std.StringArrayHashMapUnmanaged(void) = .empty;
        defer seen_paths.deinit(gpa);
        defer for (seen_paths.keys()) |key| gpa.free(key);
        {
            const walk_dir_node = render_dep_node.start("walk dirs", dep_bzz.paths.len);
            defer walk_dir_node.end();
            for (dep_bzz.paths) |path| {
                const walk_path_node = walk_dir_node.start(path, path.len);
                defer walk_path_node.end();
                walkDir(df.abspaths.get(dep), path, &seen_paths, gpa) catch |e| switch (e) {
                    else => |ee| {
                        std.log.err("failed to check path {s} / {s}", .{ path, @errorName(ee) });
                        has_error.* = true;
                        continue;
                    },
                };
            }
        }
        std.mem.sort([]const u8, seen_paths.keys(), {}, lessThanString);

        const write_tar_node = render_dep_node.start("write tar", seen_paths.keys().len);
        defer write_tar_node.end();
        for (seen_paths.keys()) |file_path| {
            const sub_tar_node = write_tar_node.start(file_path, 0);
            defer sub_tar_node.end();

            const fullpath = try std.fs.path.join(gpa, &.{ df.abspaths.get(dep), file_path });
            defer gpa.free(fullpath);

            if (std.mem.eql(u8, file_path, "build.zig.zon")) {
                // write build.zig.zon
                const rendered = try renderBuildZigZon(gpa, dep_bzz, df);
                defer gpa.free(rendered);
                try tar.writeFileBytes("build.zig.zon", rendered, .{});
            } else {
                // now we will write the file
                var file = try std.fs.openFileAbsolute(fullpath, .{ .mode = .read_only });
                defer file.close();
                var reader_buf: [1024]u8 = undefined;
                var file_reader = file.reader(&reader_buf);
                // note: not using writeFile so we don't copy mtime and such
                // TODO: save +x permission
                try tar.writeFileStream(file_path, try file_reader.getSize(), &file_reader.interface, .{});
            }
        }

        // finally, write build.zig.zon

        try tar.finishPedantically();
        try out_file_writer.interface.flush();
    }

    // now that we have written the file, use the zig compiler to determine the hash of the package
    // (maybe using --debug-hash? maybe not)

    const find_hash_node = render_dep_node.start("find hash", 0);
    defer find_hash_node.end();

    var result_package_info_writer: std.Io.Writer.Allocating = .init(dep_bzz.gpa);
    defer result_package_info_writer.deinit();
    switch (opts.mode) {
        .single_file => @panic("TODO for single file we need to decide a name and stuff. path=../name"),
        .multi_file => {
            const hash_result = try exec(gpa, find_hash_node, &.{ opts.zig_bin, "fetch", "--global-cache-dir", tmp_global_cache_dir_name, tmp_name });
            defer gpa.free(hash_result);
            const found_hash = std.mem.trim(u8, hash_result, " \r\n\t");
            const found_filename = try std.fmt.allocPrint(gpa, "{s}.tar", .{found_hash});
            defer gpa.free(found_filename);

            const rendered_url = try std.fmt.allocPrint(gpa, "{s}{s}", .{ opts.url_prefix, found_filename });
            defer gpa.free(rendered_url);
            const rendered_path = try std.fs.path.join(gpa, &.{ opts.dst_dir, found_filename });
            defer gpa.free(rendered_path);

            // write to the package info
            try std.zon.stringify.serialize(.{
                .url = rendered_url,
                .hash = found_hash,
            }, .{}, &result_package_info_writer.writer);

            // move the file
            try std.fs.cwd().rename(tmp_name, rendered_path);
        },
    }
    dep_bzz.generated_zon = try result_package_info_writer.toOwnedSlice();

    // enqueue dependents
    for (dep_bzz.dependents.view(&df.dependents)) |dependent| {
        const dec = df.dependencies_count.ptr(dependent).fetchSub(1, .acq_rel);
        if (dec == 1) { // 1 means we decremented to 0
            generate_queue.appendAssumeCapacity(dependent);
        }
    }
}

fn renderBuildZigZon(gpa: std.mem.Allocator, dep_bzz: *BuildZigZonParseResult, df: *DepList) ![]const u8 {
    if (dep_bzz.ast == null) {
        // uh oh! somehow there's no ast but there is a build.zig.zon file
        std.log.err("no ast but yes build.zig.zon file? how can this happen?", .{});
        return error.Errored;
    }

    var replace_nodes_with_string = std.AutoHashMapUnmanaged(std.zig.Ast.Node.Index, []const u8).empty;
    defer replace_nodes_with_string.deinit(gpa);

    // iterate over dependencies, rerender
    for (dep_bzz.dependencies.keys(), dep_bzz.dependencies.values()) |dep_id, node_idx| {
        const other_bzz = df.bzzs.get(dep_id);
        if (other_bzz.generated_zon == null) {
            @panic("it should have been generated by now");
        }
        try replace_nodes_with_string.putNoClobber(gpa, node_idx, other_bzz.generated_zon.?);
    }

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try dep_bzz.ast.?.render(gpa, &out.writer, .{
        .replace_nodes_with_string = replace_nodes_with_string,
    });
    return out.toOwnedSlice();
}

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn walkDir(abs_root: []const u8, sub_path: []const u8, paths: *std.StringArrayHashMapUnmanaged(void), gpa: std.mem.Allocator) !void {
    const fullpath = try std.fs.path.join(gpa, &.{ abs_root, sub_path });
    defer gpa.free(fullpath);

    var pathdir = std.fs.openDirAbsolute(fullpath, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return,
        error.NotDir => {
            const gpres = try paths.getOrPut(gpa, sub_path);
            if (!gpres.found_existing) {
                gpres.key_ptr.* = try gpa.dupe(u8, sub_path);
                gpres.value_ptr.* = {};
            }
            return;
        },
        else => |ee| {
            std.log.err("failed to check path {s} / {s}", .{ sub_path, @errorName(ee) });
            return ee;
        },
    };
    defer pathdir.close();

    var iter = pathdir.iterate();
    while (try iter.next()) |entry| {
        if (exclude_paths.get(entry.name) != null) {
            continue; // skip dir
        }
        const new_sub = try std.fs.path.join(gpa, &.{ sub_path, entry.name });
        defer gpa.free(new_sub);
        switch (entry.kind) {
            .file => {
                const gpres = try paths.getOrPut(gpa, new_sub);
                if (!gpres.found_existing) {
                    gpres.key_ptr.* = try gpa.dupe(u8, new_sub);
                    gpres.value_ptr.* = {};
                }
            },
            .directory => {
                // iterate
                try walkDir(abs_root, new_sub, paths, gpa);
            },
            else => |ekind| {
                std.log.warn("skipping file type .{s} in {s} / {s}", .{ @tagName(ekind), abs_root, new_sub });
                continue;
            },
        }
    }
}

const DtioEnum = enum { no, cyclic, yes };
fn genDependencyOrder(dep: DependencyId, deps: *DepQueue, dtio: []DtioEnum, out: *std.ArrayListUnmanaged(DependencyId)) !void {
    switch (dtio[@intFromEnum(dep)]) {
        .no => {}, // add
        .cyclic => {
            std.log.err("cyclic dependencies", .{});
            return error.Cyclic;
        },
        .yes => return, // already in the list
    }
    dtio[@intFromEnum(dep)] = .cyclic;
    if (deps.getZon(dep)) |zon| {
        for (zon.dependencies.keys()) |dep_id| {
            try genDependencyOrder(dep_id, deps, dtio, out);
        }
    }
    out.appendAssumeCapacity(dep);
    dtio[@intFromEnum(dep)] = .yes;
}

const BuildZigZonParseResult = struct {
    gpa: std.mem.Allocator,
    file: ?[:0]const u8,
    ast: ?std.zig.Ast,
    zoir: ?std.zig.Zoir,
    paths: []const []const u8,
    dependencies: std.AutoArrayHashMapUnmanaged(DependencyId, std.zig.Ast.Node.Index),
    dependents: TypesafeSlice(DependentsListIndex, DependencyId).Subslice = .{ .start = 0, .len = 0 },

    generated_zon: ?[]const u8 = null,
    defined: bool = true,

    pub fn deinit(self: *BuildZigZonParseResult) void {
        if (self.file) |file| self.gpa.free(file);
        if (self.ast) |*ast| ast.deinit(self.gpa);
        if (self.zoir) |*zoir| zoir.deinit(self.gpa);
        if (self.generated_zon) |gzn| self.gpa.free(gzn);
        self.dependencies.deinit(self.gpa);
    }
};
const default_paths: []const []const u8 = &.{""};
const exclude_paths = std.StaticStringMap(void).initComptime(.{
    .{ "zig-out", {} },
    .{ ".zig-cache", {} },
    .{ ".git", {} },
    .{ ".DS_Store", {} },
});

pub fn parseBuildZigZon(gpa: std.mem.Allocator, arena: std.mem.Allocator, package_id: DependencyId, deps_queue: *DepQueue, global_cache_path: ?[]const u8) !void {
    const fullpath = deps_queue.getAbsolutePath(package_id);
    const filepath = try std.fs.path.join(arena, &.{ fullpath, "build.zig.zon" });
    const file = std.fs.cwd().readFileAllocOptions(gpa, filepath, std.math.maxInt(usize), null, .of(u8), 0) catch |e| switch (e) {
        error.FileNotFound => {
            deps_queue.setZon(package_id, .{
                .gpa = gpa,
                .file = null,
                .ast = null,
                .zoir = null,
                .paths = default_paths,
                .dependencies = .empty,
            });
            return;
        },
        else => |ee| return ee,
    };
    errdefer gpa.free(file);

    var ast = try std.zig.Ast.parse(gpa, file, .zon);
    errdefer ast.deinit(gpa);

    // we are extracting paths and dependencies, and then we are replacing dependencies with our own

    var root: std.StringArrayHashMapUnmanaged(std.zig.Ast.Node.Index) = .empty;
    defer root.deinit(gpa);
    try parseStruct(gpa, arena, ast, ast.rootDecls()[0], &root);

    var deps: std.StringArrayHashMapUnmanaged(std.zig.Ast.Node.Index) = .empty;
    defer deps.deinit(gpa);
    if (root.get("dependencies")) |deps_idx| {
        try parseStruct(gpa, arena, ast, deps_idx, &deps);
    }

    // now we parse the contents with zoir
    var zoir = try std.zig.ZonGen.generate(gpa, ast, .{});
    errdefer zoir.deinit(gpa);

    var dependencies: std.AutoArrayHashMapUnmanaged(DependencyId, std.zig.Ast.Node.Index) = .empty;
    errdefer dependencies.deinit(gpa);

    // now, parse from the zoir
    const parsed = try std.zon.parse.fromZoirNode(struct {
        paths: ?[]const []const u8 = null,
        dependencies: ?std.zig.Zoir.Node.Index = null,
    }, arena, ast, zoir, .root, null, .{
        .ignore_unknown_fields = true,
        .free_on_error = false,
    });
    if (parsed.dependencies) |parsed_deps| {
        const fields = try structFields(zoir, parsed_deps);
        for (fields.names, 0..fields.vals.len) |name, idx| {
            const dep_parsed = try std.zon.parse.fromZoirNode(struct {
                hash: ?[]const u8 = null,
                path: ?[]const u8 = null,
            }, arena, ast, zoir, fields.vals.at(@intCast(idx)), null, .{
                .ignore_unknown_fields = true,
                .free_on_error = false,
            });
            // now, we parse value as struct { hash: ?[]const u8 = null, path: ?[]const u8 = null }

            var res_path: ?[]const u8 = null;
            if (dep_parsed.path) |path| {
                // local
                res_path = try std.fs.path.join(arena, &.{ fullpath, path });
            } else if (dep_parsed.hash) |hash| {
                if (global_cache_path == null) continue; // global packages excluded
                res_path = try std.fs.path.join(arena, &.{ global_cache_path.?, "p", hash });
            } else {
                // error
                std.log.err("package {s} has neither path nor hash", .{name.get(zoir)});
                return error.Errored;
            }
            const res_real = std.fs.cwd().realpathAlloc(arena, res_path.?) catch |e| switch (e) {
                error.FileNotFound => {
                    std.log.warn("missing path .{s} = {s}", .{ name.get(zoir), res_path.? });
                    continue; // skip this one ig?
                },
                else => |ee| {
                    std.log.err("reading dependency: .{s} = {s}", .{ name.get(zoir), res_path.? });
                    return ee;
                },
            };
            const index = try deps_queue.addAbsolutePath(res_real);
            const gpres = try dependencies.getOrPut(gpa, index);
            if (gpres.found_existing) {
                std.log.err("duplicate dependency {s}, second is called {s}", .{ res_real, name.get(zoir) });
                return error.Errored;
            }
            gpres.value_ptr.* = deps.get(name.get(zoir)).?;
        }
    }

    // now, parse dependencies (we could use std.zon to make this easy maybe?)
    // then, parse paths
    // then, save the ast along with the dependencies token index so we can replace it for rendering

    // when we're done, we need to render ast but replace_nodes_with_node dependencies with a new dependencies node
    // ast.render(gpa, w, .{ .replace_nodes_with_node =  })
    // arguably we should use replace_nodes_with_string along with std.zon.stringify
    // ast.render(gpa: Allocator, w: *Writer, fixups: Fixups)

    deps_queue.setZon(package_id, .{
        .gpa = gpa,
        .file = file,
        .ast = ast,
        .zoir = zoir,
        .paths = parsed.paths orelse default_paths,
        .dependencies = dependencies,
    });
}

fn parseStruct(gpa: std.mem.Allocator, arena: std.mem.Allocator, ast: std.zig.Ast, node: std.zig.Ast.Node.Index, out: *std.StringArrayHashMapUnmanaged(std.zig.Ast.Node.Index)) !void {
    var buf: [2]std.zig.Ast.Node.Index = undefined;
    const struct_init = ast.fullStructInit(&buf, node) orelse return error.MissingRoot;

    for (struct_init.ast.fields) |field_init| {
        const init_token = ast.firstToken(field_init);
        const field_name_token = init_token - 2;
        std.debug.assert(ast.tokenTag(field_name_token) == .identifier);
        var field_name = ast.tokenSlice(field_name_token);
        if (field_name.len > 0 and field_name[0] == '@') {
            field_name = try std.zig.string_literal.parseAlloc(arena, field_name[1..]);
        }

        try out.put(gpa, field_name, field_init);
    }
}

fn structFields(zoir: std.zig.Zoir, node: std.zig.Zoir.Node.Index) !@FieldType(std.zig.Zoir.Node, "struct_literal") {
    const repr = node.get(zoir);
    const fields: @FieldType(std.zig.Zoir.Node, "struct_literal") = switch (repr) {
        .struct_literal => |nodes| nodes,
        .empty_literal => .{ .names = &.{}, .vals = .{ .start = node, .len = 0 } },
        else => return error.WrongType,
    };
    return fields;
}

pub fn TypesafeSlice(comptime Index: type, comptime Child: type) type {
    return struct {
        value: []Child,
        pub const Subslice = struct {
            start: usize,
            len: usize,
            pub fn view(self: @This(), owner: *ThisTypesafeSlice) []Child {
                return owner.value[self.start..][0..self.len];
            }
        };
        const ThisTypesafeSlice = @This();

        pub fn alloc(gpa: std.mem.Allocator, alen: usize) !@This() {
            const value = try gpa.alloc(Child, alen);
            return .wrap(value);
        }
        pub fn wrap(value: []Child) @This() {
            return .{ .value = value };
        }
        pub fn free(self: *@This(), gpa: std.mem.Allocator) void {
            gpa.free(self.value);
        }
        pub fn memset(self: *@This(), value: Child) void {
            @memset(self.value, value);
        }
        pub fn ptr(self: *@This(), index: Index) *Child {
            return &self.value[@intFromEnum(index)];
        }
        pub fn get(self: *@This(), index: Index) Child {
            return self.ptr(index).*;
        }
        pub fn len(self: *@This()) usize {
            return self.value.len;
        }
    };
}
