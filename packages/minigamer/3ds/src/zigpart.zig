const std = @import("std");
const emu = @import("minigamer_emulator");
const constants = emu.constants;

// TODO: use generalpurposeallocator with backing_allocator = c_allocator

const c = @cImport({
    @cInclude("3ds.h");
    @cInclude("time.h");
});

const zigpart_Instance = struct {
    gpa: std.mem.Allocator,
    emu: emu.Emu,

    frame_out: *FrameOut,
    offsets_out: *OffsetsOut,
    bg_color_out: u32,
};
const FrameOut = [constants.EMU_SCREEN_DATA_SIZE_U32 * constants.EMU_SCREEN_NLAYERS]u32;
const OffsetsOut = [constants.EMU_SCREEN_NLAYERS]@Vector(2, i8);

const NullErrorSet = error{};
pub const PrintfWriter = std.Io.GenericWriter(void, NullErrorSet, writeFn);
fn writeFn(_: void, bytes: []const u8) NullErrorSet!usize {
    _ = std.c.printf("%.*s", @as(c_int, @intCast(bytes.len)), bytes.ptr);
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
    const writer = PrintfWriter{ .context = {} };
    writer.print(level_txt ++ prefix2 ++ format ++ "\n", args) catch return;
}
pub const std_options = std.Options{
    .logFn = logFn,
    .log_level = .info,
};

export fn zigpart_create() *zigpart_Instance {
    // TODO: load program from network for faster iteration
    // - https://github.com/devkitPro/3ds-examples/blob/master/network/http/source/main.c
    std.log.info("initializing...", .{});

    const result: *zigpart_Instance = std.heap.c_allocator.create(zigpart_Instance) catch @panic("oom");
    std.log.info("malloc()", .{});
    result.* = .{
        .gpa = std.heap.c_allocator,
        .emu = emu.Emu.init(),
        .frame_out = std.heap.c_allocator.create(FrameOut) catch @panic("oom"),
        .offsets_out = std.heap.c_allocator.create(OffsetsOut) catch @panic("oom"),
        .bg_color_out = 0,
    };
    std.log.info("emu init()", .{});

    result.emu.loadProgram(result.gpa, @embedFile("sponge.cart")) catch @panic("load program fail");
    std.log.info("emu load program()", .{});

    return result;
}
export fn zigpart_destroy(instance: *zigpart_Instance) void {
    instance.emu.unloadProgram(std.heap.c_allocator);
    instance.emu.deinit();
    std.heap.c_allocator.destroy(instance.frame_out);
    std.heap.c_allocator.destroy(instance.offsets_out);
    std.heap.c_allocator.destroy(instance);
}

extern const swizzle_data_u16: [65536]u16;
export fn zigpart_tick(instance: *zigpart_Instance, keys_h: c_uint, tex_buf: [*]u32) void {
    var touch: c.touchPosition = .{};
    c.hidTouchRead(&touch);

    var mouse: ?@Vector(2, i16) = null;
    if (touch.px != 0 and touch.py != 0) {
        mouse = .{ @intCast(@divFloor(@as(i32, touch.px) - 40, 2)), @intCast(@divFloor(@as(i32, touch.py), 2)) };
    }

    instance.emu.simulate(.{
        // .time = @intCast(c.time(null)), // TODO ms
        .time_ms = c.osGetTime(),
        .buttons = .{
            .up = keys_h & c.KEY_UP != 0,
            .left = keys_h & c.KEY_LEFT != 0,
            .down = keys_h & c.KEY_DOWN != 0,
            .right = keys_h & c.KEY_RIGHT != 0,
            .interact = keys_h & (c.KEY_A | c.KEY_R) != 0,
            .jump = keys_h & (c.KEY_B | c.KEY_L) != 0,
            .menu = keys_h & c.KEY_SELECT != 0,
        },
        .mouse = mouse,
    }, .{
        .frame = instance.frame_out,
        .layer_offsets = instance.offsets_out,
        .background_color = &instance.bg_color_out,
    });

    // TODO: consider computing at runtime rather than using a precomputed buffer
    // https://github.com/devkitPro/tex3ds/blob/master/source/swizzle.cpp
    // the trouble is I have no clue how that ^ works at all. It makes no sense. Buffers
    // are swizzled over the whole image, not just little 8x8 regions.
    const w = 256;
    const render_result = instance.frame_out;
    for (0..4) |n| {
        const nx = n % 2;
        const ny = n / 2;
        for (0..120) |y| {
            for (0..120) |x| {
                const indexv: usize = ((y + ny * 128) * w + (x + nx * 128));
                const index: usize = swizzle_data_u16[indexv]; // TODO use .bin file rather than the c file
                const src_index: usize = (y * 120 + x) + (120 * 120) * n;
                tex_buf[index] = @byteSwap(render_result[src_index]);
            }
        }
    }
}
export fn zigpart_getRenderOffsets(instance: *zigpart_Instance) *OffsetsOut {
    return instance.offsets_out;
}
export fn zigpart_getBgColor(instance: *zigpart_Instance) u32 {
    return instance.bg_color_out;
}
