pub const default_image = @embedFile("font.rgba"); // 97x161, 255 = white / 0 = black
pub const draw_lists = @import("render_list.zig");
pub const Texpack = @import("Texpack.zig");
pub const font_experiment = @import("font_experiment.zig");
pub const EditorView = @import("EditorView.zig");
pub const beui_experiment = @import("beui_experiment.zig");

const Beui = @This();

frame: FrameEv = .{},
persistent: PersistentEv = .{},

pub fn newFrame(self: *Beui, cfg: FrameCfg) void {
    self.frame = .{ .frame_cfg = cfg };
}
pub fn endFrame(self: *Beui) void {
    self.frame.frame_cfg = null;
}

pub fn textInput(self: *Beui) ?[]const u8 {
    const res = self.frame.text_input;
    if (res.len == 0) return null;
    self.frame.text_input = "";
    return res;
}
pub fn hotkey(self: *Beui, comptime mods: HotkeyMods, comptime key_opts: []const Key) ?HotkeyResult(mods, key_opts) {
    const ctrl_down = self.persistent.held_keys.get(.left_control) or self.persistent.held_keys.get(.right_control);
    const cmd_down = self.persistent.held_keys.get(.left_super) or self.persistent.held_keys.get(.right_super);
    const shift_down = self.persistent.held_keys.get(.left_shift) or self.persistent.held_keys.get(.right_shift);
    const alt_down = self.persistent.held_keys.get(.left_alt) or self.persistent.held_keys.get(.right_alt);
    const mods_eql = mods.shift.eql(shift_down) and mods.ctrl_or_cmd.eql(ctrl_down != cmd_down) and mods.alt.eql(alt_down);

    if (!mods_eql) return null;
    const key = for (key_opts) |key| {
        if (self.isKeyPressed(key)) break key;
    } else return null;

    return .{
        .ctrl_or_cmd = if (mods.ctrl_or_cmd == .maybe) ctrl_down or cmd_down else {},
        .alt = if (mods.alt == .maybe) alt_down else {},
        .shift = if (mods.shift == .maybe) shift_down else {},
        .key = @enumFromInt(@intFromEnum(key)),
    };
}

pub fn isKeyPressed(self: *Beui, key: Key) bool {
    return self.frame.pressed_keys.get(key) or self.frame.repeated_keys.get(key);
}
pub fn isKeyHeld(self: *Beui, key: Key) bool {
    return self.persistent.held_keys.get(key);
}
pub fn leftMouseClickedCount(self: *Beui) usize {
    self._maybeResetLeftClick(self.frame.frame_cfg.?.now_ms);
    return self.persistent.left_mouse_dblclick_info.count;
}

pub fn arena(self: *Beui) std.mem.Allocator {
    return self.frame.frame_cfg.?.arena;
}

pub fn setClipboard(self: *Beui, text_utf8: [:0]const u8) void {
    const cfg = &self.frame.frame_cfg.?;
    if (cfg.vtable.set_clipboard == null) {
        std.log.warn("Could not copy to clipboard; no clipboard defined", .{});
        return;
    }
    std.debug.assert(std.unicode.utf8ValidateSlice(text_utf8));
    std.debug.assert(std.mem.indexOfScalar(u8, text_utf8, '\x00') == null);
    cfg.vtable.set_clipboard.?(cfg, text_utf8);
}
pub fn getClipboard(self: *Beui, value: *std.array_list.Managed(u8)) void {
    const cfg = &self.frame.frame_cfg.?;
    if (cfg.vtable.get_clipboard == null) {
        std.log.warn("Could not read from clipboard; no clipboard defined", .{});
        return;
    }
    cfg.vtable.get_clipboard.?(cfg, value);
}

fn _maybeResetLeftClick(self: *Beui, now: i64) void {
    const dist_vec = self.persistent.mouse_pos - self.persistent.left_mouse_dblclick_info.last_click_pos;
    const dist_sca = std.math.hypot(dist_vec[0], dist_vec[1]);
    if ((self.persistent.left_mouse_dblclick_info.last_click_time <= now - self.persistent.config.dbl_click_time) //
    or dist_sca > self.persistent.config.dbl_click_dist) {
        self.persistent.left_mouse_dblclick_info = .{};
    }
}
pub fn _leftClickNow(self: *Beui) void {
    const now = std.time.milliTimestamp();
    self._maybeResetLeftClick(now);
    self.persistent.left_mouse_dblclick_info.count += 1;
    self.persistent.left_mouse_dblclick_info.last_click_time = now;
    self.persistent.left_mouse_dblclick_info.last_click_pos = self.persistent.mouse_pos;
}

const std = @import("std");
const math = std.math;

pub const HotkeyModOption = enum {
    no,
    maybe,
    yes,

    pub fn eql(self: HotkeyModOption, v: bool) bool {
        return switch (self) {
            .no => v == false,
            .maybe => true,
            .yes => v == true,
        };
    }
};
pub const HotkeyMods = struct {
    ctrl_or_cmd: HotkeyModOption = .no,
    alt: HotkeyModOption = .no,
    shift: HotkeyModOption = .no,
};

fn HotkeyResult(mods: HotkeyMods, key_opts: []const Key) type {
    var fields: []const std.builtin.Type.EnumField = &.{};
    for (key_opts) |ko| {
        fields = fields ++ &[_]std.builtin.Type.EnumField{.{
            .name = @tagName(ko),
            .value = @intFromEnum(ko),
        }};
    }
    const ti: std.builtin.Type = .{ .@"enum" = .{
        .tag_type = @typeInfo(Key).@"enum".tag_type,
        .fields = fields,
        .decls = &.{},
        .is_exhaustive = true,
    } };
    return struct {
        const FilteredKey = @Type(ti);
        ctrl_or_cmd: if (mods.ctrl_or_cmd == .maybe) bool else void,
        alt: if (mods.alt == .maybe) bool else void,
        shift: if (mods.shift == .maybe) bool else void,
        key: FilteredKey,
    };
}

pub fn EnumArray(comptime Enum: type, comptime Value: type) type {
    const count = blk: {
        const enum_ti = @typeInfo(Enum);
        if (!enum_ti.@"enum".is_exhaustive) {
            break :blk Enum.count;
        }
        var count_v: usize = 0;
        for (enum_ti.@"enum".fields) |field| {
            const field_v: std.builtin.Type.EnumField = field;
            count_v = @max(count_v, field_v.value + 1);
        }
        break :blk count_v;
    };
    if (count > 1000) @compileError("count large");
    return struct {
        const Self = @This();
        values: [count]Value, // for ints we can use PackedIntArray
        pub fn init(default_value: Value) Self {
            return .{ .values = [_]Value{default_value} ** count };
        }
        fn toIdx(key: Enum) usize {
            const res = @intFromEnum(key);
            if (res >= count) @panic("enum too big");
            return res;
        }
        pub fn get(self: *const Self, key: Enum) Value {
            return self.values[toIdx(key)];
        }
        pub fn set(self: *Self, key: Enum, value: Value) void {
            self.values[toIdx(key)] = value;
        }
    };
}
pub const FrameCfg = struct {
    can_capture_keyboard: bool = true,
    can_capture_mouse: bool = true,
    arena: std.mem.Allocator,
    now_ms: i64,

    user_data: ?*const anyopaque,
    vtable: *const FrameCfgVtable,

    pub fn castUserData(self: *const FrameCfg, comptime T: type) *T {
        std.debug.assert(@typeName(T) == self.vtable.type_id);
        return @ptrCast(@alignCast(@constCast(self.user_data.?)));
    }
};
pub const FrameCfgVtable = struct {
    type_id: [*:0]const u8,
    set_clipboard: ?*const fn (frame_cfg: *const FrameCfg, text_utf8: [:0]const u8) void = null,
    get_clipboard: ?*const fn (frame_cfg: *const FrameCfg, clipboard_contents: *std.array_list.Managed(u8)) void = null,
};
const PersistentEv = struct {
    config: struct {
        dbl_click_time: i64 = 500,
        dbl_click_dist: f32 = 10.0,
    } = .{},
    held_keys: EnumArray(Key, bool) = .init(false),
    mouse_pos: @Vector(2, f32) = .{ 0, 0 },
    left_mouse_dblclick_info: struct {
        count: usize = 0,
        last_click_time: i64 = 0,
        last_click_pos: @Vector(2, f32) = .{ 0.0, 0.0 },
    } = .{},
};
const FrameEv = struct {
    pressed_keys: EnumArray(Key, bool) = .init(false),
    repeated_keys: EnumArray(Key, bool) = .init(false),
    released_keys: EnumArray(Key, bool) = .init(false),
    text_input: []const u8 = "",
    frame_cfg: ?FrameCfg = null,
    scroll_px: @Vector(2, f32) = .{ 0, 0 },
    mouse_offset: @Vector(2, f32) = .{ 0, 0 },
    cursor: Cursor = .arrow,
    has_events: bool = false,
};
pub const Cursor = enum {
    arrow,
    pointer,
    text_input,
    resize_nw_se,
    resize_ns,
    resize_ne_sw,
    resize_ew,
};
pub const Key = enum(u32) {
    mouse_left = 1,
    mouse_right = 2,
    mouse_middle = 3,
    mouse_four = 4,
    mouse_five = 5,
    mouse_six = 6,
    mouse_seven = 7,
    mouse_eight = 8,

    space = 32,
    apostrophe = 39,
    comma = 44,
    minus = 45,
    period = 46,
    slash = 47,
    zero = 48,
    one = 49,
    two = 50,
    three = 51,
    four = 52,
    five = 53,
    six = 54,
    seven = 55,
    eight = 56,
    nine = 57,
    semicolon = 59,
    equal = 61,
    a = 65,
    b = 66,
    c = 67,
    d = 68,
    e = 69,
    f = 70,
    g = 71,
    h = 72,
    i = 73,
    j = 74,
    k = 75,
    l = 76,
    m = 77,
    n = 78,
    o = 79,
    p = 80,
    q = 81,
    r = 82,
    s = 83,
    t = 84,
    u = 85,
    v = 86,
    w = 87,
    x = 88,
    y = 89,
    z = 90,
    left_bracket = 91,
    backslash = 92,
    right_bracket = 93,
    grave_accent = 96,
    world_1 = 161,
    world_2 = 162,

    escape = 256,
    enter = 257,
    tab = 258,
    backspace = 259,
    insert = 260,
    delete = 261,
    right = 262,
    left = 263,
    down = 264,
    up = 265,
    page_up = 266,
    page_down = 267,
    home = 268,
    end = 269,
    caps_lock = 280,
    scroll_lock = 281,
    num_lock = 282,
    print_screen = 283,
    pause = 284,
    F1 = 290,
    F2 = 291,
    F3 = 292,
    F4 = 293,
    F5 = 294,
    F6 = 295,
    F7 = 296,
    F8 = 297,
    F9 = 298,
    F10 = 299,
    F11 = 300,
    F12 = 301,
    F13 = 302,
    F14 = 303,
    F15 = 304,
    F16 = 305,
    F17 = 306,
    F18 = 307,
    F19 = 308,
    F20 = 309,
    F21 = 310,
    F22 = 311,
    F23 = 312,
    F24 = 313,
    F25 = 314,
    kp_0 = 320,
    kp_1 = 321,
    kp_2 = 322,
    kp_3 = 323,
    kp_4 = 324,
    kp_5 = 325,
    kp_6 = 326,
    kp_7 = 327,
    kp_8 = 328,
    kp_9 = 329,
    kp_decimal = 330,
    kp_divide = 331,
    kp_multiply = 332,
    kp_subtract = 333,
    kp_add = 334,
    kp_enter = 335,
    kp_equal = 336,
    left_shift = 340,
    left_control = 341,
    left_alt = 342,
    left_super = 343,
    right_shift = 344,
    right_control = 345,
    right_alt = 346,
    right_super = 347,
    menu = 348,
    _,
    pub const count = 400;
};
pub const Color = struct {
    value: @Vector(4, u8),

    pub fn fromHexRgb(hex: u24) Color {
        return .{ .value = .{
            @truncate(hex >> 16),
            @truncate(hex >> 8),
            @truncate(hex >> 0),
            0xFF,
        } };
    }
    pub fn fromHexArgb(hex: u32) Color {
        return .{ .value = .{
            @truncate(hex >> 16),
            @truncate(hex >> 8),
            @truncate(hex >> 0),
            @truncate(hex >> 24),
        } };
    }

    pub fn toVec4f(self: Color) @Vector(4, f32) {
        var res: @Vector(4, f32) = @floatFromInt(self.value);
        res /= @splat(255.0);
        return res;
    }
};

test {
    _ = font_experiment;
    _ = draw_lists;
    _ = Texpack;
    _ = EditorView;
    _ = beui_experiment;
}
