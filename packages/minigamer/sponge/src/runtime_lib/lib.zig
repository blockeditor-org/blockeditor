const std = @import("std");
pub const constants = @import("constants");
pub const syscalls = @import("syscalls.zig");
pub const text = @import("text.zig");

pub const ImageSub = struct {
    // TODO: ImageSub should support creating subrectangles out of range of the image
    data: [*]u32,
    stride: usize,
    size: @Vector(2, i32),
    pub fn fromAsset(comptime Asset: type) ImageSub {
        return .{
            .data = @constCast(Asset.data.ptr),
            .stride = Asset.size[0],
            .size = .{ Asset.size[0], Asset.size[1] },
        };
    }
    pub inline fn getIdx(img: ImageSub, pos: @Vector(2, i32)) ?usize {
        @setRuntimeSafety(false);
        if (pos[0] < 0 or pos[1] < 0 or pos[0] >= img.size[0] or pos[1] >= img.size[1]) return null;
        const xu: usize = @intCast(pos[0]);
        const yu: usize = @intCast(pos[1]);
        return yu * img.stride + xu;
    }
    pub inline fn getPx(img: ImageSub, pos: @Vector(2, i32)) ?*u32 {
        @setRuntimeSafety(false);
        const idx = img.getIdx(pos) orelse return null;
        return &img.data[idx];
    }
    pub fn blit(dest: ImageSub, src: ImageSub) void {
        @setRuntimeSafety(false);
        var index_dest: usize = 0;
        var index_src: usize = 0;
        for (0..@intCast(@min(dest.size[1], src.size[1]))) |_| {
            const dstart = index_dest;
            const sstart = index_src;
            for (0..@intCast(@min(dest.size[0], src.size[0]))) |_| {
                dest.data[index_dest] = src.data[index_src];
                index_dest += 1;
                index_src += 1;
            }
            index_dest = dstart + dest.stride;
            index_src = sstart + src.stride;
        }
    }
    pub fn fill(dest: ImageSub, color: u32) void {
        @setRuntimeSafety(false);
        var index_dest: usize = 0;
        for (0..@intCast(dest.size[1])) |_| {
            const dstart = index_dest;
            for (0..@intCast(dest.size[0])) |_| {
                dest.data[index_dest] = color;
                index_dest += 1;
            }
            index_dest = dstart + dest.stride;
        }
    }
    pub fn subrect(img: ImageSub, pos: @Vector(2, i32), size: @Vector(2, i32)) ?ImageSub {
        const start_idx = img.getIdx(pos) orelse return null;
        if (@reduce(.Or, pos + size > img.size)) return null;
        return .{
            .data = img.data[start_idx..],
            .size = size,
            .stride = img.stride,
        };
    }
};

const NullErrorSet = error{};
pub const StderrWriter = std.Io.Writer(void, NullErrorSet, writeFn);
fn writeFn(_: void, bytes: []const u8) NullErrorSet!usize {
    printAppend(bytes);
    return bytes.len;
}
pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_txt = comptime message_level.asText();
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

    // there's basically no cost to syscalls so there's no need for a buffered writer
    const writer = StderrWriter{ .context = {} };
    writer.print(level_txt ++ prefix2 ++ format ++ "\n", args) catch return;
    printFlush();
}

var panic_stage: usize = 0;
pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    panic_stage += 1;
    switch (panic_stage) {
        1 => {}, // regular
        2 => {
            printAppend("Panicked during a panic\n");
            printFlush();
            exit(1);
        },
        else => {
            @trap();
        },
    }
    printAppend("[PANIC]: ");
    printAppend(msg);
    printAppend("\n");
    printFlush();

    exit(1);
}

pub fn printAppend(text_print: []const u8) void {
    _ = syscalls.syscall2(.print_append, @intFromPtr(text_print.ptr), text_print.len);
}
pub fn printFlush() void {
    _ = syscalls.syscall0(.print_flush);
}
pub fn exit(code: u8) noreturn {
    _ = syscalls.syscall1(.exit, code);
    @trap();
}
pub fn getButtons() u32 {
    return syscalls.syscall0(.get_buttons);
}
pub fn getMouse() ?@Vector(2, i16) {
    const res: @Vector(2, i16) = @bitCast(syscalls.syscall0(.get_mouse));
    if (res[0] == std.math.minInt(i16)) return null;
    return res;
}

pub const gpu = struct {
    pub fn setBackgroundColor(color: u32) void {
        _ = syscalls.syscall1(.gpu_set_background_color, color);
    }
    pub fn draw(layer: u2, sub: ImageSub, pos: @Vector(2, i32), alpha: constants.DrawImageCmdAlphaMode) void {
        gpu.drawImage(&.{
            .dest = .{
                .layer = layer,
                .pos = pos,
            },
            .src = .{
                .stride = sub.stride,
                .size = .{ sub.size[0], sub.size[1] },
            },
            .flags = .{ .alpha_mode = alpha },
        }, sub.data);
    }
    pub fn setLayerOffset(layer: u2, offset_x: i8, offset_y: i8) void {
        _ = syscalls.syscall3(.gpu_set_layer_offset, layer, @bitCast(@as(isize, offset_x)), @bitCast(@as(isize, offset_y)));
    }
    pub fn drawImage(cmd: *const constants.DrawImageCmd, image: [*]u32) void {
        _ = syscalls.syscall2(.gpu_draw_image, @intFromPtr(cmd), @intFromPtr(image));
    }
};

// copied from zig riscv linux syscall impl
