const std = @import("std");
const anywhere = @import("anywhere");
const util = anywhere.util;
const Grid = anywhere.util.grid.Grid;
const zpool = anywhere.util.zpool;
const printer = @import("print.zig");

// N³? that might be problematic
// it's okay to use floats here because these values aren't stored in the world,
//      they are only used to determine which fuses/wires should break.
// before sending here, we should find which networks are the same and make
//      sure their total src+dst add up. if not, we can reduce generator output or
//      turn off sinks.

// power:
// - fuses (after calculating, if the wire segment has too much power going through it, break the fuse)
// - wires (after calculating, if the wire segment has too much power, spend energy on heating until
//             it melts. since the wire is not very much mass compared to the surroundings, we can heat
//             it up very hot without it getting the surrouding air too hot)
// - mybe consider doing xyz at a (lhs):(rhs) ratio (rhs)/(lhs+rhs)

pub const Node = struct {
    intrinsic_value: f64 = 0,
};
pub const Link = struct {
    src: usize,
    dst: usize,
    cost: f64,
    value: f64 = 0, // positive = src->dst, negative = dst->src
};

pub const PowerNetwork = struct {
    nodes: std.ArrayList(Node),
    links: std.ArrayList(Link),
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) PowerNetwork {
        return .{
            .nodes = .empty,
            .links = .empty,
            .gpa = gpa,
        };
    }
    pub fn deinit(self: *PowerNetwork) void {
        self.nodes.deinit(self.gpa);
        self.links.deinit(self.gpa);
    }

    pub fn calculate(self: *PowerNetwork) !void {
        if (self.nodes.items.len == 0) return;

        for (self.links.items) |*link| {
            link.value = 0;
        }

        const size = self.nodes.items.len - 1;
        if (size <= 0) return;

        const G_base = try self.gpa.alloc(usize, size);
        defer self.gpa.free(G_base);
        for (G_base, 0..) |*res, i| res.* = i;
        const G_values = try self.gpa.alloc(f64, size * size);
        defer self.gpa.free(G_values);
        @memset(G_values, 0);

        const I = try self.gpa.alloc(f64, size);
        defer self.gpa.free(I);
        @memset(I, 0);

        for (I, self.nodes.items[0..size]) |*res, *node| {
            res.* = node.intrinsic_value;
        }

        for (self.links.items) |*link| {
            const u = link.src;
            const v = link.dst;

            const cost: f64 = link.cost;
            const conductance: f64 = @as(f64, 1.0) / cost;

            if (u < size) {
                G_values[G_base[u] * size + u] += conductance;
                if (v < size) {
                    G_values[G_base[u] * size + v] -= conductance;
                }
            }

            if (v < size) {
                G_values[G_base[v] * size + v] += conductance;
                if (u < size) {
                    G_values[G_base[v] * size + u] -= conductance;
                }
            }
        }

        const potentials = try self.gpa.alloc(f64, size);
        defer self.gpa.free(potentials);
        @memset(potentials, 0);

        solveGaussian(G_base, G_values, I, potentials);

        for (self.links.items) |*link| {
            const v_src: f64 = if (link.src >= size) 0 else potentials[link.src];
            const v_dst: f64 = if (link.dst >= size) 0 else potentials[link.dst];
            const cost: f64 = link.cost;
            const current = (v_src - v_dst) / cost;
            link.value = current;
        }
    }
};

fn solveGaussian(A_base: []usize, A_values: []f64, b: []f64, x: []f64) void {
    const n = A_base.len;
    std.debug.assert(n == b.len);
    std.debug.assert(n == x.len);
    if (n == 0) return;

    for (0..n) |i| {
        var max_row = i;
        for (i + 1..n) |k| {
            if (@abs(A_values[A_base[k] * n + i]) > @abs(A_values[A_base[max_row] * n + i])) {
                max_row = k;
            }
        }

        std.mem.swap(usize, &A_base[max_row], &A_base[i]);
        std.mem.swap(f64, &b[max_row], &b[i]);

        for (i + 1..n) |k| {
            if (@abs(A_values[A_base[i] * n + i]) < 1e-10) continue;
            const factor = A_values[A_base[k] * n + i] / A_values[A_base[i] * n + i];
            b[k] -= factor * b[i];
            for (i..n) |j| {
                A_values[A_base[k] * n + j] -= factor * A_values[A_base[i] * n + j];
            }
        }
    }

    var i: usize = n;
    @memset(x, 0);
    while (i > 0) {
        i -= 1;

        if (@abs(A_values[A_base[i] * n + i]) < 1e-10) {
            x[i] = 0;
            continue;
        }
        var sum: f64 = 0;
        for (i + 1..n) |j| {
            sum += A_values[A_base[i] * n + j] * x[j];
        }
        x[i] = (b[i] - sum) / A_values[A_base[i] * n + i];
    }
}

test "power" {
    std.testing.log_level = .info;
    const gpa = std.testing.allocator;
    var network: PowerNetwork = .init(gpa);
    defer network.deinit();

    const generator = network.nodes.items.len;
    try network.nodes.append(network.gpa, .{
        .intrinsic_value = 1080,
    });
    const consumer = network.nodes.items.len;
    try network.nodes.append(network.gpa, .{
        .intrinsic_value = -1080,
    });
    const connection = network.links.items.len;
    try network.links.append(network.gpa, .{
        .src = generator,
        .dst = consumer,
        .cost = 2000,
    });

    try network.calculate();

    _ = connection;
    try printer.snapshotPrint(&network).snap(@src(),
        \\*: struct:
        \\ nodes: struct:
        \\  items: slice:
        \\   0: struct:
        \\    intrinsic_value: 1080
        \\   1: struct:
        \\    intrinsic_value: -1080
        \\  capacity: 16
        \\ links: struct:
        \\  items: slice:
        \\   0: struct:
        \\    src: 0
        \\    dst: 1
        \\    cost: 2000
        \\    value: 1080
        \\  capacity: 4
        \\ gpa: std.testing.allocator
    );
}
