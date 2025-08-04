//! dep-list.zig

// adapted from https://ziggit.dev/t/simple-dependency-tree-printer/8185

pub fn main() !void {
    if (@import("builtin").target.os.tag == .windows) {
        _ = std.os.windows.kernel32.SetConsoleOutputCP(65001);
    }
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var pkg_cache_dir = try std.fs.cwd().openDir("C:\\Users\\pfg\\AppData\\Local\\zig\\p", .{ .access_sub_paths = true });
    defer pkg_cache_dir.close();

    var buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buffer);
    const out = &stdout_writer.interface;

    try out.writeAll("root:\n");
    try dumpDependenciesRecursive(out, gpa.allocator(), pkg_cache_dir, std.fs.cwd(), "build.zig.zon", 0);

    try out.flush();
}

fn dumpDependenciesRecursive(writer: *std.Io.Writer, gpa: std.mem.Allocator, pkg_cache_dir: std.fs.Dir, dir: std.fs.Dir, path: []const u8, indent: usize) !void {
    var root_deps = getDependenciesFromBuildZon(gpa, dir, path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer {
        for (root_deps.keys(), root_deps.values()) |key, value| {
            gpa.free(key);
            gpa.free(value.hash);
        }
        root_deps.deinit(gpa);
    }

    for (root_deps.keys(), root_deps.values()) |key, pkg_hash| {
        try writer.splatByteAll(' ', indent);
        try writer.print("╰╴{s}: {s}\n", .{ key, pkg_hash.hash });

        const sub_path = try std.fs.path.join(gpa, &.{ pkg_hash.hash, "build.zig.zon" });
        defer gpa.free(sub_path);

        var subdir = if (pkg_hash.path) dir.openDir(std.fs.path.dirname(path) orelse ".", .{}) catch |e| {
            std.log.err("failed to open dir: {s}/{s}", .{ @errorName(e), std.fs.path.dirname(path) orelse "." });
            return e;
        } else pkg_cache_dir;
        defer if (pkg_hash.path) subdir.close();
        try dumpDependenciesRecursive(writer, gpa, pkg_cache_dir, subdir, sub_path, indent + 2);
    }
}
const SV = struct { hash: []const u8, path: bool };

fn getDependenciesFromBuildZon(gpa: std.mem.Allocator, dir: std.fs.Dir, path: []const u8) !std.StringArrayHashMapUnmanaged(SV) {
    var deps = std.StringArrayHashMapUnmanaged(SV){};
    errdefer {
        for (deps.keys(), deps.values()) |key, value| {
            gpa.free(key);
            gpa.free(value.hash);
        }
        deps.deinit(gpa);
    }

    var zon_bytes = try std.ArrayListUnmanaged(u8).initCapacity(gpa, 1024 * 1024);
    defer zon_bytes.deinit(gpa);

    const zon_bytes_slice = try dir.readFile(path, zon_bytes.unusedCapacitySlice());
    zon_bytes.items.len = zon_bytes_slice.len;
    try zon_bytes.append(gpa, 0);
    const zon_bytes_z = zon_bytes.items[0..zon_bytes_slice.len :0];

    var zon_ast = try std.zig.Ast.parse(gpa, zon_bytes_z, .zon);
    defer zon_ast.deinit(gpa);

    const struct_init = zon_ast.structInitDot(zon_ast.rootDecls()[0]);

    for (struct_init.ast.fields) |field_idx| {
        const tok = zon_ast.firstToken(field_idx);

        const name = zon_ast.tokenSlice(tok - 2);
        if (!std.mem.eql(u8, name, "dependencies")) {
            continue;
        }

        var dep_list_struct_buf: [2]std.zig.Ast.Node.Index = undefined;
        const dep_list_struct_init = zon_ast.fullStructInit(&dep_list_struct_buf, field_idx);

        dep_list: for (dep_list_struct_init.?.ast.fields) |dep_list_field_idx| {
            const dep_tok = zon_ast.firstToken(dep_list_field_idx);
            const dep_name = zon_ast.tokenSlice(dep_tok - 2);

            var dep_struct_buf: [2]std.zig.Ast.Node.Index = undefined;
            const dep_struct_init = zon_ast.fullStructInit(&dep_struct_buf, dep_list_field_idx);

            for (dep_struct_init.?.ast.fields) |dep_struct_field_idx| {
                const dep_struct_field_tok = zon_ast.firstToken(dep_struct_field_idx);
                const dep_struct_field_name = zon_ast.tokenSlice(dep_struct_field_tok - 2);
                if (std.mem.eql(u8, dep_struct_field_name, "path")) {
                    const dep_struct_field_val = zon_ast.tokenSlice(dep_struct_field_tok);

                    const dep_name_owned = try gpa.dupe(u8, dep_name);
                    errdefer gpa.free(dep_name);

                    const dep_hash_owned = try gpa.dupe(u8, dep_struct_field_val[1 .. dep_struct_field_val.len - 1]);
                    errdefer gpa.free(dep_hash_owned);

                    const get_or_put = try deps.getOrPut(gpa, dep_name);
                    if (get_or_put.found_existing) {
                        std.log.warn("Found duplicate dependency name: {f}", .{std.zig.fmtId(dep_name)});
                        continue :dep_list;
                    }

                    get_or_put.key_ptr.* = dep_name_owned;
                    get_or_put.value_ptr.* = .{ .hash = dep_hash_owned, .path = true };

                    continue :dep_list;
                }
                if (!std.mem.eql(u8, dep_struct_field_name, "hash")) continue;

                const dep_struct_field_val = zon_ast.tokenSlice(dep_struct_field_tok);

                const dep_name_owned = try gpa.dupe(u8, dep_name);
                errdefer gpa.free(dep_name);

                const dep_hash_owned = try gpa.dupe(u8, dep_struct_field_val[1 .. dep_struct_field_val.len - 1]);
                errdefer gpa.free(dep_hash_owned);

                const get_or_put = try deps.getOrPut(gpa, dep_name);
                if (get_or_put.found_existing) {
                    std.log.warn("Found duplicate dependency name: {f}", .{std.zig.fmtId(dep_name)});
                    continue :dep_list;
                }

                get_or_put.key_ptr.* = dep_name_owned;
                get_or_put.value_ptr.* = .{ .hash = dep_hash_owned, .path = false };

                continue :dep_list;
            }
            std.log.warn("Failed to find info for dependency name: .{f}", .{std.zig.fmtId(dep_name)});
            continue :dep_list;
        }
    }

    return deps;
}

const std = @import("std");
