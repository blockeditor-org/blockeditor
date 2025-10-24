const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var output = std.fs.File.stdout();

    for (args[1..]) |arg| {
        try output.writeAll(arg);
        try output.writeAll("\n");
    }
}
