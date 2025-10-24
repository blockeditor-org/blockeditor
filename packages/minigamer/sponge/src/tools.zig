// usage: ./zig-out/bin/tools imgconv src/assets/font.png font.rgba

const std = @import("std");
const loadimage = @import("loadimage");

pub fn main() !void {
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa_impl.deinit() == .leak) @panic("leak");
    const gpa = gpa_impl.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len < 2) return error.BadCommand;
    if (std.mem.eql(u8, args[1], "imggen")) {
        return imggen(gpa, args[2..]);
    } else if (std.mem.eql(u8, args[1], "makeassets")) {
        return makeassets(gpa, args[2..]);
    } else {
        return error.BadCommand;
    }
}

fn lightness(color_u32: u32) f32 {
    const color_u8: @Vector(4, u8) = @bitCast(color_u32);
    const color_f32_unscaled: @Vector(4, f32) = .{ @floatFromInt(color_u8[0]), @floatFromInt(color_u8[1]), @floatFromInt(color_u8[2]), @floatFromInt(color_u8[3]) };
    const color_f32_scaled = color_f32_unscaled / @as(@Vector(4, f32), @splat(255.0));
    const r, const g, const b, const a = color_f32_scaled;
    const result = r * 0.2126 + g * 0.7152 + b * 0.0722;
    return (result + 1.0) * a;
}

fn formatColor(color_u32: u32, writer: *std.Io.Writer) !void {
    const color_u8: @Vector(4, u8) = @bitCast(color_u32);
    try writer.print("\x1b[48;2;{[r]d};{[g]d};{[b]d}m{[a]X:0>2}\x1b[m", .{ .r = color_u8[0], .g = color_u8[1], .b = color_u8[2], .a = color_u8[3] });
}
pub fn fmtColor(color: u32) std.fmt.Formatter(u32, formatColor) {
    return .{ .data = color };
}

pub fn makeassets(gpa: std.mem.Allocator, args: []const [:0]const u8) !void {
    const progress = std.Progress.start(.{});
    defer progress.end();

    if (args.len < 1) return error.BadArgs;
    const out_zig_file = args[0];
    const argsres = args[1..];
    if (argsres.len % 2 != 0) return error.BadArgs;

    const tmp = std.fs.path.dirname(out_zig_file) orelse return error.ZigFileNotInDir;
    const out_dir = try gpa.dupe(u8, tmp);
    defer gpa.free(out_dir);

    var res_deps = std.array_list.Managed(u8).init(gpa);
    defer res_deps.deinit();

    var res_zig_src = std.array_list.Managed(u8).init(gpa);
    defer res_zig_src.deinit();
    const res_zig_src_writer = res_zig_src.writer();

    var out_dir_ent = try std.fs.cwd().openDir(out_dir, .{});
    defer out_dir_ent.close();

    var i: usize = 0;
    while (i < argsres.len / 2) : (i += 1) {
        const src_path = argsres[i * 2];
        const dest_name = argsres[i * 2 + 1];

        const subnode = progress.start(dest_name, 0);
        defer subnode.end();

        // process file
        const file_cont = try std.fs.cwd().readFileAlloc(gpa, src_path, std.math.maxInt(usize));
        defer gpa.free(file_cont);

        // convert image
        const converted = try loadimage.loadImage(gpa, file_cont);
        defer converted.deinit(gpa);

        // extract palette
        var palette = std.AutoArrayHashMap(u32, void).init(gpa);
        defer palette.deinit();
        for (std.mem.bytesAsSlice(u32, converted.rgba)) |color| {
            // this is assuming color -> vector makes it r, g, b, a. but i'm not sure if that's true. we'll find out.
            try palette.put(color, {});
        }
        if (palette.keys().len > 8) {
            std.log.err("Image `{s}` has more than 8 colors:\n", .{dest_name});
            for (palette.keys(), 0..) |color, color_i| {
                std.log.err("- {}: {f}", .{ color_i, fmtColor(color) });
            }
            return error.TooManyColors; // todo dithering
        }

        // sort palette
        const Ctx = struct {
            const Ctx = @This();
            palette: *@TypeOf(palette),
            pub fn lessThan(ctx: Ctx, a_index: usize, b_index: usize) bool {
                // TODO sort based on eg lightness
                return lightness(ctx.palette.keys()[a_index]) < lightness(ctx.palette.keys()[b_index]);
            }
        };
        palette.sort(Ctx{ .palette = &palette });

        // write output file
        const output_file_name = try std.fmt.allocPrint(gpa, "asset_{d}", .{i});
        defer gpa.free(output_file_name);
        try out_dir_ent.writeFile(.{ .sub_path = output_file_name, .data = converted.rgba });

        // write output zig
        try res_zig_src_writer.print("pub const {f} = struct {{\n", .{std.zig.fmtId(dest_name)});
        try res_zig_src_writer.print("    const u8_slice = @embedFile(\"{f}\");\n", .{std.zig.fmtString(output_file_name)});
        try res_zig_src_writer.print("    const u8_aligned align(@alignOf(u32)) = u8_slice.ptr[0..u8_slice.len].*;\n", .{});
        try res_zig_src_writer.print("    const u32_slice: []const u32 = @as([*]const u32, @ptrCast(&u8_aligned))[0 .. u8_aligned.len / 4];\n", .{});
        try res_zig_src_writer.print("    pub const data = u32_slice;\n", .{});
        try res_zig_src_writer.print("    pub const size = .{{ {d}, {d} }};\n", .{ converted.w, converted.h });
        try res_zig_src_writer.print("    pub const palette: []const u32 = &.{{ ", .{});
        for (palette.keys(), 0..) |color, i_inner| {
            if (i_inner != 0) try res_zig_src_writer.writeAll(", ");
            try res_zig_src_writer.print("0x{X:0>8}", .{color});
        }
        try res_zig_src_writer.print(" }};\n", .{});
        try res_zig_src_writer.print("}};\n", .{});
    }

    // write output .zig
    try std.fs.cwd().writeFile(.{ .sub_path = out_zig_file, .data = res_zig_src.items });
}

pub fn imggen(gpa: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len != 3) return error.BadArgs;
    const width = args[0];
    const height = args[1];
    const label = args[2];

    _ = gpa;
    _ = width;
    _ = height;
    _ = label;
    @panic("TODO");
}
