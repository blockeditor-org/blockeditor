// bundle types:

const std = @import("std");

const DependencyId = enum(usize) { _ };

const DepQueue = struct {
    gpa: std.mem.Allocator,
    dependency_name_to_index: std.StringArrayHashMapUnmanaged(void),

    pub fn addAbsolutePath(self: *DepQueue, path: []const u8) !DependencyId {
        const gpres = try self.dependency_name_to_index.getOrPut(self.gpa, path);
        if (!gpres.found_existing) {
            gpres.value_ptr.* = {};
        }
        return @enumFromInt(gpres.index);
    }
    pub fn getAbsolutePath(self: *DepQueue, id: DependencyId) []const u8 {
        return self.dependency_name_to_index.keys()[@intFromEnum(id)];
    }

    pub fn deinit(self: *DepQueue) void {
        self.dependency_name_to_index.deinit(self.gpa);
    }
};

pub const options: std.Options = .{ .log_level = .debug };

pub fn main() !u8 {
    var gpa_backing = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa_backing.deinit() == .ok);
    const gpa = gpa_backing.allocator();
    var arena_backing = std.heap.ArenaAllocator.init(gpa);
    defer arena_backing.deinit();
    const arena = arena_backing.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    const usage =
        \\Usage:
        \\  zig run package-deps.zig -- ...args
        \\
        \\Example:
        \\  zig run package-deps.zig -- --zig-bin=zig --dst-dir=dst --url-prefix=https://github.com/org/repo/releases/tag/release-id/
        \\
        \\Flags:
        \\  --src-dir=[src_dir]  / specifies the source directory to search for packages
        \\  --zig-bin=[zig_bin]  / specifies the path to the zig binary on the system
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
    var src_dir_opt: ?[]const u8 = null;
    var zig_bin_opt: ?[]const u8 = null;
    var dst_dir_opt: ?[]const u8 = null;
    var url_prefix_opt: ?[]const u8 = null;
    var include_global_packages = false;
    var override_global_packages_dir: ?[]const u8 = null;
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--src-dir=")) {
            src_dir_opt = arg["--src-dir=".len..];
        } else if (std.mem.startsWith(u8, arg, "--zig-bin=")) {
            zig_bin_opt = arg["--zig-bin=".len..];
        } else if (std.mem.startsWith(u8, arg, "--dst-dir=")) {
            dst_dir_opt = arg["--dst-dir=".len..];
        } else if (std.mem.startsWith(u8, arg, "--url-prefix=")) {
            url_prefix_opt = arg["--url-prefix=".len..];
        } else if (std.mem.startsWith(u8, arg, "--dst-file")) {
            std.log.err("todo implement single-file output mode", .{});
            return 1;
        } else if (std.mem.eql(u8, arg, "--include-global-packages")) {
            include_global_packages = true;
        } else if (std.mem.startsWith(u8, arg, "--include-global-packages=")) {
            include_global_packages = true;
            override_global_packages_dir = arg["--include-global-packages=".len..];
        } else {
            std.log.err("unexpected arg \"{f}\". usage:\n{s}", .{ std.zig.fmtString(arg), usage });
            return 1;
        }
    }

    const src_dir = src_dir_opt orelse {
        std.log.err("missing --src-dir, usage:\n{s}", .{usage});
        return 1;
    };
    const zig_arg = zig_bin_opt orelse {
        std.log.err("missing --zig-bin, usage:\n{s}", .{usage});
        return 1;
    };
    const dst_dir = dst_dir_opt orelse {
        std.log.err("missing --dst-dir, usage:\n{s}", .{usage});
        return 1;
    };
    const url_prefix = url_prefix_opt orelse {
        std.log.err("missing --url-prefix, usage:\n{s}", .{usage});
        return 1;
    };
    const mode: enum { multi_file, single_file } = .multi_file;

    var progress = std.Progress.start(.{});
    defer progress.end();

    var zig_env_proc = std.process.Child.init(&.{ zig_arg, "env" }, gpa);
    zig_env_proc.stdout_behavior = .Pipe;
    try zig_env_proc.spawn();
    const zig_env_output = try zig_env_proc.stdout.?.readToEndAllocOptions(gpa, std.math.maxInt(usize), null, .of(u8), 0);
    defer gpa.free(zig_env_output);
    const zig_env_proc_term = try zig_env_proc.wait();
    if (zig_env_proc_term != .Exited or zig_env_proc_term.Exited != 0) {
        std.log.err("zig_env_proc_term {any}", .{zig_env_proc_term});
        return 1;
    }
    const zig_env_parsed = try std.zon.parse.fromSlice(struct {
        global_cache_dir: []const u8,
        version: []const u8,
    }, arena, zig_env_output, null, .{ .free_on_error = false, .ignore_unknown_fields = true });

    var deps: DepQueue = .{
        .gpa = gpa,
        .dependency_name_to_index = .empty,
    };
    defer deps.deinit();

    var dir = try std.fs.cwd().openDir(src_dir, .{ .iterate = true });
    var dir_iter = dir.iterate();
    var has_error = false;
    {
        const find_root = progress.start("find_root", dir_iter.end_index - dir_iter.index);
        defer find_root.end();
        while (try dir_iter.next()) |entry| {
            const itm = find_root.start(entry.name, 0);
            defer itm.end();
            const filepath = try std.fs.path.join(arena, &.{ "packages", entry.name });
            const fullpath = try std.fs.cwd().realpathAlloc(arena, filepath);
            const zonpath = try std.fs.path.join(arena, &.{ fullpath, "build.zig.zon" });

            // we will only queue base packages that have a build.zig.zon
            std.fs.cwd().access(zonpath, .{}) catch |e| switch (e) {
                error.FileNotFound => {
                    // skip
                    continue;
                },
                else => |ee| {
                    has_error = true;
                    std.log.err("checking {s}: error: {s}", .{ zonpath, @errorName(ee) });
                    continue;
                },
            };

            _ = try deps.addAbsolutePath(fullpath);
        }
    }

    var dependency_to_build_zig_zon: std.ArrayListUnmanaged(?BuildZigZonParseResult) = .empty;
    defer dependency_to_build_zig_zon.deinit(gpa);
    defer for (dependency_to_build_zig_zon.items) |*item| if (item.*) |*ite| ite.deinit();

    {
        const queue_node = progress.start("read_zons", deps.dependency_name_to_index.keys().len);
        defer queue_node.end();
        var queue_idx: usize = 0;
        while (queue_idx < deps.dependency_name_to_index.keys().len) : (queue_idx += 1) {
            const item = deps.dependency_name_to_index.keys()[queue_idx];
            const queue_sub_node = queue_node.start(item, 0);
            defer queue_sub_node.end();
            const idx = dependency_to_build_zig_zon.items.len;
            std.debug.assert(idx == queue_idx);
            try dependency_to_build_zig_zon.append(gpa, null);
            dependency_to_build_zig_zon.items[idx] = parseBuildZigZon(gpa, arena, item, &deps, if (include_global_packages) override_global_packages_dir orelse zig_env_parsed.global_cache_dir else null) catch |e| {
                has_error = true;
                std.log.err("{s}: error: {s}", .{ item, @errorName(e) });
                continue;
            };
        }
    }

    var dependency_order = try std.ArrayListUnmanaged(DependencyId).initCapacity(gpa, dependency_to_build_zig_zon.items.len);
    defer dependency_order.deinit(gpa);
    const dependency_to_in_order = try gpa.alloc(DtioEnum, dependency_to_build_zig_zon.items.len);
    defer gpa.free(dependency_to_in_order);
    @memset(dependency_to_in_order, .no);
    {
        const dep_order_node = progress.start("dependency order", deps.dependency_name_to_index.keys().len);
        defer dep_order_node.end();
        for (0..deps.dependency_name_to_index.keys().len) |index| {
            defer dep_order_node.completeOne();
            try genDependencyOrder(@enumFromInt(index), dependency_to_build_zig_zon.items, dependency_to_in_order, &dependency_order);
        }
    }

    std.fs.cwd().makeDir(".zig-cache") catch {};
    std.fs.cwd().makeDir(".zig-cache/tmp") catch {};
    const tmp_global_cache_dir_name = ".zig-cache/tmp/package-deps-" ++ std.fmt.hex(std.crypto.random.int(u64));
    std.fs.cwd().makeDir(tmp_global_cache_dir_name) catch {};
    std.fs.cwd().makeDir(dst_dir) catch {};

    // now, we loop over each dependency
    // for each dependency we will generate a tar.gz file for it and we will rerender its build.zig.zon and then we will generate its hash and save that
    {
        const generate_output_node = progress.start("generate output", dependency_order.items.len);
        defer generate_output_node.end();

        for (dependency_order.items) |dep| {
            const dep_abspath = deps.getAbsolutePath(dep);
            const render_dep_node = generate_output_node.start(dep_abspath, 4);
            defer render_dep_node.end();

            const dep_bzz = if (dependency_to_build_zig_zon.items[@intFromEnum(dep)]) |*it| it else {
                // skip this dependency; no bzz;
                continue;
            };

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

                // TODO: enable compression. it looks like it will be in 0.16.0:
                // https://codeberg.org/ziglang/zig/src/commit/56253d9e31c0576f024d95929a8fe26428b35176/lib/std/compress/flate/Compress.zig
                // in 0.15.0, it doesn't work: https://github.com/ziglang/zig/issues/24973

                var tar: std.tar.Writer = .{ .underlying_writer = &out_file_writer.interface };

                var seen_paths: std.StringArrayHashMapUnmanaged(void) = .empty;
                defer seen_paths.deinit(gpa);
                {
                    const walk_dir_node = render_dep_node.start("walk dirs", dep_bzz.paths.len);
                    defer walk_dir_node.end();
                    for (dep_bzz.paths) |path| {
                        const walk_path_node = walk_dir_node.start(path, path.len);
                        defer walk_path_node.end();
                        walkDir(deps.getAbsolutePath(dep), path, &seen_paths, gpa, arena) catch |e| switch (e) {
                            else => |ee| {
                                std.log.err("failed to check path {s} / {s}", .{ path, @errorName(ee) });
                                has_error = true;
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

                    const fullpath = try std.fs.path.join(gpa, &.{ deps.getAbsolutePath(dep), file_path });
                    defer gpa.free(fullpath);

                    if (std.mem.eql(u8, file_path, "build.zig.zon")) {
                        // write build.zig.zon
                        const rendered = try renderBuildZigZon(gpa, arena, dep_bzz, dependency_to_build_zig_zon.items);
                        defer gpa.free(rendered);
                        try tar.writeFileBytes("build.zig.zon", rendered, .{});
                    } else {
                        // now we will write the file
                        var file = try std.fs.openFileAbsolute(fullpath, .{ .mode = .read_only });
                        defer file.close();
                        var reader_buf: [1024]u8 = undefined;
                        var file_reader = file.reader(&reader_buf);
                        // note: not using writeFile so we don't copy mtime and such
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
            switch (mode) {
                .single_file => @panic("TODO for single file we need to decide a name and stuff. path=../name"),
                .multi_file => {
                    var hash_finder = std.process.Child.init(&.{ zig_arg, "fetch", "--global-cache-dir", tmp_global_cache_dir_name, tmp_name }, gpa);
                    hash_finder.stdout_behavior = .Pipe;
                    try hash_finder.spawn();
                    const hash_result = try hash_finder.stdout.?.readToEndAlloc(gpa, 256);
                    defer gpa.free(hash_result);
                    const term = try hash_finder.wait();
                    if (term != .Exited or term.Exited != 0) {
                        std.log.err("bad term: {any} / stdout: {s}", .{ term, hash_result });
                        return error.BadTerm;
                    }
                    const found_hash = std.mem.trim(u8, hash_result, " \r\n\t");
                    const found_filename = try std.fmt.allocPrint(gpa, "{s}.tar", .{found_hash});
                    defer gpa.free(found_filename);

                    const rendered_url = try std.fmt.allocPrint(gpa, "{s}{s}", .{ url_prefix, found_filename });
                    defer gpa.free(rendered_url);
                    const rendered_path = try std.fs.path.join(gpa, &.{ dst_dir, found_filename });
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
        }
    }

    if (has_error) return 1;
    return 0;
}

fn renderBuildZigZon(gpa: std.mem.Allocator, arena: std.mem.Allocator, dep_bzz: *BuildZigZonParseResult, all_bzz: []?BuildZigZonParseResult) ![]const u8 {
    _ = arena;
    if (dep_bzz.ast == null) {
        // uh oh! somehow there's no ast but there is a build.zig.zon file
        std.log.err("no ast but yes build.zig.zon file? how can this happen?", .{});
        return error.Errored;
    }

    var replace_nodes_with_string = std.AutoHashMapUnmanaged(std.zig.Ast.Node.Index, []const u8).empty;
    defer replace_nodes_with_string.deinit(gpa);

    // iterate over dependencies, rerender
    for (dep_bzz.dependencies.keys(), dep_bzz.dependencies.values()) |dep_id, node_idx| {
        if (all_bzz[@intFromEnum(dep_id)]) |*other_bzz| {
            if (other_bzz.generated_zon == null) {
                @panic("it should have been generated by now");
            }
            try replace_nodes_with_string.putNoClobber(gpa, node_idx, other_bzz.generated_zon.?);
        } else {
            // it is null, oops
        }
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

fn walkDir(abs_root: []const u8, sub_path: []const u8, paths: *std.StringArrayHashMapUnmanaged(void), gpa: std.mem.Allocator, arena: std.mem.Allocator) !void {
    const fullpath = try std.fs.path.join(gpa, &.{ abs_root, sub_path });
    defer gpa.free(fullpath);

    var pathdir = std.fs.openDirAbsolute(fullpath, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return,
        error.NotDir => {
            try paths.put(gpa, try arena.dupe(u8, sub_path), {});
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
        const new_sub = try std.fs.path.join(arena, &.{ sub_path, entry.name });
        switch (entry.kind) {
            .file => {
                try paths.put(gpa, new_sub, {});
            },
            .directory => {
                // iterate
                try walkDir(abs_root, new_sub, paths, gpa, arena);
            },
            else => |ekind| {
                std.log.warn("skipping file type .{s}", .{@tagName(ekind)});
                continue;
            },
        }
    }
}

const DtioEnum = enum { no, cyclic, yes };
fn genDependencyOrder(dep: DependencyId, bzz: []?BuildZigZonParseResult, dtio: []DtioEnum, out: *std.ArrayListUnmanaged(DependencyId)) !void {
    switch (dtio[@intFromEnum(dep)]) {
        .no => {}, // add
        .cyclic => {
            std.log.err("cyclic dependencies", .{});
            return error.Cyclic;
        },
        .yes => return, // already in the list
    }
    dtio[@intFromEnum(dep)] = .cyclic;
    if (bzz[@intFromEnum(dep)]) |*zon| {
        for (zon.dependencies.keys()) |dep_id| {
            try genDependencyOrder(dep_id, bzz, dtio, out);
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

    generated_zon: ?[]const u8 = null,

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

pub fn parseBuildZigZon(gpa: std.mem.Allocator, arena: std.mem.Allocator, fullpath: []const u8, deps_queue: *DepQueue, global_cache_path: ?[]const u8) !BuildZigZonParseResult {
    const filepath = try std.fs.path.join(arena, &.{ fullpath, "build.zig.zon" });
    const file = std.fs.cwd().readFileAllocOptions(gpa, filepath, std.math.maxInt(usize), null, .of(u8), 0) catch |e| switch (e) {
        error.FileNotFound => {
            return .{
                .gpa = gpa,
                .file = null,
                .ast = null,
                .zoir = null,
                .paths = default_paths,
                .dependencies = .empty,
            };
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

    return .{
        .gpa = gpa,
        .file = file,
        .ast = ast,
        .zoir = zoir,
        .paths = parsed.paths orelse default_paths,
        .dependencies = dependencies,
    };
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
