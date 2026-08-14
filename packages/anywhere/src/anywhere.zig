const std = @import("std");
const root = @import("root");

pub const AnywhereCfg = struct {
    tracy: ?type = null,
    zgui: ?type = null,
};
const anywhere_cfg: AnywhereCfg = if (@hasDecl(root, "anywhere_cfg")) root.anywhere_cfg else .{};

const tracy_mod: ?type = anywhere_cfg.tracy;
const zgui_mod: ?type = anywhere_cfg.zgui;

pub const zgui = struct {
    pub inline fn beginWindow(title: [:0]const u8, _: struct {}) bool {
        if (zgui_mod) |z| {
            const res = z.begin(title, .{});
            if (!res) z.end();
            return res;
        }
        return false;
    }
    pub inline fn endWindow() void {
        if (zgui_mod) |z| z.end();
    }

    pub inline fn text(comptime fmt: []const u8, args: anytype) void {
        if (zgui_mod) |z| z.text(fmt, args);
    }
    pub inline fn checkbox(label: [:0]const u8, value: *bool) void {
        if (zgui_mod) |z| _ = z.checkbox(label, .{ .v = value });
    }
    pub inline fn button(label: [:0]const u8, _: struct {}) bool {
        if (zgui_mod) |z| return z.button(label, .{});
        return false;
    }

    /// log a message for the current frame
    pub fn framelog(comptime msg: []const u8, args: anytype) void {
        if (zgui_mod) |z| return z.framelog(msg, args);
    }
};

pub const tracy = struct {
    pub const Ctx = struct {
        value: if (tracy_mod) |t| t.Ctx else void,

        pub inline fn end(self: @This()) void {
            if (tracy_mod) |_| self.value.end();
        }
        pub inline fn addText(self: @This(), text: []const u8) void {
            if (tracy_mod) |_| self.value.addText(text);
        }
        pub inline fn setName(self: @This(), name: []const u8) void {
            if (tracy_mod) |_| self.value.setName(name);
        }
        pub inline fn setColor(self: @This(), color: u32) void {
            if (tracy_mod) |_| self.value.setColor(color);
        }
        pub inline fn setValue(self: @This(), value: u64) void {
            if (tracy_mod) |_| self.value.setValue(value);
        }
    };

    pub inline fn trace(comptime src: std.builtin.SourceLocation) Ctx {
        if (tracy_mod) |t| return .{ .value = t.trace(src) };
        return .{ .value = {} };
    }
    pub inline fn traceNamed(comptime src: std.builtin.SourceLocation, comptime name: [:0]const u8) Ctx {
        if (tracy_mod) |t| return .{ .value = t.traceNamed(src, name) };
        return .{ .value = {} };
    }
    pub inline fn tracyAllocator(allocator: std.mem.Allocator) TracyAllocator(null) {
        if (tracy_mod) |t| return .{ .value = t.tracyAllocator(allocator) };
        return .{ .value = allocator };
    }

    pub fn TracyAllocator(comptime name: ?[:0]const u8) type {
        return struct {
            value: if (tracy_mod) |t| t.TracyAllocator(name) else std.mem.Allocator,

            pub inline fn init(parent_allocator: std.mem.Allocator) @This() {
                if (tracy_mod) |_| return .{ .value = .init(parent_allocator) };
                return .{ .value = parent_allocator };
            }
            pub inline fn allocator(self: *@This()) std.mem.Allocator {
                if (tracy_mod) |_| return self.value.allocator();
                return self.value;
            }
        };
    }

    pub inline fn message(comptime msg: [:0]const u8) void {
        if (tracy_mod) |t| t.message(msg);
    }
    pub inline fn messageColor(comptime msg: [:0]const u8, color: u32) void {
        if (tracy_mod) |t| t.messageColor(msg, color);
    }
    pub inline fn messageCopy(msg: []const u8) void {
        if (tracy_mod) |t| t.messageCopy(msg);
    }
    pub inline fn messageColorCopy(msg: []const u8, color: u32) void {
        if (tracy_mod) |t| t.messageColorCopy(msg, color);
    }
    pub inline fn frameMark() void {
        if (tracy_mod) |t| t.frameMark();
    }
    pub inline fn frameMarkNamed(comptime name: [:0]const u8) void {
        if (tracy_mod) |t| t.frameMarkNamed(name);
    }
    pub inline fn namedFrame(comptime name: [:0]const u8) Frame(name) {
        if (tracy_mod) |t| return .{ .value = t.namedFrame(name) };
        return .{ .value = {} };
    }
    pub inline fn emitFrameImage(image: *const anyopaque, w: u16, h: u16, offset: u8, flip: c_int) void {
        if (tracy_mod) |t| t.emitFrameImage(image, w, h, offset, flip);
    }

    pub fn Frame(comptime name: [:0]const u8) type {
        return struct {
            value: if (tracy_mod) |t| t.Frame(name) else void,
            pub inline fn end(self: @This()) void {
                if (tracy_mod) |_| self.value.end(name);
            }
        };
    }
};

pub const util = @import("util.zig");
