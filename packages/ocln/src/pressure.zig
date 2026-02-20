const std = @import("std");
const print = @import("print.zig");
const anywhere = @import("anywhere");
const Grid = anywhere.util.grid.Grid;
const vec = anywhere.util.vec;

// scenerios to test:
// stable states:
// - [x] 2x2 water with 1x2 air above and tiles all around.
//        - make sure the tiles still only get 100kN of air pressure even though there's two air tiles both pushing on the water 100kN each.
//        - should they only get 100kN air pressure? surely right?
// - similar to the top one, one container fully filled with water connected to one half water half air.
//   the one fully filled with water can't drain at all.
//   - make sure the air does not change in pressure.
// unstable states:
// - two containers connected at the bottom. one has 75% water, one 25% water.
//   they should cause the air pressures to change and get more level.
// - air pressure powered siphon? chain powered siphon?

const ResponsePattern = enum {
    // force is reflected
    solid,
    // force is distributed to all other edges
    liquid,
    // P=F/A
    gas,
};
const GraphNode = struct {
    size_m3: f64,
    response_pattern: ResponsePattern,

    /// we should be able to remove this by adding it directly into the outgoing forces in the update function
    edge_intrinsic_force_N: []f64,
    edge_incoming_force_N: []f64,
    edge_outgoing_force_N: []f64,
    edge_nodes: []usize,
    edge_indices: []usize,
    edge_sizes_m2: []f64,
};
const Graph = struct {
    nodes: []GraphNode,

    pub fn printCustomFormat(printer: *print.Printer, arg: print.DetailedAny) !void {
        const graph = arg.cast(Graph);
        try printer.print("Graph:", .{});
        printer.indent();
        defer printer.dedent();
        for (graph.nodes, 0..) |*node, index| {
            try printer.newline();
            try printer.dump(.fromAuto(&index));
            try printer.print(": .{s}:", .{@tagName(node.response_pattern)});
            printer.indent();
            defer printer.dedent();
            for (0.., node.edge_nodes, node.edge_indices, node.edge_incoming_force_N, node.edge_outgoing_force_N, node.edge_intrinsic_force_N) |i, target, target_index, incoming, outgoing, intrinsic| {
                try printer.newline();
                try printer.print("{d}[{d}]->{d}[{d}] received {d:.2} / sent {d:.2}kN / intrinsic {d:.2}", .{ index, i, target, target_index, incoming / 1000, outgoing / 1000, intrinsic / 1000 });
            }
        }
    }
};

fn updateSolid(node: *GraphNode) void {
    for (node.edge_incoming_force_N, node.edge_outgoing_force_N) |incoming, *outgoing| {
        outgoing.* = incoming;
    }
}
fn updateLiquid(node: *GraphNode) void {
    // this doesn't seem right - if two sides have force, shouldn't the output go to the two remaining sides?
    var total_size_m: f64 = 0;
    var total_incoming_N: f64 = 0;
    for (node.edge_sizes_m2, node.edge_incoming_force_N) |edge_size_m, incoming_N| {
        total_size_m += edge_size_m;
        total_incoming_N += incoming_N;
    }
    for (node.edge_sizes_m2, node.edge_incoming_force_N, node.edge_outgoing_force_N) |edge_size_m, incoming_N, *outgoing_N| {
        outgoing_N.* = (total_incoming_N - incoming_N) * (edge_size_m / (total_size_m - edge_size_m));
    }
}
fn updateGas(node: *GraphNode) void {
    for (node.edge_incoming_force_N, node.edge_outgoing_force_N) |incoming, *outgoing| {
        // TODO we need to absorb some of the force and send some back.
        //absorbing means we will physically get smaller.
        _ = incoming;
        outgoing.* = 0;
    }
}
fn updateNode(node: *GraphNode) void {
    return switch (node.response_pattern) {
        .solid => updateSolid(node),
        .liquid => updateLiquid(node),
        .gas => updateGas(node),
    };
}
fn update(graph: *Graph) void {
    // first, send outgoing to incoming
    for (graph.nodes) |*node| {
        for (node.edge_intrinsic_force_N, node.edge_outgoing_force_N, node.edge_nodes, node.edge_indices) |from_intrinsic, from_outgoing, to_node, to_index| {
            const to = &graph.nodes[to_node];
            const to_incoming = &to.edge_incoming_force_N[to_index];
            const to_intrinsic = to.edge_intrinsic_force_N[to_index];
            to_incoming.* = from_intrinsic + from_outgoing - to_intrinsic;
        }
    }
    // clear outgoings
    for (graph.nodes) |*node| {
        for (node.edge_outgoing_force_N) |*outgoing| {
            outgoing.* = 0;
        }
    }
    // then, apply incoming to outgoing
    for (graph.nodes) |*node| updateNode(node);
}

const Tile = enum {
    none,
    air,
    water,
    tile,
};
fn generateGraph(arena: std.mem.Allocator, grid: *const Grid(2, i32, Tile)) !*Graph {
    var coordinate_to_node_index = std.AutoArrayHashMap(vec.by2i32, usize).init(arena);
    var tiles = std.ArrayList(GraphNode).empty;

    // first pass: define all nodes
    {
        var iter = vec.Iterator(2, i32).size(@intCast(grid.size));
        while (iter.next()) |coord| {
            const value = grid.get(coord) orelse continue;
            if (value == .none) continue;
            try coordinate_to_node_index.putNoClobber(coord, tiles.items.len);
            try tiles.append(arena, undefined);
        }
    }
    // second pass: define all links
    {
        var iter = vec.Iterator(2, i32).posSize(.{ 0, 0 }, @intCast(grid.size));
        while (iter.next()) |coord| {
            const value = grid.get(coord) orelse continue;
            if (value == .none) continue;

            const directions = [_]vec.by2i32{
                vec.by2i32{ 0, 1 },
                vec.by2i32{ 0, -1 },
                vec.by2i32{ 1, 0 },
                vec.by2i32{ -1, 0 },
            };
            var results = std.MultiArrayList(struct {
                intrinsic_force_N: f64,
                incoming_force_N: f64,
                outgoing_force_N: f64,
                node: usize,
                index: usize,
                size_m2: f64,
            }).empty;
            for (directions) |direction| {
                const target = coordinate_to_node_index.get(coord + direction) orelse continue;

                const intrinsic_force_N: f64 = switch (value) {
                    .none => unreachable,
                    .air => 100_000, // 100kPa over 1m² = 100kN
                    .water => blk: {
                        if (direction[1] == -1) break :blk 10_000_000; // 1Mg (t) with 10m/s² gravity = 10MN
                        if (direction[1] == 0) break :blk 5_000_000; // half of the down force
                        break :blk 0;
                    },
                    .tile => 0, // tiles are stuck to the background, there is no gravity. we could have some tiles with gravity.
                };
                var target_index: usize = 0; // hacky method to get the index of the backref. we could use a third pass to set the backrefs instead.
                for (directions) |dir2| {
                    if (coordinate_to_node_index.get(coord + direction + dir2) == null) continue;
                    if (@reduce(.And, dir2 == direction * @as(vec.by2i32, @splat(-1)))) break;
                    target_index += 1;
                } else unreachable;

                try results.append(arena, .{
                    .intrinsic_force_N = intrinsic_force_N,
                    .incoming_force_N = 0,
                    .outgoing_force_N = 0,
                    .node = target,
                    .index = target_index,
                    .size_m2 = 1,
                });
            }
            const final = results.toOwnedSlice();

            const index = coordinate_to_node_index.get(coord).?;
            tiles.items[index] = .{
                .size_m3 = 1,
                .response_pattern = switch (value) {
                    .none => unreachable,
                    .air => .gas,
                    .water => .liquid,
                    .tile => .solid,
                },
                .edge_intrinsic_force_N = final.items(.intrinsic_force_N),
                .edge_incoming_force_N = final.items(.incoming_force_N),
                .edge_outgoing_force_N = final.items(.outgoing_force_N),
                .edge_nodes = final.items(.node),
                .edge_indices = final.items(.index),
                .edge_sizes_m2 = final.items(.size_m2),
            };
        }
    }

    const result = try arena.create(Graph);
    result.* = .{ .nodes = try tiles.toOwnedSlice(arena) };
    return result;
}

test "pressure" {
    // generate a graph. there is 1m³ air and 1m³ water
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    var grid: Grid(2, i32, Tile) = .empty;
    try grid.resize(arena, .{ 20, 20 });
    grid.fill(.none);
    // sample
    _ = grid.set(.{ 10, 7 }, .tile);
    _ = grid.set(.{ 11, 7 }, .tile);
    _ = grid.set(.{ 12, 7 }, .tile);
    _ = grid.set(.{ 13, 7 }, .tile);

    _ = grid.set(.{ 10, 6 }, .tile);
    _ = grid.set(.{ 11, 6 }, .air);
    _ = grid.set(.{ 12, 6 }, .air);
    _ = grid.set(.{ 13, 6 }, .tile);

    _ = grid.set(.{ 10, 5 }, .tile);
    _ = grid.set(.{ 11, 5 }, .water);
    _ = grid.set(.{ 12, 5 }, .water);
    _ = grid.set(.{ 13, 5 }, .tile);

    _ = grid.set(.{ 10, 4 }, .tile);
    _ = grid.set(.{ 11, 4 }, .tile);
    _ = grid.set(.{ 12, 4 }, .tile);
    _ = grid.set(.{ 13, 4 }, .tile);

    const graph = try generateGraph(arena, &grid);

    // if (true) return error.SkipZigTest; // TODO we need to actually test stuff instead of printing

    for (0..10000) |_| update(graph);

    try anywhere.util.testing.snap(@src(), print.snapshotPrint(graph),
        \\*: Graph:
        \\ 0: .solid:
        \\  0[0]->4[1] received 0.00 / sent 0.00kN / intrinsic 0.00
        \\  0[1]->1[2] received 0.00 / sent 0.00kN / intrinsic 0.00
        \\ 1: .solid:
        \\  1[0]->5[1] received 10100.00 / sent 10100.00kN / intrinsic 0.00
        \\  1[1]->2[2] received 0.00 / sent 0.00kN / intrinsic 0.00
        \\  1[2]->0[1] received 0.00 / sent 0.00kN / intrinsic 0.00
        \\ 2: .solid:
        \\  2[0]->6[1] received 10100.00 / sent 10100.00kN / intrinsic 0.00
        \\  2[1]->3[1] received 0.00 / sent 0.00kN / intrinsic 0.00
        \\  2[2]->1[1] received 0.00 / sent 0.00kN / intrinsic 0.00
        \\ 3: .solid:
        \\  3[0]->7[1] received 0.00 / sent 0.00kN / intrinsic 0.00
        \\  3[1]->2[1] received 0.00 / sent 0.00kN / intrinsic 0.00
        \\ 4: .solid:
        \\  4[0]->8[1] received 0.00 / sent 0.00kN / intrinsic 0.00
        \\  4[1]->0[0] received 0.00 / sent 0.00kN / intrinsic 0.00
        \\  4[2]->5[3] received 5100.00 / sent 5100.00kN / intrinsic 0.00
        \\ 5: .liquid:
        \\  5[0]->9[1] received 100.00 / sent 100.00kN / intrinsic 0.00
        \\  5[1]->1[0] received 100.00 / sent 100.00kN / intrinsic 10000.00
        \\  5[2]->6[3] received 100.00 / sent 100.00kN / intrinsic 5000.00
        \\  5[3]->4[2] received 100.00 / sent 100.00kN / intrinsic 5000.00
        \\ 6: .liquid:
        \\  6[0]->10[1] received 100.00 / sent 100.00kN / intrinsic 0.00
        \\  6[1]->2[0] received 100.00 / sent 100.00kN / intrinsic 10000.00
        \\  6[2]->7[2] received 100.00 / sent 100.00kN / intrinsic 5000.00
        \\  6[3]->5[2] received 100.00 / sent 100.00kN / intrinsic 5000.00
        \\ 7: .solid:
        \\  7[0]->11[1] received 0.00 / sent 0.00kN / intrinsic 0.00
        \\  7[1]->3[0] received 0.00 / sent 0.00kN / intrinsic 0.00
        \\  7[2]->6[2] received 5100.00 / sent 5100.00kN / intrinsic 0.00
        \\ 8: .solid:
        \\  8[0]->12[0] received 0.00 / sent 0.00kN / intrinsic 0.00
        \\  8[1]->4[0] received 0.00 / sent 0.00kN / intrinsic 0.00
        \\  8[2]->9[3] received 100.00 / sent 100.00kN / intrinsic 0.00
        \\ 9: .gas:
        \\  9[0]->13[0] received 0.00 / sent 0.00kN / intrinsic 100.00
        \\  9[1]->5[0] received 0.00 / sent 0.00kN / intrinsic 100.00
        \\  9[2]->10[3] received 0.00 / sent 0.00kN / intrinsic 100.00
        \\  9[3]->8[2] received 0.00 / sent 0.00kN / intrinsic 100.00
        \\ 10: .gas:
        \\  10[0]->14[0] received 0.00 / sent 0.00kN / intrinsic 100.00
        \\  10[1]->6[0] received 0.00 / sent 0.00kN / intrinsic 100.00
        \\  10[2]->11[2] received 0.00 / sent 0.00kN / intrinsic 100.00
        \\  10[3]->9[2] received 0.00 / sent 0.00kN / intrinsic 100.00
        \\ 11: .solid:
        \\  11[0]->15[0] received 0.00 / sent 0.00kN / intrinsic 0.00
        \\  11[1]->7[0] received 0.00 / sent 0.00kN / intrinsic 0.00
        \\  11[2]->10[2] received 100.00 / sent 100.00kN / intrinsic 0.00
        \\ 12: .solid:
        \\  12[0]->8[0] received 0.00 / sent 0.00kN / intrinsic 0.00
        \\  12[1]->13[2] received 0.00 / sent 0.00kN / intrinsic 0.00
        \\ 13: .solid:
        \\  13[0]->9[0] received 100.00 / sent 100.00kN / intrinsic 0.00
        \\  13[1]->14[2] received 0.00 / sent 0.00kN / intrinsic 0.00
        \\  13[2]->12[1] received 0.00 / sent 0.00kN / intrinsic 0.00
        \\ 14: .solid:
        \\  14[0]->10[0] received 100.00 / sent 100.00kN / intrinsic 0.00
        \\  14[1]->15[1] received 0.00 / sent 0.00kN / intrinsic 0.00
        \\  14[2]->13[1] received 0.00 / sent 0.00kN / intrinsic 0.00
        \\ 15: .solid:
        \\  15[0]->11[0] received 0.00 / sent 0.00kN / intrinsic 0.00
        \\  15[1]->14[1] received 0.00 / sent 0.00kN / intrinsic 0.00
    );
}
