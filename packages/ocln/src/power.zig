const std = @import("std");
const anywhere = @import("anywhere");
const util = anywhere.util;
const Grid = anywhere.util.grid.Grid;
const zpool = anywhere.util.zpool;

// power:
// - fuses (after calculating, if the wire segment has too much power going through it, break the fuse)
// - wires (after calculating, if the wire segment has too much power, spend energy on heating until
//             it melts. since the wire is not very much mass compared to the surroundings, we can heat
//             it up very hot without it getting the surrouding air too hot)
// - mybe consider doing xyz at a (lhs):(rhs) ratio (rhs)/(lhs+rhs)

const Node = struct {
    links: [4]LinkPool.Handle = @splat(.nil),
    intrinsic_kJph: i64 = 0,
};
const Link = struct {
    src: NodePool.Handle,
    dst: NodePool.Handle,
    cost_mm: u64,
    value_kJph: i64, // positive = src->dst, negative = dst->src
};

const NodePool = zpool.Pool(16, 16, Node, struct { ptr: Node });
const LinkPool = zpool.Pool(16, 16, Link, struct { ptr: Link });

const PowerNetwork = struct {
    nodes: NodePool,
    links: LinkPool,
    fn init(gpa: std.mem.Allocator) PowerNetwork {
        return .{
            .nodes = .init(gpa),
            .links = .init(gpa),
        };
    }
    fn deinit(self: *PowerNetwork) void {
        self.nodes.deinit();
        self.links.deinit();
    }
};

test "power" {
    const gpa = std.testing.allocator;
    var network: PowerNetwork = .init(gpa);
    defer network.deinit();

    {
        const generator = network.nodes.add(.{ .ptr = .{
            .intrinsic_kJph = 1080,
        } });
        const consumer = network.nodes.add(.{ .ptr = .{
            .intrinsic_kJph = -1080,
        } });
        network.links.add(.{
            .src = generator,
            .dst = consumer,
            .cost_mm = 2000,
            .value_kJph = 0,
        });
    }
}
