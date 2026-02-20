const std = @import("std");
const print = @import("print.zig");

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
            try printer.print(": Node:", .{});
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
            to_incoming.* = @max(0, from_intrinsic + from_outgoing - to_intrinsic);
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

test "pressure" {
    // generate a graph. there is 1m³ air and 1m³ water
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    var nodes = [_]GraphNode{
        // air
        .{
            .size_m3 = 1,
            .response_pattern = .gas,
            .edge_intrinsic_force_N = try arena.dupe(f64, &.{100_000}),
            .edge_incoming_force_N = try arena.dupe(f64, &.{0}),
            .edge_outgoing_force_N = try arena.dupe(f64, &.{0}),
            .edge_nodes = try arena.dupe(usize, &.{1}),
            .edge_indices = try arena.dupe(usize, &.{0}),
            .edge_sizes_m2 = try arena.dupe(f64, &.{1}),
        },
        // water
        .{
            .size_m3 = 1,
            .response_pattern = .liquid,
            .edge_intrinsic_force_N = try arena.dupe(f64, &.{ 0, 5_000_000, 10_000_000, 5_000_000 }),
            .edge_incoming_force_N = try arena.dupe(f64, &.{ 0, 0, 0, 0 }),
            .edge_outgoing_force_N = try arena.dupe(f64, &.{ 0, 0, 0, 0 }),
            .edge_nodes = try arena.dupe(usize, &.{ 0, 2, 3, 4 }),
            .edge_indices = try arena.dupe(usize, &.{ 0, 0, 0, 0 }),
            .edge_sizes_m2 = try arena.dupe(f64, &.{ 1, 1, 1, 1 }),
        },
        // tile e
        .{
            .size_m3 = 1,
            .response_pattern = .solid,
            .edge_intrinsic_force_N = try arena.dupe(f64, &.{0}),
            .edge_incoming_force_N = try arena.dupe(f64, &.{0}),
            .edge_outgoing_force_N = try arena.dupe(f64, &.{0}),
            .edge_nodes = try arena.dupe(usize, &.{1}),
            .edge_indices = try arena.dupe(usize, &.{1}),
            .edge_sizes_m2 = try arena.dupe(f64, &.{1}),
        },
        // tile s
        .{
            .size_m3 = 1,
            .response_pattern = .solid,
            .edge_intrinsic_force_N = try arena.dupe(f64, &.{0}),
            .edge_incoming_force_N = try arena.dupe(f64, &.{0}),
            .edge_outgoing_force_N = try arena.dupe(f64, &.{0}),
            .edge_nodes = try arena.dupe(usize, &.{1}),
            .edge_indices = try arena.dupe(usize, &.{2}),
            .edge_sizes_m2 = try arena.dupe(f64, &.{1}),
        },
        // tile w
        .{
            .size_m3 = 1,
            .response_pattern = .solid,
            .edge_intrinsic_force_N = try arena.dupe(f64, &.{0}),
            .edge_incoming_force_N = try arena.dupe(f64, &.{0}),
            .edge_outgoing_force_N = try arena.dupe(f64, &.{0}),
            .edge_nodes = try arena.dupe(usize, &.{1}),
            .edge_indices = try arena.dupe(usize, &.{3}),
            .edge_sizes_m2 = try arena.dupe(f64, &.{1}),
        },
    };
    var graph: Graph = .{
        .nodes = &nodes,
    };

    std.log.info("\n{f}", .{print.autoPrint(&graph)});
    update(&graph);
    std.log.info("\n{f}", .{print.autoPrint(&graph)});
    update(&graph);
    std.log.info("\n{f}", .{print.autoPrint(&graph)});
    update(&graph);
    std.log.info("\n{f}", .{print.autoPrint(&graph)});
    update(&graph);
    std.log.info("...step", .{});
    for (0..1000) |_| update(&graph);
    std.log.info("\n{f}", .{print.autoPrint(&graph)});
}
