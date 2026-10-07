// bundle types:

const std = @import("std");

const PackageID = enum(usize) { _ };

// stages:
// 1. explore dependency tree, parse build.zig.zon files
// 2. output named .tar.gz files

// TODO:
// --update-readmes: update README.md files in the root of local packages (not global cache packages) to include the
//   command to fetch the package. eg a line ending with `#zools.install_command` will be replaced with `zig fetch --save=$name $url #zools.install_command`.
//   warn for each readme that doesn't have the zools.install_command thing.
// --missing:(remove|skip): if a dependency was not found, should it be removed or ignored? ignore = leave the existing url/hash. remove = unclear.

// Usage modes:
//   To gather all URL dependencies for uploading onto your own server, and update local packages to use the new URL:
//     zig build --fetch=all ; zig run packages/zools/src/package-deps.zig -- bundle build/packages https://lfs.pfg.pw/by-hash/zig-pkg/ --compression-level=best --verbose-compression --update-dependency-urls --exclude-local-packages
//     REMINDER: run --fetch=all, remove the offending packages after bundling, not before. otherwise it keeps in the github urls.
//   To gather all local packages into seperate tar files and update readmes to point to where to download them:
//     zig run packages/zools/src/package-deps.zig -- bundle build/packages https://lfs.pfg.pw/by-hash/zig-pkg/ --exclude-global-packages --update-readmes
//   To gather everything into one .tar.gz file so you can build depending only on the zig compiler:
//     bundle-onefile build/app.tar.gz
//   To see why a package is installed
//     why path/to/package
// it would be nice to simplify these to not need so many arguments

const PackageQueue = struct {
    gpa: std.mem.Allocator,
    /// TODO: store packages by (name/fingerprint@version) and only fall back to abspath for packages without a name and fingerprint
    dependency_abspath_to_zon: std.StringArrayHashMapUnmanaged(PackageInfo) = .empty,
    finalized: bool = false,

    pub fn addAbsolutePath(self: *PackageQueue, path: []const u8) !PackageID {
        std.debug.assert(!self.finalized);
        const gpres = try self.dependency_abspath_to_zon.getOrPut(self.gpa, path);
        if (!gpres.found_existing) {
            gpres.value_ptr.* = undefined;
            gpres.value_ptr.defined = false;
        }
        return @enumFromInt(gpres.index);
    }
    pub fn getAbsolutePath(self: *PackageQueue, id: PackageID) []const u8 {
        return self.dependency_abspath_to_zon.keys()[@intFromEnum(id)];
    }
    pub fn getZon(self: *PackageQueue, id: PackageID) *PackageInfo {
        return &self.dependency_abspath_to_zon.values()[@intFromEnum(id)];
    }
    pub fn setZon(self: *PackageQueue, id: PackageID, value: PackageInfo) void {
        const ptr = &self.dependency_abspath_to_zon.values()[@intFromEnum(id)];
        std.debug.assert(!ptr.defined); // tried to overwrite package zon
        std.debug.assert(value.defined);
        ptr.* = value;
    }
    pub fn len(self: *PackageQueue) usize {
        return self.dependency_abspath_to_zon.keys().len;
    }

    pub fn deinit(self: *PackageQueue) void {
        for (self.dependency_abspath_to_zon.values()) |*item| if (item.defined) item.deinit();
        self.dependency_abspath_to_zon.deinit(self.gpa);
    }

    pub fn finalize(self: *PackageQueue) !PackageList {
        // 1. ensure fully completed
        for (self.dependency_abspath_to_zon.values()) |*bzz| {
            if (!bzz.defined) {
                return error.Errored;
            }
        }

        var dependents_count: TypesafeSlice(PackageID, usize) = try .alloc(self.gpa, self.len());
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

        const dependents = try self.gpa.alloc(PackageID, dependents_total);
        errdefer self.gpa.free(dependents);

        var running_total = root_dependencies;
        for (self.dependency_abspath_to_zon.values(), 0..) |*bzz, i| {
            const dep_id: PackageID = @enumFromInt(i);
            bzz.dependents.start = running_total;
            running_total += dependents_count.get(dep_id);
        }

        var root: TypesafeSlice(DependentsListIndex, PackageID).Subslice = .{ .start = 0, .len = 0 };
        for (self.dependency_abspath_to_zon.values(), 0..) |*bzz, i| {
            const dependent_id: PackageID = @enumFromInt(i);
            if (bzz.dependencies.keys().len == 0) {
                dependents[root.start + root.len] = dependent_id;
                root.len += 1;
            } else for (bzz.dependencies.keys()) |dependency_id| {
                const zon = self.getZon(dependency_id);
                dependents[zon.dependents.start + zon.dependents.len] = dependent_id;
                zon.dependents.len += 1;
            }
        }

        var dependencies_count: TypesafeSlice(PackageID, std.atomic.Value(usize)) = try .alloc(self.gpa, self.len());
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
const DependentsListIndex = opaque {};
const PackageList = struct {
    gpa: std.mem.Allocator,
    dependents: TypesafeSlice(DependentsListIndex, PackageID),
    dependencies_count: TypesafeSlice(PackageID, std.atomic.Value(usize)), // when you decrement this to 0, spawn a new task
    root_dependencies: TypesafeSlice(DependentsListIndex, PackageID).Subslice,
    abspaths: TypesafeSlice(PackageID, []const u8),
    bzzs: TypesafeSlice(PackageID, PackageInfo), // interestingly, these are already known to not be null

    pub fn deinit(self: *PackageList) void {
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
    command_type: CommandType,
    src_pkgs: []const []const u8,
    zig_bin: []const u8,
    include_global_packages: bool,
    override_global_packages_dir: ?[]const u8,
    update: struct {
        dependency_urls: bool,
    },
    update_root: []const u8,
    exclude_local_packages: bool,
    compression_level: CompressionLevel,
    verbose_compression: bool,

    const CompressionLevel = std.meta.DeclEnum(std.compress.flate.Compress.Options);
    const CommandType = union(enum) {
        bundle: struct {
            dst_dir: []const u8,
            url_prefix: []const u8,
        },
        why: struct {
            pkg: []const u8,
        },
    };

    pub fn deinit(self: *Opts, gpa: std.mem.Allocator) void {
        gpa.free(self.src_pkgs);
    }
    pub fn parse(gpa: std.mem.Allocator, args: []const []const u8) !Opts {
        var iter = ArgsIter.init(args[1..]);
        const usage =
            \\Usage:
            \\  zig run package-deps.zig -- bundle [./dst/dir] [https://url_prefix/]
            \\  zig run package-deps.zig -- why [./path/to/package]
            \\
            \\Flags:
            \\  --src-pkg=[src_dir]  / specifies the source directory to search for packages.
            \\                                 you may specify multiple by repeating this flag.
            \\                                 default is '.' if no src-pkgs are specified
            \\  --zig-bin=[zig_bin]  / specifies the path to the zig, default `zig`
        ++ @import("builtin").zig_version_string ++
            \\ binary on the system
            \\  --exclude-global-packages  / specifies that packages in the global package cache should not be walked
            \\  --global-packages-dir=[dir]  / manually specify global package dir, default `$(zig env).global_cache_dir`
            \\  --update-root=[folder]  / don't update anything outside of this root, default `.`
            \\  --why=[path]  / prints the chain of dependents leading to this package and exits
            \\  --compression-level=[level_1...level_9/fastest/default/best]  / sets gzip compression level. default 'default'
            \\  --verbose-compression  / output file sizes and compression levels
            \\  --help  / show this
            \\
            \\For multi-file output:
            \\  --update-dependency-urls  / if set, update build.zig.zon files to point to the new generated URLs & hashes
            \\  --exclude-local-packages  / if set, skip emitting local packages. local packages are packages inside the update root.
            \\
            \\For single-file output:
            \\  --dst-file=[file].tar.gz  / specifies the output file
            \\
        ;
        var src_pkgs: std.ArrayList([]const u8) = .empty;
        defer src_pkgs.deinit(gpa);
        var zig_bin: []const u8 = "zig";
        var include_global_packages = true;
        var update_dependency_urls = false;
        var update_root: []const u8 = ".";
        var override_global_packages_dir: ?[]const u8 = null;
        var exclude_local_packages = false;
        var compression_level: CompressionLevel = .default;
        var verbose_compression: bool = false;
        var opts_done = false;
        var positionals: std.ArrayList([]const u8) = .empty;
        defer positionals.deinit(gpa);

        while (iter.take()) |arg| {
            if (opts_done or !std.mem.startsWith(u8, arg, "-")) {
                try positionals.append(gpa, arg);
                continue;
            }
            if (std.mem.eql(u8, arg, "--")) {
                opts_done = true;
            } else if (tryEat(arg, "--src-pkg=")) |sub| {
                try src_pkgs.append(gpa, sub);
            } else if (tryEat(arg, "--zig-bin=")) |sub| {
                zig_bin = sub;
            } else if (tryEat(arg, "--dst-file=")) |sub| {
                _ = sub;
                return printError("todo implement single-file output mode", .{});
            } else if (std.mem.eql(u8, arg, "--exclude-global-packages")) {
                include_global_packages = false;
            } else if (tryEat(arg, "--global-packages-dir=")) |sub| {
                override_global_packages_dir = sub;
            } else if (std.mem.eql(u8, arg, "--update-dependency-urls")) {
                update_dependency_urls = true;
            } else if (tryEat(arg, "--update-root=")) |sub| {
                update_root = sub;
            } else if (std.mem.eql(u8, arg, "--exclude-local-packages")) {
                exclude_local_packages = true;
            } else if (tryEat(arg, "--compression-level=")) |sub| {
                compression_level = std.meta.stringToEnum(CompressionLevel, sub) orelse {
                    return printError("invalid comrpession level: '{s}', expected: level_1/.../level_9/fastest/default/best", .{sub});
                };
            } else if (std.mem.eql(u8, arg, "--verbose-compression")) {
                verbose_compression = true;
            } else if (std.mem.eql(u8, arg, "--help")) {
                return printError("help:\n{s}", .{usage}); // this should go to stdout and return exit code 0
            } else {
                return printError("unexpected arg \"{f}\". usage:\n{s}", .{ std.zig.fmtString(arg), usage });
            }
        }

        const cmdstr = std.meta.stringToEnum(enum { bundle, why }, if (positionals.items.len == 0) "" else positionals.items[0]) orelse {
            return printError("missing command 'bundle' or 'why'\n{s}", .{usage});
        };
        const command_type: CommandType = command_type: switch (cmdstr) {
            .bundle => {
                if (positionals.items.len != 3) return printError("missing dst_dir or url_prefix or extra args\n{s}", .{usage});
                break :command_type .{ .bundle = .{ .dst_dir = positionals.items[1], .url_prefix = positionals.items[2] } };
            },
            .why => {
                if (positionals.items.len != 2) return printError("missing path_to_package or extra args\n{s}", .{usage});
                break :command_type .{ .why = .{ .pkg = positionals.items[1] } };
            },
        };

        if (src_pkgs.items.len == 0) {
            try src_pkgs.append(gpa, ".");
        }

        const src_pkgs_owned = try src_pkgs.toOwnedSlice(gpa);
        errdefer gpa.free(src_pkgs_owned);

        if (update_dependency_urls and !include_global_packages) {
            return printError("missing --include-global-packages, required if using --update-depdendency-urls", .{});
        }

        if (exclude_local_packages and !include_global_packages) {
            return printError("missing --include-global-packages, required if using --exclude-local-packages", .{});
        }

        return .{
            .command_type = command_type,
            .src_pkgs = src_pkgs_owned,
            .zig_bin = zig_bin,
            .include_global_packages = include_global_packages,
            .override_global_packages_dir = override_global_packages_dir,
            .update = .{ .dependency_urls = update_dependency_urls },
            .update_root = update_root,
            .exclude_local_packages = exclude_local_packages,
            .compression_level = compression_level,
            .verbose_compression = verbose_compression,
        };
    }
};

const ArgsIter = struct {
    args: []const []const u8,
    index: usize,
    fn init(args: []const []const u8) ArgsIter {
        return .{ .args = args, .index = 0 };
    }
    fn peek(self: *ArgsIter) ?[]const u8 {
        if (self.index >= self.args.len) return null;
        return self.args[self.index];
    }
    fn take(self: *ArgsIter) ?[]const u8 {
        const res = self.peek() orelse return null;
        self.index += 1;
        return res;
    }
};

fn tryEat(str: []const u8, takeoff: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, str, takeoff)) return str[takeoff.len..];
    return null;
}

pub fn exec(io: std.Io, gpa: std.mem.Allocator, progress: std.Progress.Node, args: []const []const u8) ![:0]const u8 {
    var zig_env_proc = try std.process.spawn(io, .{
        .argv = args,
        .stdin = .inherit,
        .stdout = .pipe,
        .stderr = .inherit,
        .progress_node = progress,
    });
    var file_reader = zig_env_proc.stdout.?.reader(io, &.{});
    const zig_env_output = try file_reader.interface.allocRemainingAlignedSentinel(gpa, .unlimited, .of(u8), 0);
    errdefer gpa.free(zig_env_output);
    const zig_env_proc_term = try zig_env_proc.wait(io);
    if (zig_env_proc_term != .exited or zig_env_proc_term.exited != 0) {
        return printError("zig_env_proc_term {any}", .{zig_env_proc_term});
    }
    return zig_env_output;
}

const Context = struct {
    tmp_global_cache_dir_name: []const u8,

    /// null if global packages should not be included
    global_cache_dir: ?[]const u8,

    has_error: bool,

    update_root: []const u8,
};

pub fn main(init: std.process.Init) !u8 {
    return main2(init) catch |e| switch (e) {
        error.Errored => return 1,
        else => return e,
    };
}
pub fn main2(init: std.process.Init) !u8 {
    var gpa_backing = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa_backing.deinit() == .ok);
    const gpa = gpa_backing.allocator();
    var arena_backing = std.heap.ArenaAllocator.init(gpa);
    defer arena_backing.deinit();
    const arena = arena_backing.allocator();

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const io = init.io;

    var opts = try Opts.parse(gpa, args);
    defer opts.deinit(gpa);

    var progress = std.Progress.start(io, .{ .estimated_total_items = 4 });
    defer progress.end();

    const zig_env_output = try exec(io, gpa, progress, &.{ opts.zig_bin, "env" });
    defer gpa.free(zig_env_output);

    const zig_env_parsed = try std.zon.parse.fromSliceAlloc(struct {
        global_cache_dir: []const u8,
        version: []const u8,
    }, arena, zig_env_output, null, .{ .free_on_error = false, .ignore_unknown_fields = true });
    if (!std.mem.eql(u8, zig_env_parsed.version, @import("builtin").zig_version_string)) {
        return printError("running `{s}` binary:\n  expected zig version {s}, got version {s}\n  to override the zig binary, pass `--zig-bin`", .{ opts.zig_bin, @import("builtin").zig_version_string, zig_env_parsed.version });
    }

    const update_root = try std.Io.Dir.cwd().realPathFileAlloc(io, opts.update_root, gpa);
    defer gpa.free(update_root);

    const rng_impl: std.Random.IoSource = .{ .io = io };
    const rng = rng_impl.interface();
    var context: Context = .{
        .tmp_global_cache_dir_name = ".zig-cache/tmp/package-deps-" ++ std.fmt.hex(rng.int(u64)),
        .global_cache_dir = switch (opts.include_global_packages) {
            true => opts.override_global_packages_dir orelse zig_env_parsed.global_cache_dir,
            false => null,
        },
        .has_error = false,
        .update_root = update_root,
    };

    var deps: PackageQueue = .{ .gpa = gpa };
    defer deps.deinit();

    {
        const find_root = progress.start("find_root", opts.src_pkgs.len);
        defer find_root.end();

        for (opts.src_pkgs) |src_pkg| {
            const find_one_root = find_root.start(src_pkg, 0);
            defer find_one_root.end();

            const fullpath = try std.Io.Dir.cwd().realPathFileAlloc(io, src_pkg, arena);
            _ = try deps.addAbsolutePath(fullpath);
        }
    }

    {
        const queue_node = progress.start("explore", deps.dependency_abspath_to_zon.keys().len);
        defer queue_node.end();
        var queue_idx: usize = 0;
        while (queue_idx < deps.len()) : (queue_idx += 1) {
            const package_abs_path = deps.getAbsolutePath(@enumFromInt(queue_idx));
            const queue_sub_node = queue_node.start(package_abs_path, 0);
            defer queue_sub_node.end();

            fillDependency(io, gpa, arena, @enumFromInt(queue_idx), &deps, &context) catch |e| {
                context.has_error = true;
                std.log.err("{s}: error: {s}", .{ package_abs_path, @errorName(e) });
                continue;
            };
        }
    }

    var df = try deps.finalize();
    defer df.deinit();

    const bundle = switch (opts.command_type) {
        .why => |*why| {
            const why_path = std.Io.Dir.cwd().realPathFileAlloc(io, why.pkg, gpa) catch |e| {
                return printError("could not resolve path '{s}': {s}", .{ why.pkg, @errorName(e) });
            };
            defer gpa.free(why_path);

            return printError("TODO: print why tree", .{});
        },
        .bundle => |*bundle| bundle,
    };

    std.Io.Dir.cwd().createDir(io, ".zig-cache", .default_dir) catch {};
    std.Io.Dir.cwd().createDir(io, ".zig-cache/tmp", .default_dir) catch {};
    std.Io.Dir.cwd().createDir(io, context.tmp_global_cache_dir_name, .default_dir) catch {};
    std.Io.Dir.cwd().createDir(io, bundle.dst_dir, .default_dir) catch {};

    defer {
        const cleanup = progress.start("clean up", 1);
        defer cleanup.end();
        std.Io.Dir.cwd().deleteTree(io, context.tmp_global_cache_dir_name) catch |e| {
            std.log.err("error while deleting global cache dir: {s}", .{@errorName(e)});
        };
    }

    // now, we loop over each dependency
    // for each dependency we will generate a tar.gz file for it and we will rerender its build.zig.zon and then we will generate its hash and save that
    {
        const generate_output_node = progress.start("generate output", df.abspaths.len());
        defer generate_output_node.end();

        var group: std.Io.Group = .init;
        errdefer group.cancel(io);

        const efo: EmitFileOpts = .{
            .df = &df,
            .generate_output_node = generate_output_node,
            .opts = &opts,
            .group = &group,
            .context = &context,
        };

        for (df.root_dependencies.view(&df.dependents)) |dependent| {
            group.async(io, emitFile, .{ io, dependent, &efo });
        }
        try group.await(io);
    }

    if (context.has_error) return 1;
    return 0;
}

const EmitFileOpts = struct {
    df: *PackageList,
    generate_output_node: std.Progress.Node,
    opts: *const Opts,
    group: *std.Io.Group,
    context: *Context,
};
fn emitFile(
    io: std.Io,
    dep: PackageID,
    efo: *const EmitFileOpts,
) std.Io.Cancelable!void {
    emitFileInternal(io, dep, efo) catch |e| {
        if (e == error.Canceled) return error.Canceled;
        std.log.err("emitFileInternal failed: {s}", .{@errorName(e)});
        efo.context.has_error = true;
        return;
    };
}
fn emitFileInternal(
    io: std.Io,
    dep: PackageID,
    efo: *const EmitFileOpts,
) !void {
    const df = efo.df;
    const generate_output_node = efo.generate_output_node;
    const opts = efo.opts;
    const group = efo.group;

    const gpa = df.gpa;
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

    if (!opts.exclude_local_packages or !dep_bzz.is_local) {
        const rng_impl: std.Random.IoSource = .{ .io = io };
        const rng = rng_impl.interface();
        const rand_int = rng.int(u64);
        const tmp_name = ".zig-cache/tmp/package-deps-" ++ std.fmt.hex(rand_int) ++ ".tar.gz";
        {
            var out_file = try std.Io.Dir.cwd().createFile(io, tmp_name, .{});
            defer out_file.close(io);
            var out_file_buf: [1024]u8 = undefined;
            var out_file_writer = out_file.writer(io, &out_file_buf);
            var src_bytes_est: u64 = 0;

            const Compress = std.compress.flate.Compress;
            const flate = std.compress.flate;
            var compressor_buf: [flate.max_window_len * 2]u8 = undefined;
            var compressor: Compress = try .init(&out_file_writer.interface, &compressor_buf, .gzip, switch (opts.compression_level) {
                inline else => |level| @field(Compress.Options, @tagName(level)),
            });

            var tar: std.tar.Writer = .{ .underlying_writer = &compressor.writer };

            var seen_paths: std.StringArrayHashMapUnmanaged(void) = .empty;
            defer seen_paths.deinit(gpa);
            defer for (seen_paths.keys()) |key| gpa.free(key);
            {
                const walk_dir_node = render_dep_node.start("walk dirs", dep_bzz.paths.len);
                defer walk_dir_node.end();
                for (dep_bzz.paths) |path| {
                    const walk_path_node = walk_dir_node.start(path, path.len);
                    defer walk_path_node.end();
                    walkDir(io, df.abspaths.get(dep), path, &seen_paths, gpa) catch |e| switch (e) {
                        else => |ee| {
                            std.log.err("failed to check path {s} / {s}", .{ path, @errorName(ee) });
                            efo.context.has_error = true;
                            continue;
                        },
                    };
                }
            }
            std.mem.sort([]const u8, seen_paths.keys(), {}, lessThanString);

            const write_tar_node = render_dep_node.start("write tar", seen_paths.keys().len);
            defer write_tar_node.end();
            for (seen_paths.keys()) |file_path| {
                src_bytes_est += file_path.len;
                const sub_tar_node = write_tar_node.start(file_path, 0);
                defer sub_tar_node.end();

                const fullpath = try std.fs.path.join(gpa, &.{ df.abspaths.get(dep), file_path });
                defer gpa.free(fullpath);

                const tar_path = try gpa.dupe(u8, file_path);
                defer gpa.free(tar_path);
                if (std.fs.path.sep != std.fs.path.sep_posix) {
                    std.mem.replaceScalar(u8, tar_path, std.fs.path.sep, std.fs.path.sep_posix);
                }

                if (std.mem.eql(u8, tar_path, "build.zig.zon")) {
                    // write build.zig.zon
                    const rendered = try renderBuildZigZon(gpa, dep_bzz, df, .output);
                    defer gpa.free(rendered);
                    try tar.writeFileBytes(tar_path, rendered, .{});
                    src_bytes_est += rendered.len;
                } else {
                    // now we will write the file
                    var file = try std.Io.Dir.openFileAbsolute(io, fullpath, .{ .mode = .read_only });
                    defer file.close(io);
                    var reader_buf: [1024]u8 = undefined;
                    var file_reader = file.reader(io, &reader_buf);
                    // note: not using writeFile so we don't copy mtime and such
                    // TODO: save +x permission
                    const file_size = try file_reader.getSize();
                    try tar.writeFileStream(tar_path, file_size, &file_reader.interface, .{});
                    src_bytes_est += file_size;
                }
            }

            // finally, write build.zig.zon

            try tar.finishPedantically();
            try compressor.finish();
            try out_file_writer.interface.flush();
            //out_file_writer.pos

            if (opts.verbose_compression) {
                std.log.scoped(.compression).info("{s}: {Bi:.2} -> {Bi:.2} / compressed {d:.2}%", .{
                    dep_abspath,
                    src_bytes_est,
                    out_file_writer.pos,
                    (1.0 - @as(f64, @floatFromInt(out_file_writer.pos)) / @as(f64, @floatFromInt(src_bytes_est))) * 100,
                });
            }
        }

        // now that we have written the file, use the zig compiler to determine the hash of the package
        // (maybe using --debug-hash? maybe not)

        const find_hash_node = render_dep_node.start("find hash", 0);
        defer find_hash_node.end();

        const hash_result = try exec(io, gpa, find_hash_node, &.{
            opts.zig_bin,
            "fetch",
            // TODO: there doesn't seem to be an arg for setting the 'zig-pkg' folder in 0.16
            "--global-cache-dir",
            switch (opts.update.dependency_urls and !dep_bzz.is_local and efo.context.global_cache_dir != null) {
                true => efo.context.global_cache_dir.?,
                false => efo.context.tmp_global_cache_dir_name,
            },
            tmp_name,
        });
        defer gpa.free(hash_result);
        const found_hash = std.mem.trim(u8, hash_result, " \r\n\t");
        const found_filename = try std.fmt.allocPrint(gpa, "{s}.tar.gz", .{found_hash});
        defer gpa.free(found_filename);

        const rendered_url = try std.fmt.allocPrint(gpa, "{s}{s}", .{ opts.command_type.bundle.url_prefix, found_filename });
        errdefer gpa.free(rendered_url);
        const rendered_path = try std.fs.path.join(gpa, &.{ opts.command_type.bundle.dst_dir, found_filename });
        defer gpa.free(rendered_path);
        const rendered_hash = try gpa.dupe(u8, found_hash);
        errdefer gpa.free(rendered_hash);

        // move the file
        try std.Io.Dir.cwd().rename(tmp_name, std.Io.Dir.cwd(), rendered_path, io);

        // finally, set generated zon. this takes ownership of rendered_url,rendered_hash
        dep_bzz.generated_zon = .{
            .url = rendered_url,
            .hash = rendered_hash,
        };
    }

    if (opts.update.dependency_urls and dep_bzz.is_local and dep_bzz.ast != null) {
        const rendered = try renderBuildZigZon(gpa, dep_bzz, df, .source);
        defer gpa.free(rendered);
        const path = try std.fs.path.join(gpa, &.{ dep_abspath, "build.zig.zon" });
        defer gpa.free(path);
        try std.Io.Dir.cwd().writeFile(io, .{ .data = rendered, .sub_path = path });
    }

    // enqueue dependents
    for (dep_bzz.dependents.view(&df.dependents)) |dependent| {
        const dec = df.dependencies_count.ptr(dependent).fetchSub(1, .acq_rel);
        if (dec == 1) { // 1 means we decremented to 0
            group.async(io, emitFile, .{ io, dependent, efo });
        }
    }
}

fn renderBuildZigZon(gpa: std.mem.Allocator, dep_bzz: *PackageInfo, df: *PackageList, mode: enum { output, source }) ![]const u8 {
    if (dep_bzz.ast == null) {
        // uh oh! somehow there's no ast but there is a build.zig.zon file
        std.log.err("no ast but yes build.zig.zon file? how can this happen?", .{});
        return error.Errored;
    }

    var replace_nodes_with_string = std.AutoHashMapUnmanaged(std.zig.Ast.Node.Index, []const u8).empty;
    defer replace_nodes_with_string.deinit(gpa);
    defer {
        var iter = replace_nodes_with_string.valueIterator();
        while (iter.next()) |str| gpa.free(str.*);
    }

    // iterate over dependencies, rerender
    for (dep_bzz.dependencies.keys(), dep_bzz.dependencies.values()) |dep_id, dep_data| {
        const other_bzz = df.bzzs.get(dep_id);
        if (mode == .source and other_bzz.is_local) continue;
        const generated_zon = other_bzz.generated_zon orelse {
            return printError("it should have been generated by now // this error could occur when --exclude-local-packages is passed but a nonlocal package depends on a local one. TODO, it should be gracefully handled in that case", .{});
        };

        var result_package_info_writer: std.Io.Writer.Allocating = .init(gpa);
        defer result_package_info_writer.deinit();

        try std.zon.stringify.serialize(struct {
            url: []const u8,
            hash: []const u8,
            lazy: bool = false,
        }{
            .url = generated_zon.url,
            .hash = generated_zon.hash,
            .lazy = dep_data.lazy,
        }, .{ .emit_default_optional_fields = false }, &result_package_info_writer.writer);

        const owned = try result_package_info_writer.toOwnedSlice();
        errdefer gpa.free(owned);

        try replace_nodes_with_string.putNoClobber(gpa, dep_data.ast_node, owned);
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

fn walkDir(io: std.Io, abs_root: []const u8, sub_path: []const u8, paths: *std.StringArrayHashMapUnmanaged(void), gpa: std.mem.Allocator) !void {
    const fullpath = try std.fs.path.join(gpa, &.{ abs_root, sub_path });
    defer gpa.free(fullpath);

    var pathdir = std.Io.Dir.openDirAbsolute(io, fullpath, .{ .iterate = true }) catch |e| switch (e) {
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
    defer pathdir.close(io);

    var iter = pathdir.iterate();
    while (try iter.next(io)) |entry| {
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
                try walkDir(io, abs_root, new_sub, paths, gpa);
            },
            else => |ekind| {
                std.log.warn("skipping file type .{s} in {s} / {s}", .{ @tagName(ekind), abs_root, new_sub });
                continue;
            },
        }
    }
}

const DtioEnum = enum { no, cyclic, yes };
fn genDependencyOrder(dep: PackageID, deps: *PackageQueue, dtio: []DtioEnum, out: *std.ArrayListUnmanaged(PackageID)) !void {
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

const PackageInfo = struct {
    gpa: std.mem.Allocator,
    file: ?[:0]const u8,
    ast: ?std.zig.Ast,
    zoir: ?std.zig.Zoir,
    paths: []const []const u8,
    dependencies: std.AutoArrayHashMapUnmanaged(PackageID, DependencyInfo),
    dependents: TypesafeSlice(DependentsListIndex, PackageID).Subslice = .{ .start = 0, .len = 0 },
    name: ?[]const u8 = null,

    is_local: bool,
    generated_zon: ?struct {
        url: []const u8,
        hash: []const u8,
    } = null,
    defined: bool = true,

    const DependencyInfo = struct {
        ast_node: std.zig.Ast.Node.Index,
        lazy: bool,
    };

    pub fn deinit(self: *PackageInfo) void {
        if (self.file) |file| self.gpa.free(file);
        if (self.ast) |*ast| ast.deinit(self.gpa);
        if (self.zoir) |*zoir| zoir.deinit(self.gpa);
        if (self.generated_zon) |gzn| {
            self.gpa.free(gzn.url);
            self.gpa.free(gzn.hash);
        }
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

pub fn fillDependency(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, package_id: PackageID, deps_queue: *PackageQueue, context: *const Context) !void {
    const fullpath = deps_queue.getAbsolutePath(package_id);
    const is_local = std.mem.startsWith(u8, fullpath, context.update_root);
    const filepath = try std.fs.path.join(arena, &.{ fullpath, "build.zig.zon" });
    const file = std.Io.Dir.cwd().readFileAllocOptions(io, filepath, gpa, .unlimited, .of(u8), 0) catch |e| switch (e) {
        error.FileNotFound => {
            deps_queue.setZon(package_id, .{
                .gpa = gpa,
                .file = null,
                .ast = null,
                .zoir = null,
                .paths = default_paths,
                .dependencies = .empty,
                .is_local = is_local,
            });
            return;
        },
        else => |ee| return ee,
    };
    errdefer gpa.free(file);

    var ast = try std.zig.Ast.parse(gpa, file, .zon);
    errdefer ast.deinit(gpa);

    // now we parse the contents with zoir
    var zoir = try std.zig.ZonGen.generate(gpa, ast, .{});
    errdefer zoir.deinit(gpa);

    var dependencies: std.AutoArrayHashMapUnmanaged(PackageID, PackageInfo.DependencyInfo) = .empty;
    errdefer dependencies.deinit(gpa);

    // now, parse from the zoir
    const parsed = try std.zon.parse.fromZoirNodeAlloc(struct {
        paths: ?[]const []const u8 = null,
        dependencies: ?std.zig.Zoir.Node.Index = null,
        name: ?std.zig.Zoir.Node.Index = null,
    }, arena, ast, zoir, .root, null, .{
        .ignore_unknown_fields = true,
        .free_on_error = false,
    });
    if (parsed.dependencies) |parsed_deps| {
        const fields = try structFields(zoir, parsed_deps);
        for (fields.names, 0..fields.vals.len) |name, idx| {
            const field_value_node = fields.vals.at(@intCast(idx));
            const dep_parsed = try std.zon.parse.fromZoirNodeAlloc(struct {
                hash: ?[]const u8 = null,
                url: ?[]const u8 = null,
                path: ?[]const u8 = null,
                lazy: bool = false,
            }, arena, ast, zoir, field_value_node, null, .{
                .ignore_unknown_fields = true,
                .free_on_error = false,
            });
            // now, we parse value as struct { hash: ?[]const u8 = null, path: ?[]const u8 = null }

            var res_path: ?[]const u8 = null;
            if (dep_parsed.path) |path| {
                // local
                res_path = try std.fs.path.join(arena, &.{ fullpath, path });
            } else if (dep_parsed.hash) |hash| {
                if (context.global_cache_dir == null) continue; // global packages excluded
                res_path = try std.fs.path.join(arena, &.{ context.global_cache_dir.?, "p", hash });
            } else {
                // error
                std.log.err("package {s} has neither path nor hash", .{name.get(zoir)});
                return error.Errored;
            }
            const res_real = std.Io.Dir.realPathFileAbsoluteAlloc(io, res_path.?, arena) catch |e| switch (e) {
                error.FileNotFound => {
                    std.log.warn("missing path .{s} = {s} / maybe you need to run `zig build --fetch=all`?", .{ name.get(zoir), res_path.? });
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
            gpres.value_ptr.* = .{
                .ast_node = field_value_node.getAstNode(zoir),
                .lazy = dep_parsed.lazy,
            };
        }
    }

    var name: ?[]const u8 = null;
    if (parsed.name) |name_id| {
        const node = name_id.get(zoir);
        if (node == .enum_literal) {
            name = node.enum_literal.get(zoir);
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
        .is_local = is_local,
        .name = name,
    });
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
