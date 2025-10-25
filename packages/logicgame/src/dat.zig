const std = @import("std");
const util = @import("util.zig");
const GenerationalPool = @import("generational_pool.zig").GenerationalPool;

const ivec2 = @Vector(2, i32);

test "dat" {
    const gpa = std.testing.allocator;

    var board: Board = .init(gpa);
    defer board.deinit();

    try util.formattedSnapshot(gpa, "{f}", .{board}, @src(),
        \\components:
        \\wires:
        \\
    );
    board.onMouseOp(.{ 5, 7 }, .down);
    try util.formattedSnapshot(gpa, "{f}", .{board}, @src(),
        \\components:
        \\wires:
        \\- wire_1: [inactive] 5,7 -> 5,7
        \\
    );
    board.onMouseOp(.{ 6, 7 }, .drag);
    try util.formattedSnapshot(gpa, "{f}", .{board}, @src(),
        \\components:
        \\wires:
        \\- wire_1: [inactive] 5,7 -> 6,7
        \\
    );
    board.onMouseOp(.{ 6, 8 }, .drag);
    try util.formattedSnapshot(gpa, "{f}", .{board}, @src(),
        \\components:
        \\wires:
        \\- wire_1: [inactive] 5,7 -> 5,8
        \\
    );
    board.onMouseOp(.{ 5, 8 }, .drag);
    try util.formattedSnapshot(gpa, "{f}", .{board}, @src(),
        \\components:
        \\wires:
        \\- wire_1: [inactive] 5,7 -> 5,8
        \\
    );
    board.onMouseOp(.{ 5, 3 }, .drag);
    try util.formattedSnapshot(gpa, "{f}", .{board}, @src(),
        \\components:
        \\wires:
        \\- wire_1: [inactive] 5,7 -> 5,3
        \\
    );
    board.onMouseOp(.{ 3, 7 }, .drag);
    try util.formattedSnapshot(gpa, "{f}", .{board}, @src(),
        \\components:
        \\wires:
        \\- wire_1: [inactive] 5,7 -> 3,7
        \\
    );
    board.onMouseOp(.{ 2, 6 }, .up);
    try util.formattedSnapshot(gpa, "{f}", .{board}, @src(),
        \\components:
        \\wires:
        \\- wire_1: 5,7 -> 2,7
        \\
    );

    board.onPlaceComponent(.{ 1, 4 }, .{ .id = .not, .size = .{ 1, 3 } });
    try util.formattedSnapshot(gpa, "{f}", .{board}, @src(),
        \\components:
        \\- type: not
        \\  pos: 1,4,1,3
        \\wires:
        \\- wire_1: 5,7 -> 2,7
        \\
    );
}

const ComponentData = struct {
    id: ComponentHash, // content-addressable hash? or just id
    size: @Vector(2, i32),
};
const ComponentHash = enum(u128) {
    none = 0,
    not = 1,
    microled = 2,
    buffer = 3,
};

const Wires = GenerationalPool(Wire, .{ .keep_list = .unordered });
const Components = GenerationalPool(Component, .{ .keep_list = .unordered });
const Board = struct {
    // TODO interactions:
    // - drag existing component (not wire)
    // - delete existing component (right-click?)
    // - box-select (shift left-click?)
    // - add to selection (left-click?)
    // - pan and zoom camera
    // - place new component

    gpa: std.mem.Allocator,
    components: Components,
    wires: Wires,

    placing_wire: ?struct {
        wire: Wires.ID,
        centerpt: ivec2,
    } = null,

    pub fn init(gpa: std.mem.Allocator) Board {
        return .{
            .gpa = gpa,
            .components = .init(gpa),
            .wires = .init(gpa),
        };
    }
    pub fn deinit(board: *Board) void {
        board.components.deinit();
        board.wires.deinit();
    }

    fn normalizeWires() void {
        // TODO: find any wires where a start or end point overlaps another wire
        // split that wire in two
        // skip any wires that are not active, as these wires are not fully placed yet
    }

    pub fn format(board: *const Board, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("components:\n");
        for (board.components.list.items) |component_id| {
            const component = board.components.mut(component_id).?;
            try w.print("- type: {s}\n", .{@tagName(component.data.id)});
            try w.print("  pos: {d},{d},{d},{d}\n", .{ component.ul[0], component.ul[1], component.data.size[0], component.data.size[1] });
        }
        try w.writeAll("wires:\n");
        for (board.wires.list.items) |wire_id| {
            const wire = board.wires.mut(wire_id).?;
            try w.print("- wire_{d}:{s} {d},{d} -> {d},{d}\n", .{
                @as(usize, wire.bitwidth_minus_one) + 1,
                if (wire.active) "" else " [inactive]",
                wire.from[0],
                wire.from[1],
                wire.to[0],
                wire.to[1],
            });
        }
    }

    pub fn onPlaceComponent(board: *Board, cpos: ivec2, cdata: ComponentData) void {
        _ = board.components.add(.{
            .ul = cpos,
            .data = cdata,
            .active = true,
        }) catch return;
    }

    pub fn onMouseOp(board: *Board, mpos: ivec2, op: enum { down, drag, hover, up }) void {
        switch (op) {
            .down => {
                const wire = board.wires.add(.{
                    .from = mpos,
                    .to = mpos,
                    .bitwidth_minus_one = 0,
                    .active = false,
                }) catch return;
                board.placing_wire = .{
                    .wire = wire,
                    .centerpt = mpos,
                };
            },
            .drag, .up => {
                if (board.placing_wire) |pwire| {
                    const mut = board.wires.mut(pwire.wire) orelse {
                        // component del-eted while placing
                        board.placing_wire = null;
                        return;
                    };
                    const centerpt = pwire.centerpt;
                    const target = mpos;
                    const diff = target - centerpt;
                    // now choose axis
                    const absdiff = @abs(diff);
                    var finalsize = diff;
                    if (absdiff[0] > absdiff[1]) {
                        finalsize = .{ diff[0], 0 }; // x axis
                    } else {
                        finalsize = .{ 0, diff[1] }; // y axis
                    }
                    const pos1 = centerpt;
                    const pos2 = centerpt + finalsize;

                    mut.from = pos1;
                    mut.to = pos2;

                    if (op == .up) {
                        mut.active = true;
                        board.placing_wire = null;
                    }
                }
            },
            .hover => {},
        }
    }
};

const Wire = struct {
    from: ivec2,
    to: ivec2,
    bitwidth_minus_one: u6,
    active: bool,
};
const Component = struct {
    ul: ivec2,
    data: ComponentData,
    active: bool,
};

// wire design selection:

//
// a wire connects two wire pads in a horizontal line
// wires can cross over eachother
// if you put a wire pad between two other wire pads, it connects to the wire
// sample
//            _____
//      X    [     ]
// X----+----X NOT X
//      X-X  [_____]
//        |
//        X
//
// components have wire pads on their i/o
//
//
// wires cannot go thru components

// impl changes:
// - we can seperate true components from wires & wire pads
// - when you draw a wire, you place two wire pads and the components connecting them
// - there are no implicit connections (except if you place a wire pad on a wire)
