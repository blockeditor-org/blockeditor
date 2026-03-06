const std = @import("std");
const main = @import("main.zig");
const Grid = util.grid.Grid;
const anywhere = @import("anywhere");
const util = anywhere.util;

pub const BuildingDescriptor = struct {
    offset: @Vector(2, i32),
    grid: Grid(2, i32, usize),
    flags: []const BuildingDescriptorFlag,
    image: main.Image,
};
pub const BuildingDescriptorFlag = packed struct {
    set_building: bool = false,
    set_power_port: bool = false,
    needs_tile: bool = false,
};
pub const BuildingTag = enum(u16) {
    generator = 1,
    power_outlet = 2,
    /// a lamp plugs into a power port
    /// what we can do is have it so when you click to place the lamp,
    ///   it has you then click where to place the wire. limited to a maximum length, ideally following a catenary,
    ///   using A* pathfinding to route. and you can put the other end wherever but if it's not on a power port
    ///   it will show a warning that it's not plugged in. then you could place a power port under it or if you put
    ///   it somewhere else you could click on it and choose to move it
    /// alternatively, we can have it auto-connect to the nearest one. if we do this then ideally we would also
    ///   auto connect when a new power port is placed, and we would allow infinite connections to each power
    ///   port so we don't need to do rebalancing
    /// alternative three is we just have it attach to the grid directly.
    lamp = 3,
};
pub const building_to_descriptor_map: std.EnumArray(BuildingTag, BuildingDescriptor) = .init(.{
    .generator = @as(BuildingDescriptor, .{
        .offset = .{ 1, 1 },
        .grid = .fromSizeSlice(.{ 3, 5 }, @constCast(&[_]usize{
            // note that this is upside-down
            2, 2, 2,
            0, 0, 1,
            0, 0, 0,
            0, 0, 0,
            0, 0, 0,
        })),
        .flags = &.{
            .{ .set_building = true },
            .{ .set_building = true, .set_power_port = true },
            .{ .needs_tile = true },
        },
        .image = .{
            .world = .from(.{ -1, 0 }, .{ 3, 4 }),
            .spritesheet = .from(.{ 0, 64 }, .{ 48, 64 }),
        },
    }),
    .power_outlet = @as(BuildingDescriptor, .{
        .offset = .{ 0, 0 },
        .grid = .fromSizeSlice(.{ 1, 1 }, @constCast(&[_]usize{
            0,
        })),
        .flags = &.{
            .{ .set_building = true, .set_power_port = true },
        },
        .image = .{
            .world = .from(.{ 0, 0 }, .{ 1, 1 }),
            .spritesheet = .from(.{ 80, 0 }, .{ 16, 16 }),
        },
    }),
    .lamp = @as(BuildingDescriptor, .{
        .offset = .{ 0, 1 },
        .grid = .fromSizeSlice(.{ 1, 3 }, @constCast(&[_]usize{
            1,
            0,
            0,
        })),
        .flags = &.{
            .{ .set_building = true },
            .{ .needs_tile = true },
        },
        .image = .{
            .world = .from(.{ 0, 0 }, .{ 1, 2 }),
            .spritesheet = .from(.{ 144, 0 }, .{ 16, 32 }),
        },
    }),
});
