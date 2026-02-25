// given the packages folder:
// - loop over each item
// - find all deps
// - store in a hashmap that maps from absolute_path to dependencies (absolute paths)
// - now, go in dependency order:
//   - render the build.zig.zon for the dep
//   - package the dep to a .tar.gz file, including only the specified paths
//   - use the zig package manager commands to determine the hash of the packaged file
// when rendering the build.zig.zon, we will use a prefix (ie github release) and then filename for the url

const std = @import("std");

pub fn main() !u8 {
    var gpa_backing = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa_backing.deinit() == .ok);
    const gpa = gpa_backing.allocator();
    var arena_backing = std.heap.ArenaAllocator.init(gpa);
    defer arena_backing.deinit();
    const arena = arena_backing.allocator();

    var dependency_name_to_index: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer dependency_name_to_index.deinit(gpa);
    var queue: std.ArrayList(usize) = .empty;
    defer queue.deinit(gpa);

    var dir = try std.fs.cwd().openDir("packages", .{ .iterate = true });
    var dir_iter = dir.iterate();
    var has_error = false;
    while (try dir_iter.next()) |entry| {
        const filepath = try std.fs.path.join(arena, &.{ "packages", entry.name });
        const fullpath = try std.fs.cwd().realpathAlloc(arena, filepath);
        const zonpath = try std.fs.path.join(arena, &.{ fullpath, "build.zig.zon" });

        try dependency_name_to_index.putNoClobber(gpa, fullpath, {});
        const index = dependency_name_to_index.getIndex(fullpath).?;

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

        try queue.append(gpa, index);
    }

    var queue_idx: usize = 0;
    while (queue_idx < queue.items.len) : (queue_idx += 1) {
        const index = queue.items[queue_idx];
        const item = dependency_name_to_index.keys()[index];
        handleOneFile(gpa, arena, item) catch |e| {
            has_error = true;
            std.log.err("{s}: error: {s}", .{ item, @errorName(e) });
            continue;
        };
    }

    if (has_error) return 1;
    return 0;
}

pub fn handleOneFile(gpa: std.mem.Allocator, arena: std.mem.Allocator, fullpath: []const u8) !void {
    const filepath = try std.fs.path.join(arena, &.{ fullpath, "build.zig.zon" });
    const file = std.fs.cwd().readFileAllocOptions(gpa, filepath, std.math.maxInt(usize), null, .of(u8), 0) catch |e| switch (e) {
        error.FileNotFound => {
            // TODO: default to paths = .{""} and dependencies = &.{}
            return;
        },
        else => |ee| return ee,
    };
    defer gpa.free(file);

    std.log.info("\n\nread file {s}", .{filepath});

    var ast = try std.zig.Ast.parse(gpa, file, .zon);
    defer ast.deinit(gpa);

    // we are extracting paths and dependencies, and then we are replacing dependencies with our own

    var root: std.StringArrayHashMapUnmanaged(std.zig.Ast.Node.Index) = .empty;
    defer root.deinit(gpa);
    try parseStruct(gpa, ast, ast.rootDecls()[0], &root);

    if (root.get("dependencies")) |deps_idx| {
        var deps: std.StringArrayHashMapUnmanaged(std.zig.Ast.Node.Index) = .empty;
        defer deps.deinit(gpa);
        try parseStruct(gpa, ast, deps_idx, &deps);

        for (deps.keys(), deps.values()) |name, value| {
            // ok we got all we needed out of ast, now we can use zoir
            std.log.info("- .{s} = {s}", .{ name, @tagName(ast.nodeTag(value)) });
        }
    }

    // now, parse dependencies (we could use std.zon to make this easy maybe?)
    // then, parse paths
    // then, save the ast along with the dependencies token index so we can replace it for rendering

    // when we're done, we need to render ast but replace_nodes_with_node dependencies with a new dependencies node
    // ast.render(gpa, w, .{ .replace_nodes_with_node =  })
    // arguably we should use replace_nodes_with_string along with std.zon.stringify
    // ast.render(gpa: Allocator, w: *Writer, fixups: Fixups)
}

fn parseStruct(gpa: std.mem.Allocator, ast: std.zig.Ast, node: std.zig.Ast.Node.Index, out: *std.StringArrayHashMapUnmanaged(std.zig.Ast.Node.Index)) !void {
    var buf: [2]std.zig.Ast.Node.Index = undefined;
    const struct_init = ast.fullStructInit(&buf, node) orelse return error.MissingRoot;

    for (struct_init.ast.fields) |field_init| {
        const init_token = ast.firstToken(field_init);
        const field_name_token = init_token - 2;
        std.debug.assert(ast.tokenTag(field_name_token) == .identifier);
        const field_name = ast.tokenSlice(field_name_token);

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
