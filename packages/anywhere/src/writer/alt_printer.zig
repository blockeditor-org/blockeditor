pub fn print(w: *std.Io.Writer, args: anytype) std.Io.Writer.Error!void {
    inline for (args) |arg| {
        try dispatch(w, &arg);
    }
}
inline fn dispatch(w: *std.Io.Writer, ptr_to_arg: anytype) std.Io.Writer.Error!void {
    const T = @typeInfo(@TypeOf(ptr_to_arg)).pointer.child;
    switch (@typeInfo(T)) {
        .pointer => |ptr| switch (ptr.size) {
            .one => try dispatch(w, ptr_to_arg.*),
            .many => @compileError("TODO many-ptr"), // todo need to validate at the top level for the error
            .slice => try dispatchSlice(w, ptr.child, ptr_to_arg.*),
            .c => @compileError("TODO c-ptr"),
        },
        .array => |arr| try dispatchSlice(w, arr.child, ptr_to_arg),
        else => @compileError("TODO type: " ++ @typeName(T)),
    }
}

inline fn dispatchSlice(w: *std.Io.Writer, comptime T: type, slice: []const T) std.Io.Writer.Error!void {
    switch (T) {
        u8 => try printString(w, slice),
        else => @compileError("TODO slice: " ++ @typeName(T)),
    }
}

fn printString(w: *std.Io.Writer, slice: []const u8) std.Io.Writer.Error!void {
    try w.writeAll(slice);
}

const std = @import("std");

test print {
    var w = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer w.deinit();

    try print(&w.writer, .{ "Hello", " ", "World!" });
    try std.testing.expectEqualStrings(
        \\Hello World!
    , w.written());
}
