const zglfw = @import("zglfw");
const std = @import("std");

const Event = union(enum) {
    key: struct {
        window: *zglfw.Window,
        key: zglfw.Key,
        scancode: i32,
        action: zglfw.Action,
        mods: zglfw.Mods,
    },
    char: struct {
        window: *zglfw.Window,
        codepoint: u32,
    },
    scroll: struct {
        window: *zglfw.Window,
        xoffset: f64,
        yoffset: f64,
    },
    cursorPos: struct {
        window: *zglfw.Window,
        xpos: f64,
        ypos: f64,
    },
    cursorEnter: struct {
        window: *zglfw.Window,
        entered: i32,
    },
    mouseButton: struct {
        window: *zglfw.Window,
        button: zglfw.MouseButton,
        action: zglfw.Action,
        mods: zglfw.Mods,
    },
};

pub const EventQueue = struct {
    mutex: std.Thread.Mutex = .{},
    events: std.ArrayList(Event) = .empty,
    gpa: std.mem.Allocator,
    kill: std.atomic.Value(bool) = .init(false),

    pub fn deinit(self: *EventQueue, gpa: std.mem.Allocator) !void {
        for (self.items) |*event| {
            event.deinit();
        }
        self.items.deinit(gpa);
    }

    pub fn postEvent(self: *EventQueue, event: Event) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.events.append(self.gpa, event) catch @panic("oom");
    }
    pub fn takeEventsOwned(self: *EventQueue) ![]Event {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.events.toOwnedSlice(self.gpa);
    }
};

const callbacks = struct {
    fn keyCallback(window: *zglfw.Window, key: zglfw.Key, scancode: i32, action: zglfw.Action, mods: zglfw.Mods) callconv(.c) void {
        const eq = window.getUserPointer(EventQueue).?;
        eq.postEvent(.{ .key = .{ .window = window, .key = key, .scancode = scancode, .action = action, .mods = mods } });
    }
    fn charCallback(window: *zglfw.Window, codepoint: u32) callconv(.c) void {
        const eq = window.getUserPointer(EventQueue).?;
        eq.postEvent(.{ .char = .{ .window = window, .codepoint = codepoint } });
    }
    fn scrollCallback(window: *zglfw.Window, xoffset: f64, yoffset: f64) callconv(.c) void {
        const eq = window.getUserPointer(EventQueue).?;
        eq.postEvent(.{ .scroll = .{ .window = window, .xoffset = xoffset, .yoffset = yoffset } });
    }
    fn cursorPosCallback(window: *zglfw.Window, xpos: f64, ypos: f64) callconv(.c) void {
        const eq = window.getUserPointer(EventQueue).?;
        eq.postEvent(.{ .cursorPos = .{ .window = window, .xpos = xpos, .ypos = ypos } });
    }
    fn cursorEnterCallback(window: *zglfw.Window, entered: i32) callconv(.c) void {
        const eq = window.getUserPointer(EventQueue).?;
        eq.postEvent(.{ .cursorEnter = .{ .window = window, .entered = entered } });
    }
    fn mouseButtonCallback(window: *zglfw.Window, button: zglfw.MouseButton, action: zglfw.Action, mods: zglfw.Mods) callconv(.c) void {
        const eq = window.getUserPointer(EventQueue).?;
        eq.postEvent(.{ .mouseButton = .{ .window = window, .button = button, .action = action, .mods = mods } });
    }
};

/// must be called on the main thread because of macos
pub fn eventThreadListen(window: *zglfw.Window, queue: *EventQueue) void {
    window.setUserPointer(@ptrCast(@alignCast(queue)));

    _ = window.setPosCallback(null);
    _ = window.setKeyCallback(&callbacks.keyCallback);
    _ = window.setSizeCallback(null);
    _ = window.setCharCallback(&callbacks.charCallback);
    _ = zglfw.setDropCallback(window, null);
    _ = zglfw.setScrollCallback(window, &callbacks.scrollCallback);
    _ = zglfw.setCursorPosCallback(window, &callbacks.cursorPosCallback);
    _ = zglfw.setCursorEnterCallback(window, &callbacks.cursorEnterCallback);
    _ = zglfw.setMouseButtonCallback(window, &callbacks.mouseButtonCallback);
    _ = window.setContentScaleCallback(null);
    _ = zglfw.setFramebufferSizeCallback(window, null);
    // _ = zglfw.setWindowRefreshCallback(window, null); // TODO we might want to use this?

    while (!queue.kill.load(.seq_cst)) {
        zglfw.waitEvents();
    }
}
