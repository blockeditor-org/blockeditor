const vec = @import("vector.zig");

pub fn posToIndex(comptime n: comptime_int, comptime Int: type, size: vec.x(n, usize), pos: vec.x(n, Int)) ?usize {
    const min: vec.x(n, Int) = @splat(0);
    const max: vec.x(n, Int) = @intCast(size);
    if (@reduce(.Or, pos < min) or @reduce(.Or, pos >= max)) return null;
    const cast: vec.x(n, usize) = @intCast(pos);
    var result: usize = 0;
    var multiply: usize = 1;
    inline for (0..n) |index| {
        result += cast[index] * multiply;
        multiply *= size[index];
    }
    return result;
}

pub fn Grid(comptime n: comptime_int, comptime Int: type, comptime Child: type) type {
    return struct {
        items: []Child,
        size: vecXusize,

        const Self = @This();

        const vecXusize = vec.x(n, usize);
        const vecXInt = vec.x(n, Int);

        pub fn init(gpa: std.mem.Allocator, size: vecXusize) !Self {
            const items = try gpa.alloc(Child, size[0] * size[1]);
            errdefer gpa.free(items);
            return .{ .items = items, .size = size };
        }
        pub fn deinit(this: *Self, gpa: std.mem.Allocator) void {
            gpa.free(this.items);
        }
        pub fn get(this: *const Self, pos: vecXInt) Child {
            const idx = this.index(pos) orelse return .empty;
            return this.items[idx];
        }
        pub fn ptr(this: *const Self, pos: vecXInt) ?*Child {
            const idx = this.index(pos) orelse return null;
            return &this.items[idx];
        }
        pub fn set(this: *const Self, pos: vecXInt, value: Child) void {
            const idx = this.index(pos) orelse return;
            this.items[idx] = value;
        }
        fn index(this: *const Self, pos: vecXInt) ?usize {
            return posToIndex(n, Int, this.size, pos);
        }
    };
}

const std = @import("std");
