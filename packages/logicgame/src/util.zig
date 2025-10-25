const std = @import("std");
const snapshot_zig = @import("snapshot.zig");
pub const snapshot = snapshot_zig.snapshot;
pub const formattedSnapshot = snapshot_zig.formattedSnapshot;

const Cyclic = std.AutoArrayHashMap(*const anyopaque, usize);
const PrintCtx = struct {
    cyclic: *Cyclic,
    w: *std.Io.Writer,
};

inline fn prettyPrintAnytype(obj: anytype, ctx: *const PrintCtx) error{WriteFailed}!void {
    // so the goal here is to convert the typeInfo to a runtime typeInfo description and then do the printing
    // at runtime based on the runtime description. that's doable but all code will be compiled even if you don't
    // need eg float printing
    // it's probably fine to do it comptime as long as struct printing isn't 'inline' so it can memoize
    switch (@typeInfo(@TypeOf(obj))) {
        .comptime_int, .int, .float => {
            try ctx.w.print("{d}", .{obj});
        },
        else => {
            try ctx.w.print("[todo {s}]", .{@tagName(@typeInfo(@TypeOf(obj)))});
        },
    }
}
fn FmtAny(comptime V: type) type {
    return struct {
        gpa: std.mem.Allocator,
        v: V,
        pub inline fn format(obj: @This(), w: *std.Io.Writer) error{WriteFailed}!void {
            var cyclic = Cyclic.init(obj.gpa);
            defer cyclic.deinit();
            try prettyPrintAnytype(obj.v, &.{ .cyclic = &cyclic, .w = w });
        }
    };
}
fn fmtAny(gpa: std.mem.Allocator, v: anytype) FmtAny(@TypeOf(v)) {
    return .{ .v = v, .gpa = gpa };
}

test "fmtAny" {
    const gpa = std.testing.allocator;
    try formattedSnapshot(gpa, "{f}", .{fmtAny(gpa, .{ .x = 25 })}, @src(),
        \\[todo struct]
    );
}
