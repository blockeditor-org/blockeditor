const std = @import("std");
const print = @import("print.zig");
const anywhere = @import("anywhere");
const Grid = anywhere.util.grid.Grid;
const vec = anywhere.util.vec;

// scenerios to test:
// stable states:
// - 2x2 water with 1x2 air above and tiles all around.
//   - make sure the tiles still only get 100kN of air pressure even though there's two air tiles both pushing on the water 100kN each.
//   - should they only get 100kN air pressure? surely right?
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

    edge_intrinsic_force_N: []f64, // can this be a node? maybe? should it be? unclear
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
                try printer.print("{d}[{d}]->{d}[{d}] received {d:.2}      \tsent {d:.2}kN     \tintrinsic {d:.2}", .{ index, i, target, target_index, incoming / 1000, outgoing / 1000, intrinsic / 1000 });
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
                var target_index: usize = 0; // hacky method to get the index of the backref
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
    _ = grid.set(.{ 10, 6 }, .air);
    _ = grid.set(.{ 10, 5 }, .water);
    _ = grid.set(.{ 10, 4 }, .tile);
    _ = grid.set(.{ 9, 5 }, .tile);
    _ = grid.set(.{ 11, 5 }, .tile);
    _ = grid.set(.{ 9, 6 }, .tile);
    _ = grid.set(.{ 11, 6 }, .tile);
    _ = grid.set(.{ 10, 7 }, .tile);
    const graph = try generateGraph(arena, &grid);

    std.log.info("\n{f}", .{print.autoPrint(graph)});
    std.log.info("...step", .{});
    for (0..10000) |_| update(graph);
    std.log.info("\n{f}", .{print.autoPrint(graph)});
}
