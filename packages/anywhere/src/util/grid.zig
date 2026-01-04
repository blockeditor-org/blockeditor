pub const vec2i32 = @Vector(2, i32);
pub const vec2usize = @Vector(2, usize);

pub fn posToIndex(size: vec2usize, pos: vec2i32) ?usize {
    const min: vec2i32 = .{ 0, 0 };
    const max: vec2i32 = @intCast(size);
    if (@reduce(.Or, pos < min) or @reduce(.Or, pos >= max)) return null;
    const cast: vec2usize = @intCast(pos);
    return cast[1] * @as(usize, @intCast(size[0])) + cast[0];
}

pub fn Grid(comptime Child: type) type {
    return struct {
        items: []Child,
        size: vec2usize,

        const Self = @This();

        pub fn init(gpa: std.mem.Allocator, size: vec2usize) !Self {
            const items = try gpa.alloc(Child, size[0] * size[1]);
            errdefer gpa.free(items);
            return .{ .items = items, .size = size };
        }
        pub fn deinit(this: *Self, gpa: std.mem.Allocator) void {
            gpa.free(this.items);
        }
        pub fn get(this: *const Self, pos: vec2i32) Child {
            const idx = posToIndex(this.size, pos) orelse return .empty;
            return this.items[idx];
        }
        pub fn ptr(this: *const Self, pos: vec2i32) *Child {
            const idx = posToIndex(this.size, pos) orelse return .empty;
            return &this.items[idx];
        }
        pub fn set(this: *const Self, pos: vec2i32, value: Child) void {
            const idx = posToIndex(this.size, pos) orelse return;
            this.items[idx] = value;
        }
    };
}

const std = @import("std");
