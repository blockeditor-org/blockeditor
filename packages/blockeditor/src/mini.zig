const std = @import("std");
const Beui = @import("beui").Beui;
const B2 = Beui.beui_experiment;

const emu = @import("minigamer");
const util = @import("anywhere").util;
const blocks_mod = @import("blocks");
const db_mod = blocks_mod.blockdb;
const bi = blocks_mod.blockinterface2;

const OffsetsOut = [emu.constants.EMU_SCREEN_NLAYERS]@Vector(2, i8);
const State = struct {
    gpa: std.mem.Allocator,
    val: emu.Emu,
    frame_out: *B2.ImageCache.Image,
    offsets_out: *OffsetsOut,
    bg_color_out: u32,
    mouse: ?@Vector(2, i16) = null,
    err: bool = false,

    pub fn init(self: *State, gpa: std.mem.Allocator) void {
        self.* = .{
            .gpa = gpa,
            .val = .init(),
            .frame_out = B2.ImageCache.Image.create(gpa, .{ emu.constants.EMU_SCREEN_W, emu.constants.EMU_SCREEN_H * emu.constants.EMU_SCREEN_NLAYERS }, .rgba),
            .offsets_out = gpa.create(OffsetsOut) catch @panic("oom"),
            .bg_color_out = 0,
        };
    }
    pub fn deinit(self: *State) void {
        self.gpa.destroy(self.offsets_out);
        self.frame_out.destroy(self.gpa);
        if (self.val.program != null) self.val.unloadProgram(self.gpa);
        self.val.deinit(); // this doesn't even do anything?
    }
};

const Data = struct {
    state: *State,
    center: @Vector(2, f32),
    max_scale: f32,
};
pub fn render__onMouseEvent(data: *Data, b2: *B2.Beui2, mev: B2.MouseEvent) ?Beui.Cursor {
    _ = b2;
    if (mev.action == .down or mev.action == .move_while_down) {
        const converted = (mev.pos.? - mev.capture_pos - data.center) / @as(@Vector(2, f32), @splat(data.max_scale));
        data.state.mouse = .{
            std.math.lossyCast(i16, converted[0]),
            std.math.lossyCast(i16, converted[1]),
        };
    }
    if (mev.action == .up) {
        data.state.mouse = null;
    }
    return .arrow;
}

pub fn render(viewer: db_mod.TypedComponentRef(bi.ReplaceTextComponent), call_info: B2.StandardCallInfo, _: void) *B2.RepositionableDrawList {
    const ui = call_info.ui(@src());
    const rdl = ui.id.b2.draw();
    const size: @Vector(2, f32) = .{ ui.constraints.available_size.w.?, ui.constraints.available_size.h.? };

    const state = ui.id.b2.state2(ui.id.sub(@src()), ui.id.b2.persistent.gpa, State);

    if (state.val.program == null) {
        state.val.loadProgram(state.gpa, viewer.value.value) catch |e| {
            std.log.err("progarm failed to load: {s}", .{@errorName(e)});
            state.err = true;
            return rdl;
        };
    }
    if (state.val.program == null or state.err) return rdl;

    state.val.simulate(.{
        .time_ms = @bitCast(ui.id.b2.persistent.beui1.frame.frame_cfg.?.now_ms),
        .buttons = .{
            .up = ui.id.b2.persistent.beui1.isKeyHeld(.up) or ui.id.b2.persistent.beui1.isKeyHeld(.w),
            .left = ui.id.b2.persistent.beui1.isKeyHeld(.left) or ui.id.b2.persistent.beui1.isKeyHeld(.a),
            .down = ui.id.b2.persistent.beui1.isKeyHeld(.down) or ui.id.b2.persistent.beui1.isKeyHeld(.s),
            .right = ui.id.b2.persistent.beui1.isKeyHeld(.right) or ui.id.b2.persistent.beui1.isKeyHeld(.d),
            .interact = ui.id.b2.persistent.beui1.isKeyHeld(.z) or ui.id.b2.persistent.beui1.isKeyHeld(.enter),
            .jump = ui.id.b2.persistent.beui1.isKeyHeld(.x) or ui.id.b2.persistent.beui1.isKeyHeld(.space),
            .menu = ui.id.b2.persistent.beui1.isKeyHeld(.c) or ui.id.b2.persistent.beui1.isKeyHeld(.escape),
        },
        .mouse = state.mouse, // TODO
    }, .{
        .frame = std.mem.bytesAsSlice(u32, state.frame_out.mutate())[0 .. emu.constants.EMU_SCREEN_DATA_SIZE_U32 * emu.constants.EMU_SCREEN_NLAYERS],
        .layer_offsets = state.offsets_out,
        .background_color = &state.bg_color_out,
    });

    const allow_non_integer = false; // if we want this we need to use pixel art scaling in the shader (only interpolates at the edges between pixels)
    const min_axis = @min(size[0], size[1]);
    var max_scale: f32 = min_axis / @as(f32, emu.constants.EMU_SCREEN_W);
    if (!allow_non_integer and max_scale >= 1.0) max_scale = @floor(max_scale);
    const scale: @Vector(2, f32) = @splat(max_scale * emu.constants.EMU_SCREEN_W);
    const center = (size - scale) / @as(@Vector(2, f32), @splat(2));

    // TODO clip a full pixel in from every edge

    const clipped = ui.id.b2.draw();

    const uv = ui.id.b2.persistent.image_cache.getImageUVOnRenderFromRdl(state.frame_out);
    for (&[_]f32{ 3.0, 2.0, 1.0, 0.0 }, &[_]usize{ 3, 2, 1, 0 }) |offset, i| {
        // offset is i8 from -128 to 127. convert to [-0.5, 0.5)
        var offset_vec: @Vector(2, f32) = @floatFromInt(state.offsets_out[i]);
        offset_vec /= @splat(256);

        clipped.addRect(.{
            .pos = center + offset_vec * @as(@Vector(2, f32), @splat(max_scale)),
            .size = scale,
            .uv_pos = uv.pos + uv.size * @Vector(2, f32){ 0.0, offset / 4.0 },
            .uv_size = uv.size * @Vector(2, f32){ 1.0, 1.0 / 4.0 },
            .image = .rgba,
        });
    }
    const V2 = @Vector(2, f32);
    rdl.addClip(clipped, .{
        .pos = center + @as(V2, @splat(1)) * @as(V2, @splat(max_scale)),
        .size = scale - @as(V2, @splat(2)) * @as(V2, @splat(max_scale)),
    });

    rdl.addRect(.{
        .pos = .{ 0, 0 },
        .size = size,
        .tint = .fromHexArgb(state.bg_color_out),
        .rounding = .{ .corners = .all, .radius = 6.0 },
    });

    const data = ui.id.b2.frame.arena.create(Data) catch @panic("oom");
    data.* = .{
        .state = state,
        .center = center,
        .max_scale = max_scale,
    };

    rdl.addMouseEventCapture2(ui.id.sub(@src()), .{ 0, 0 }, size, .{
        .buttons = .left,
        .onMouseEvent = .from(data, render__onMouseEvent),
    });

    return rdl;
}
