const std = @import("std");

var result_data = std.mem.zeroes([256 * 256]u16);
var seen_values = std.mem.zeroes([256 * 256]bool);
pub fn main() !void {
    var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa_alloc.deinit() == .ok);
    const gpa = gpa_alloc.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len != 3) return error.BadArgs;
    const swizzle = try std.fs.cwd().readFileAlloc(gpa, args[1], std.math.maxInt(usize));
    defer gpa.free(swizzle);

    const result = &result_data;
    for (0..256) |y| {
        for (0..256) |x| {
            const src_idx = (y * 256 + x);
            const src_idx_four = src_idx * 4;
            const x_index: u32 = swizzle[src_idx_four + 0];
            const y_index: u32 = swizzle[src_idx_four + 2];
            if (x_index == 0 and y_index == 0) std.log.info("0 at: {d}.", .{src_idx});
            // result[y_index * 256 + x_index] = @intCast(src_idx);
            result[src_idx] = @intCast(y_index * 256 + x_index);
        }
    }
    std.log.info("done.", .{});
    for (result) |itm| {
        std.debug.assert(!seen_values[itm]);
        seen_values[itm] = true;
    }
    for (seen_values) |itm| {
        std.debug.assert(itm);
    }
    std.log.info("validated.", .{});

    var carr = std.array_list.Managed(u8).init(gpa);
    defer carr.deinit();

    try carr.appendSlice("#include <3ds.h>\n");
    try carr.appendSlice("u16 swizzle_data_u16[65536] = {\n");
    for (result, 0..) |itm, i| {
        try carr.writer().print("{d},", .{itm});
        if (i % 16 == 15) {
            try carr.appendSlice("\n");
        } else {
            try carr.appendSlice(" ");
        }
    }
    try carr.appendSlice("};");

    // try std.fs.cwd().writeFile(.{.sub_path = "swizzle256.bin", .data = std.mem.sliceAsBytes(result)});
    try std.fs.cwd().writeFile(.{ .sub_path = args[2], .data = carr.items });
    std.log.info("saved.", .{});
}
