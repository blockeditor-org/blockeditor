fn anyPrintString(w: *std.Io.Writer, slice: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('\"');
    try std.zig.fmtString(slice).format(w);
    try w.writeByte('\"');
}

const std = @import("std");
