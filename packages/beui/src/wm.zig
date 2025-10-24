const std = @import("std");
const B2 = @import("beui_experiment.zig");
const Theme = @import("Theme.zig");
const blocks_mod = @import("blocks");
const util = @import("anywhere").util;
const bi = blocks_mod.blockinterface2;
const db_mod = blocks_mod.blockdb;

// TODO:
// - add a fullscreen button to wm:
//   - in final / tabbed windows, put a fullscreen button on the top right
//   - it makes that window fill the whole outer window, minus a bit of border around the edge to tell
//     you you're in fullscreen. you can click there or on the leave fullscrene button to get out.

// this is the backing wm
// but the caller will manage:
// - remove windows by id that no longer exist
pub const XY = B2.Axis;
pub const LR = B2.LR;
pub const Dir = B2.Direction;
// - ok so this is fine and works out. recap:
//   - all Final windows hold Blocks. a placeholder window is a window holding nothing.
//   - the blocks they hold are viewer blocks
//   - the blocks hold a reference to their application block so they can have behaviour for the application
//   - in your UI, you no longer declaratively say which windows to zopen
// - our existing UI:
//   - a Minigamer block holding a reference to (but not owning) the cart. this block is irregular, rather than
//     being editable/viewable by multiple people at once, it can only be edited by one. while held, it is
//     locked like steam cloud. if two offline devices edit it, there is a conflict and it needs resolution.
//     using presence, it could allow a multiplayer game that is hosted by one and viewed by another
//     but that is complicated and comes later.
//     - specifically it is {save_state: MinigamerSaveState} and savestate holds {contents: ..., cart: Ref}
// - transition period:
//   - [x] we'll create void blocks for each of the things
//     - [x] MinigamerBlock (not yet holding a MinigamerSaveState)
//     - [x] EditorBlock (not yet holding the editor state or scroll state or cursor state or any of that, just a filename for now)
//     - [x] DebugTextureBlock (just holding an index for now)
//     - [x] FileViewerBlock (void, not yet holding the map of (block ids => isopen) or the scroll state)
//   - [x] we'll update wm Final to hold a block reference
//     - i don't think this is quite what we want, how is a final supposed to be a fullscreen
//       overlay window then? we would like each thing to have a render fn
//       that can return a window with attributes. like "title", "kind", ...
//   - [ ] we'll add render methods to these blocks
//   - [x] we'll remove addWindow and instead render from the block's render method
//   - [ ] we'll move WM to be operation-based
//   - [ ] we'll add serialization/deserialization to WM (remember to use the gist! add it to anywhere/util)
//   - [ ] we'll add support for blocks to hold references to other blocks
//   - [ ] we'll change WM to be a block & update callsites
//   - [ ] we'll update the void blocks to not be so void anymore
//     - [ ] MinigamerBlock holds a MinigamerSaveState which holds {contents_id: ..., contents: []const u8, cart: Ref}
//       - it will have to deal with conflict management eventually
//     - [ ] EditorBlock holds scroll & cursor state & a reference to a TextBlock in the docs folder?
//     - [ ] DebugTextureBlock holds an index of the texture to view
//     - [ ] FileViewerBlock holds maybe a map of (block id => true) & scroll state
// - outstanding questions:
//   - what about a fullscreen overlay window?
//   - what about an application which has windows and a tray icon
//   - what about a notification? (a block seems resonable here and it can show then go to a history in a moment)
//   - do we really want every window to be a block? every application will have to define a block type for each
//     of its windows and parent ref to the application block. alternatively, apps could own their windows and render
//     them in a render fn based on their open window list.
pub const WM = struct {
    pub const FrameID = packed struct(u64) {
        gen: u32,
        ptr: enum(u32) {
            not_set = std.math.maxInt(u32) - 1,
            top_level = std.math.maxInt(u32),
            _,
        },
        pub const not_set = FrameID{ .gen = 0, .ptr = .not_set };
        pub const top_level = FrameID{ .gen = 0, .ptr = .top_level };

        pub fn format(value: FrameID, writer: *std.Io.Writer) !void {
            try writer.print("@{d}.{d}", .{ value.gen, @intFromEnum(value.ptr) });
        }
        fn fromTest(a: u32, b: u32) FrameID {
            return .{ .gen = a, .ptr = @enumFromInt(b) };
        }
    };
    pub const Frame = struct {
        gen: u32,
        parent: FrameID,
        id: FrameID,
        self: FrameContent,
        collapsed: bool = false,
        fn _setParent(self: *Frame, parent: FrameID) void {
            std.debug.assert(self.parent == FrameID.not_set);
            std.debug.assert(parent != FrameID.not_set);
            self.parent = parent;
        }
        pub fn clear(self: *Frame) void {
            self.* = .{ .gen = self.gen + 1, .parent = .not_set, .id = .not_set, .self = .none };
        }
    };
    const FrameContent = union(enum) {
        pub const Tabbed = struct {
            current_tab: FrameID,
            children: std.ArrayListUnmanaged(FrameID),
        };
        pub const Split = struct {
            axis: XY,
            // center: FrameID[]
            // left[]
            // right[]
            // left & right store size in pixels
            // center stores sizes in percentages
            // this would be hard to have clear ui for, but if you're
            //   making an app where tabs are locked in a tab area
            //   by default, it would be nice.
            children: std.ArrayListUnmanaged(FrameID),
            percentages: std.ArrayListUnmanaged(f32),
        };
        tabbed: Tabbed,
        split: Split,
        final: struct {
            // null indicates this is a placeholder window that does not contain any block
            ref: ?*db_mod.BlockRef = null,
        },
        window: struct {
            child: FrameID,
        },
        dragging: struct {
            child: FrameID,
        },
        /// unreachable
        none,
        pub fn children(self: *FrameContent) []FrameID {
            switch (self.*) {
                inline .tabbed, .split => |s| return s.children.items,
                .final => return &.{},
                .window => |*w| return @as(*[1]FrameID, &w.child),
                .dragging => |*w| return @as(*[1]FrameID, &w.child),
                .none => @panic("frame is none"),
            }
        }
        pub fn deinit(self: *FrameContent, gpa: std.mem.Allocator) void {
            switch (self.*) {
                .tabbed => |*s| s.children.deinit(gpa),
                .split => |*s| {
                    s.children.deinit(gpa);
                    s.percentages.deinit(gpa);
                },
                .final => |f| {
                    if (f.ref) |r| r.unref();
                },
                else => {},
            }
        }
    };
    gpa: std.mem.Allocator,
    frames: std.ArrayListUnmanaged(Frame),
    unused_frames: std.ArrayListUnmanaged(FrameID),
    dragging: FrameID = .not_set,

    top_level_windows: std.ArrayListUnmanaged(FrameID),

    pub fn init(gpa: std.mem.Allocator) WM {
        return .{
            .gpa = gpa,
            .frames = .empty,
            .unused_frames = .empty,
            .top_level_windows = .empty,
        };
    }
    pub fn deinit(self: *WM) void {
        for (self.frames.items) |*f| {
            // if we swith to a memorypool, this will have to change
            if (f.self != .none) f.self.deinit(self.gpa);
        }

        // deinit things
        self.unused_frames.deinit(self.gpa);
        self.frames.deinit(self.gpa);
        self.top_level_windows.deinit(self.gpa);
    }

    pub fn addFrame(self: *WM, value: FrameContent) FrameID {
        const id: FrameID = if (self.unused_frames.pop()) |reuse| blk: {
            break :blk reuse;
        } else blk: {
            const res: FrameID = .{ .gen = 0, .ptr = @enumFromInt(self.frames.items.len) };
            self.frames.append(self.gpa, .{ .gen = res.gen, .parent = .not_set, .id = res, .self = value }) catch @panic("oom");
            break :blk res;
        };
        self.getFrame(id).* = .{
            .gen = id.gen,
            .parent = .not_set,
            .id = id,
            .self = value,
        };

        for (self.getFrame(id).self.children()) |child| {
            self.getFrame(child)._setParent(id);
        }
        return id;
    }
    pub fn existsFrame(self: *WM, frame: FrameID) bool {
        const res = &self.frames.items[@intFromEnum(frame.ptr)];
        return res.gen == frame.gen;
    }
    pub fn getFrame(self: *WM, frame: FrameID) *Frame {
        const res = &self.frames.items[@intFromEnum(frame.ptr)];
        if (res.gen != frame.gen) unreachable; // consider returning null in this case
        return res;
    }

    fn _removeNode(self: *WM, frame_id: FrameID) void {
        const pval = self.getFrame(frame_id);
        std.debug.assert(pval.self != .none);
        pval.self.deinit(self.gpa);
        pval.clear();
        self.unused_frames.append(self.gpa, .{ .gen = pval.gen, .ptr = frame_id.ptr }) catch @panic("oom");
    }
    fn _removeTree(self: *WM, frame_id: FrameID) void {
        const frame = self.getFrame(frame_id);
        for (frame.self.children()) |child| {
            self._removeTree(child);
        }
        self._removeNode(frame_id);
    }
    pub fn removeFrame(self: *WM, frame_id: FrameID) void {
        self._tellParentChildRemoved(frame_id);
        self._removeTree(frame_id);
    }
    fn _tellParentChildRemoved(self: *WM, child: FrameID) void {
        const child_frame = self.getFrame(child);
        const parent = child_frame.parent;
        if (parent == FrameID.top_level) unreachable; // not allowed
        if (parent == FrameID.not_set) return; // no parent to inform
        const parent_frame = self.getFrame(parent);
        switch (parent_frame.self) {
            inline .tabbed, .split => |*sv| {
                const idx = std.mem.indexOfScalar(FrameID, sv.children.items, child) orelse unreachable;
                _ = sv.children.orderedRemove(idx);
                if (@TypeOf(sv.*) == FrameContent.Split) {
                    _ = sv.percentages.orderedRemove(idx);
                }
                if (sv.children.items.len == 0) unreachable;
                if (sv.children.items.len == 1) {
                    self.getFrame(sv.children.items[0]).parent = .not_set;
                    self._replaceChild(parent_frame.parent, parent, sv.children.items[0]);
                    self._removeNode(parent);
                } else if (@TypeOf(sv.*) == FrameContent.Tabbed) {
                    sv.current_tab = sv.children.items[idx -| 1];
                }
            },
            .final => unreachable, // has no children
            .window => |win| {
                // the window must be removed
                std.debug.assert(win.child == child);
                self._removeNode(parent);
                const idx = std.mem.indexOfScalar(FrameID, self.top_level_windows.items, parent) orelse unreachable;
                _ = self.top_level_windows.orderedRemove(idx);
            },
            .dragging => |win| {
                // ungrab
                std.debug.assert(win.child == child);
                self._removeNode(parent);
                std.debug.assert(self.dragging == parent);
                self.dragging = .not_set;
            },
            .none => unreachable,
        }
    }
    pub fn grabFrame(self: *WM, frame_id: FrameID) void {
        if (self.dragging != FrameID.not_set) {
            self.dropFrameToNewWindow();
        }
        self._tellParentChildRemoved(frame_id);
        self.getFrame(frame_id).parent = .not_set;
        self.dragging = self.addFrame(.{ .dragging = .{ .child = frame_id } });
        self.getFrame(self.dragging).parent = .top_level;
    }
    fn _replaceChild(self: *WM, parent: FrameID, prev_child: FrameID, next_child: FrameID) void {
        const children = self.getFrame(parent).self.children();
        children[std.mem.indexOfScalar(FrameID, children, prev_child) orelse unreachable] = next_child;
        switch (self.getFrame(parent).self) {
            .tabbed => |*t| {
                t.current_tab = next_child;
            },
            else => {},
        }
        self.getFrame(next_child)._setParent(parent);
    }
    pub fn moveFrameNewWindow(self: *WM, child: FrameID) void {
        self._tellParentChildRemoved(child);
        self.getFrame(child).parent = .not_set;

        const window_id = self.addFrame(.{ .window = .{ .child = child } });
        self.top_level_windows.append(self.gpa, window_id) catch @panic("oom");
        self.getFrame(window_id).parent = .top_level;
    }
    pub fn dropFrameToNewWindow(self: *WM) void {
        if (self.dragging == FrameID.not_set) return;
        const child = self.getFrame(self.dragging).self.dragging.child;
        self.moveFrameNewWindow(child);
    }
    pub fn dropFrameToSplit(self: *WM, target: FrameID, target_dir: Dir) void {
        std.debug.assert(self.dragging != FrameID.not_set);
        const child = self.getFrame(self.dragging).self.dragging.child;
        self.moveFrameToSplit(child, target, target_dir);
    }
    pub fn moveFrameToSplit(self: *WM, child: FrameID, target: FrameID, target_dir: Dir) void {
        self._tellParentChildRemoved(child);

        const target_parent = self.getFrame(target).parent;
        const offset: usize, const split: FrameID = if (self.getFrame(target_parent).self == .split and self.getFrame(target_parent).self.split.axis == target_dir.toAxis()) blk: {
            const idxof = std.mem.indexOfScalar(FrameID, self.getFrame(target_parent).self.split.children.items, target) orelse unreachable;
            break :blk .{ idxof, target_parent };
        } else if (self.getFrame(target).self == .split and self.getFrame(target).self.split.axis == target_dir.toAxis()) blk: {
            break :blk .{ if (target_dir.idx() == 0) 0 else self.getFrame(target).self.split.children.items.len - 1, target };
        } else blk: {
            const split = self.addFrame(.{ .split = .{
                .axis = target_dir.toAxis(),
                .children = .empty,
                .percentages = .empty,
            } });
            self.getFrame(split).self.split.children.append(self.gpa, target) catch @panic("oom");
            self.getFrame(split).self.split.percentages.append(self.gpa, 1) catch @panic("oom");
            self._replaceChild(target_parent, target, split);
            self.getFrame(target).parent = .not_set;
            self.getFrame(target)._setParent(split);
            break :blk .{ 0, split };
        };
        if (self.getFrame(child).self == .split and self.getFrame(child).self.split.axis == target_dir.toAxis()) {
            @panic("TODO support drop split in split");
        }
        self.getFrame(split).self.split.children.insert(self.gpa, offset + target_dir.idx(), child) catch @panic("oom");
        self.getFrame(split).self.split.percentages.insert(self.gpa, offset + target_dir.idx(), 1) catch @panic("oom");
        self.getFrame(child).parent = .not_set;
        self.getFrame(child)._setParent(split);
    }
    pub fn dropFrameToTab(self: *WM, target: FrameID, target_dir: LR) void {
        std.debug.assert(self.dragging != FrameID.not_set);
        const child = self.getFrame(self.dragging).self.dragging.child;
        self.moveFrameToTab(child, target, target_dir);
    }
    pub fn moveFrameToTab(self: *WM, child: FrameID, target: FrameID, target_dir: LR) void {
        self._tellParentChildRemoved(child);

        const target_parent = self.getFrame(target).parent;
        const offset: usize, const tabbed: FrameID = if (self.getFrame(target_parent).self == .tabbed) blk: {
            const idxof = std.mem.indexOfScalar(FrameID, self.getFrame(target_parent).self.tabbed.children.items, target) orelse unreachable;
            break :blk .{ idxof, target_parent };
        } else blk: {
            const tabbed = self.addFrame(.{ .tabbed = .{
                .current_tab = target,
                .children = .empty,
            } });
            self.getFrame(tabbed).self.tabbed.children.append(self.gpa, target) catch @panic("oom");
            self._replaceChild(target_parent, target, tabbed);
            self.getFrame(target).parent = .not_set;
            self.getFrame(target)._setParent(tabbed);
            break :blk .{ 0, tabbed };
        };
        self.getFrame(tabbed).self.tabbed.children.insert(self.gpa, offset + target_dir.idx(), child) catch @panic("oom");
        self.getFrame(tabbed).self.tabbed.current_tab = child;
        self.getFrame(child).parent = .not_set;
        self.getFrame(child)._setParent(tabbed);
    }
    pub fn bringToFront(self: *WM, target: FrameID) void {
        // find parent
        const parentmost = self.findRoot(target);
        switch (self.getFrame(parentmost).self) {
            .window => {
                const idx = std.mem.indexOfScalar(FrameID, self.top_level_windows.items, parentmost) orelse unreachable;
                _ = self.top_level_windows.orderedRemove(idx);
                self.top_level_windows.appendAssumeCapacity(parentmost);
            },
            else => unreachable, // no other parentmost window types
        }
    }
    pub fn selectTab(self: *WM, tab: FrameID) void {
        const parent = self.getFrame(tab).parent;
        if (parent.ptr == .not_set or parent.ptr == .top_level) return;
        switch (self.getFrame(parent).self) {
            .tabbed => |*t| {
                t.current_tab = tab;
            },
            else => {},
        }
    }
    pub fn findRoot(self: *WM, target: FrameID) FrameID {
        var parentmost: FrameID = target;
        while (self.getFrame(parentmost).parent != FrameID.top_level) {
            parentmost = self.getFrame(parentmost).parent;
        }
        std.debug.assert(self.getFrame(parentmost).parent == FrameID.top_level);
        return parentmost;
    }

    pub fn testingRenderToString(self: *WM, buf: *std.array_list.Managed(u8)) ![]const u8 {
        buf.clearAndFree();

        for (self.top_level_windows.items) |tlw| {
            try self._renderFrameToString(tlw, .top_level, buf, 1);
            try buf.appendSlice("\n");
        }

        if (self.dragging != FrameID.not_set) {
            try self._renderFrameToString(self.dragging, .top_level, buf, 1);
            try buf.appendSlice("\n");
        }

        if (std.mem.endsWith(u8, buf.items, "\n")) return buf.items[0 .. buf.items.len - 1];
        return buf.items;
    }
    fn _printIndent(out: *std.array_list.Managed(u8), indent: usize) !void {
        try out.append('\n');
        try out.appendNTimes(' ', indent * 4);
    }
    fn _renderFrameToString(self: *WM, frame_id: FrameID, expect_parent: FrameID, out: *std.array_list.Managed(u8), indent: usize) !void {
        const frame = self.getFrame(frame_id);
        try std.testing.expectEqual(frame.id, frame_id);
        if (expect_parent != frame.parent) {
            try out.writer().print("(expected parent = {f}, got parent = {f} for item {f})", .{ expect_parent, frame.parent, frame_id });
        }

        try out.writer().print("{f}.{s}", .{ frame_id, @tagName(frame.self) });
        switch (frame.self) {
            .tabbed => |s| {
                if (s.children.items.len < 2) unreachable;
                try out.writer().print(": {f}", .{s.current_tab});
                for (s.children.items) |child| {
                    try _printIndent(out, indent);
                    try self._renderFrameToString(child, frame_id, out, indent + 1);
                }
            },
            .split => |s| {
                if (s.children.items.len < 2) unreachable;
                try out.writer().print(".{s}:", .{@tagName(s.axis)});
                for (s.children.items, s.percentages.items) |child, percent| {
                    try _printIndent(out, indent);
                    try out.writer().print("{d:.1}: ", .{percent});
                    try self._renderFrameToString(child, frame_id, out, indent + 1);
                }
            },
            .final => {},
            .window => |w| {
                try out.appendSlice(": ");
                try self._renderFrameToString(w.child, frame_id, out, indent);
            },
            .dragging => |d| {
                try out.appendSlice(": ");
                try self._renderFrameToString(d.child, frame_id, out, indent);
            },
            .none => unreachable,
        }
    }
};

test WM {
    var my_wm = WM.init(std.testing.allocator);
    defer my_wm.deinit();

    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();

    try std.testing.expectEqualStrings("", try my_wm.testingRenderToString(&buf));
    my_wm.moveFrameNewWindow(my_wm.addFrame(.{ .final = .{} }));
    try std.testing.expectEqualStrings(
        \\@0.1.window: @0.0.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.moveFrameNewWindow(my_wm.addFrame(.{ .final = .{} }));
    try std.testing.expectEqualStrings(
        \\@0.1.window: @0.0.final
        \\@0.3.window: @0.2.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.removeFrame(.fromTest(0, 0));
    try std.testing.expectEqualStrings(
        \\@0.3.window: @0.2.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.removeFrame(.fromTest(0, 2));
    try std.testing.expectEqualStrings(
        \\
    , try my_wm.testingRenderToString(&buf));

    my_wm.moveFrameNewWindow(my_wm.addFrame(.{ .final = .{} }));
    my_wm.moveFrameNewWindow(my_wm.addFrame(.{ .final = .{} }));
    try std.testing.expectEqualStrings(
        \\@1.3.window: @1.2.final
        \\@1.1.window: @1.0.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.grabFrame(.fromTest(1, 2));
    try std.testing.expectEqualStrings(
        \\@1.1.window: @1.0.final
        \\@2.3.dragging: @1.2.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.dropFrameToSplit(.fromTest(1, 0), .left);
    try std.testing.expectEqualStrings(
        \\@1.1.window: @3.3.split.x:
        \\    1.0: @1.2.final
        \\    1.0: @1.0.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.moveFrameNewWindow(my_wm.addFrame(.{ .final = .{} }));
    try std.testing.expectEqualStrings(
        \\@1.1.window: @3.3.split.x:
        \\    1.0: @1.2.final
        \\    1.0: @1.0.final
        \\@0.5.window: @0.4.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.grabFrame(.fromTest(0, 4));
    my_wm.dropFrameToSplit(.fromTest(1, 0), .right);
    try std.testing.expectEqualStrings(
        \\@1.1.window: @3.3.split.x:
        \\    1.0: @1.2.final
        \\    1.0: @1.0.final
        \\    1.0: @0.4.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.grabFrame(.fromTest(1, 0));
    try std.testing.expectEqualStrings(
        \\@1.1.window: @3.3.split.x:
        \\    1.0: @1.2.final
        \\    1.0: @0.4.final
        \\@2.5.dragging: @1.0.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.dropFrameToNewWindow();
    try std.testing.expectEqualStrings(
        \\@1.1.window: @3.3.split.x:
        \\    1.0: @1.2.final
        \\    1.0: @0.4.final
        \\@3.5.window: @1.0.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.grabFrame(.fromTest(1, 2));
    try std.testing.expectEqualStrings(
        \\@1.1.window: @0.4.final
        \\@3.5.window: @1.0.final
        \\@4.3.dragging: @1.2.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.dropFrameToTab(.fromTest(1, 0), .left);
    try std.testing.expectEqualStrings(
        \\@1.1.window: @0.4.final
        \\@3.5.window: @5.3.tabbed: @1.2
        \\    @1.2.final
        \\    @1.0.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.grabFrame(.fromTest(0, 4));
    try std.testing.expectEqualStrings(
        \\@3.5.window: @5.3.tabbed: @1.2
        \\    @1.2.final
        \\    @1.0.final
        \\@2.1.dragging: @0.4.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.dropFrameToTab(.fromTest(1, 0), .right);
    try std.testing.expectEqualStrings(
        \\@3.5.window: @5.3.tabbed: @0.4
        \\    @1.2.final
        \\    @1.0.final
        \\    @0.4.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.grabFrame(.fromTest(0, 4));
    try std.testing.expectEqualStrings(
        \\@3.5.window: @5.3.tabbed: @1.0
        \\    @1.2.final
        \\    @1.0.final
        \\@3.1.dragging: @0.4.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.dropFrameToSplit(.fromTest(1, 2), .bottom);
    try std.testing.expectEqualStrings(
        \\@3.5.window: @5.3.tabbed: @4.1
        \\    @4.1.split.y:
        \\        1.0: @1.2.final
        \\        1.0: @0.4.final
        \\    @1.0.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.grabFrame(.fromTest(1, 0));
    try std.testing.expectEqualStrings(
        \\@3.5.window: @4.1.split.y:
        \\    1.0: @1.2.final
        \\    1.0: @0.4.final
        \\@6.3.dragging: @1.0.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.dropFrameToSplit(.fromTest(0, 4), .left);
    try std.testing.expectEqualStrings(
        \\@3.5.window: @4.1.split.y:
        \\    1.0: @1.2.final
        \\    1.0: @7.3.split.x:
        \\        1.0: @1.0.final
        \\        1.0: @0.4.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.moveFrameNewWindow(my_wm.addFrame(.{ .final = .{} }));
    try std.testing.expectEqualStrings(
        \\@3.5.window: @4.1.split.y:
        \\    1.0: @1.2.final
        \\    1.0: @7.3.split.x:
        \\        1.0: @1.0.final
        \\        1.0: @0.4.final
        \\@0.7.window: @0.6.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.grabFrame(.fromTest(4, 1));
    try std.testing.expectEqualStrings(
        \\@0.7.window: @0.6.final
        \\@4.5.dragging: @4.1.split.y:
        \\    1.0: @1.2.final
        \\    1.0: @7.3.split.x:
        \\        1.0: @1.0.final
        \\        1.0: @0.4.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.dropFrameToTab(.fromTest(0, 6), .right);
    try std.testing.expectEqualStrings(
        \\@0.7.window: @5.5.tabbed: @4.1
        \\    @0.6.final
        \\    @4.1.split.y:
        \\        1.0: @1.2.final
        \\        1.0: @7.3.split.x:
        \\            1.0: @1.0.final
        \\            1.0: @0.4.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.removeFrame(.fromTest(1, 2));
    try std.testing.expectEqualStrings(
        \\@0.7.window: @5.5.tabbed: @7.3
        \\    @0.6.final
        \\    @7.3.split.x:
        \\        1.0: @1.0.final
        \\        1.0: @0.4.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.removeFrame(.fromTest(7, 3));
    try std.testing.expectEqualStrings(
        \\@0.7.window: @0.6.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.moveFrameNewWindow(my_wm.addFrame(.{ .final = .{} }));
    try std.testing.expectEqualStrings(
        \\@0.7.window: @0.6.final
        \\@1.4.window: @8.3.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.bringToFront(.fromTest(0, 7));
    try std.testing.expectEqualStrings(
        \\@1.4.window: @8.3.final
        \\@0.7.window: @0.6.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.bringToFront(.fromTest(0, 6));
    try std.testing.expectEqualStrings(
        \\@1.4.window: @8.3.final
        \\@0.7.window: @0.6.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.bringToFront(.fromTest(8, 3));
    try std.testing.expectEqualStrings(
        \\@0.7.window: @0.6.final
        \\@1.4.window: @8.3.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.bringToFront(.fromTest(1, 4));
    try std.testing.expectEqualStrings(
        \\@0.7.window: @0.6.final
        \\@1.4.window: @8.3.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.moveFrameToSplit(.fromTest(0, 6), .fromTest(8, 3), .right);
    try std.testing.expectEqualStrings(
        \\@1.4.window: @1.7.split.x:
        \\    1.0: @8.3.final
        \\    1.0: @0.6.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.moveFrameToSplit(my_wm.addFrame(.{ .final = .{} }), .fromTest(0, 6), .right);
    try std.testing.expectEqualStrings(
        \\@1.4.window: @1.7.split.x:
        \\    1.0: @8.3.final
        \\    1.0: @0.6.final
        \\    1.0: @2.0.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.moveFrameToSplit(my_wm.addFrame(.{ .final = .{} }), .fromTest(1, 7), .right);
    try std.testing.expectEqualStrings(
        \\@1.4.window: @1.7.split.x:
        \\    1.0: @8.3.final
        \\    1.0: @0.6.final
        \\    1.0: @2.0.final
        \\    1.0: @6.5.final
    , try my_wm.testingRenderToString(&buf));
}

// could make this <Manager> <addWindow /> <addWindow> <addWindow /> </addWindow> ... </Manager>
// (rather than being a global thing managed by beui itself)
// but that means you would have to be passing around *Manager pointers or you would need to use a context provider
// and wm is going to handle stuff like dropdown menus, ... so basically everything needs it
//
// TODO:
// - top_level_window_positions_and_sizes belongs in the WM instance
pub const Manager = struct {
    /// should this data be in WM rather than in Manager?
    const TLFInfo = struct {
        pos: @Vector(2, f32),
        size: @Vector(2, f32),
        _minitial: ?@Vector(2, f32), // kind of a hack, not sure what the final method of doing this will be
    };

    wm: WM,
    /// stored for both the 'window' and the item directly inside it
    top_level_window_positions_and_sizes: std.AutoArrayHashMapUnmanaged(WM.FrameID, TLFInfo),

    id_to_final_map: B2.IdArrayMapUnmanaged(WM.FrameID),
    final_to_id_map: std.AutoArrayHashMapUnmanaged(WM.FrameID, B2.ID),
    this_frame: std.ArrayListUnmanaged(struct {
        id_unowned: B2.ID,
        frame_id: WM.FrameID,
        title: []const u8,
        cb: B2.Component(B2.StandardCallInfo, void, *B2.RepositionableDrawList),
    }),

    final_rdl: ?*B2.RepositionableDrawList,
    id_for_frame: ?B2.ID.LoopValue(WM.FrameID),

    /// not owned
    current_window: ?B2.ID,

    active: ?FrameCfg,
    dragging: struct {
        pos: @Vector(2, f32) = @splat(0),
        anim_start: @Vector(2, f32) = @splat(0),
        anim_start_ms: i64 = 0,
    } = .{},

    pub const FrameCfg = struct {
        size: @Vector(2, f32),
        id: B2.ID,
    };
    pub const RenderWindowResult = std.AutoHashMapUnmanaged(WM.FrameID, RenderWindowCtx);
    pub const RenderWindowCtx = struct {
        title: []const u8,
        result: union(enum) {
            filled: struct {
                pos: @Vector(2, f32),
                size: @Vector(2, f32),
                reservation: B2.RepositionableDrawList.Reservation,
            },
            empty: struct {},
        },
    };

    pub fn init(gpa: std.mem.Allocator) Manager {
        return .{
            .wm = .init(gpa),
            .top_level_window_positions_and_sizes = .empty,
            .id_to_final_map = .empty,
            .final_to_id_map = .empty,
            .this_frame = .empty,
            .current_window = null,
            .active = null,
            .final_rdl = null,
            .id_for_frame = null,
        };
    }
    pub fn deinit(self: *Manager) void {
        for (self.id_to_final_map.keys()) |*id| {
            id.deinitOwned(self.wm.gpa);
        }
        self.id_to_final_map.deinit(self.wm.gpa);
        self.final_to_id_map.deinit(self.wm.gpa);
        self.top_level_window_positions_and_sizes.deinit(self.wm.gpa);
        self.this_frame.deinit(self.wm.gpa);
        self.wm.deinit();
    }

    pub fn getWindowInfo(self: *Manager, win: WM.FrameID) *const TLFInfo {
        // return the value for the frame
        // return the value for the window within the frame
        const frame = self.wm.getFrame(win);
        const child: ?WM.FrameID = if (frame.self == .window) frame.self.window.child else null;
        if (self.top_level_window_positions_and_sizes.getPtr(win)) |val| return val;
        if (child != null) if (self.top_level_window_positions_and_sizes.getPtr(child.?)) |val| return val;
        // window is missing info
        self.setWindowInfo(win, .{ .pos = .{ 20, 20 }, .size = .{ 300, 300 }, ._minitial = null });
        return self.top_level_window_positions_and_sizes.getPtr(win).?;
    }
    pub fn setWindowInfo(self: *Manager, win: WM.FrameID, value: TLFInfo) void {
        const frame = self.wm.getFrame(win);
        const child: ?WM.FrameID = if (frame.self == .window) frame.self.window.child else null;
        self.top_level_window_positions_and_sizes.put(self.wm.gpa, win, value) catch @panic("oom");
        if (child != null) self.top_level_window_positions_and_sizes.put(self.wm.gpa, child.?, value) catch @panic("oom");
    }
    pub fn beginResize(self: *Manager, win: WM.FrameID, mpos: @Vector(2, f32)) void {
        var wi = self.getWindowInfo(win).*;
        wi._minitial = mpos;
        self.setWindowInfo(win, wi);
    }
    pub fn updateResize(self: *Manager, win: WM.FrameID, sides: B2.Sides, mpos: @Vector(2, f32)) void {
        const wi = self.getWindowInfo(win).*;
        if (wi._minitial == null) return;
        const offset = mpos - wi._minitial.?;
        var x1 = wi.pos[0];
        var x2 = wi.pos[0] + wi.size[0];
        var y1 = wi.pos[1];
        var y2 = wi.pos[1] + wi.size[1];
        if (sides._left) x1 += offset[0];
        if (sides._top) y1 += offset[1];
        if (sides._right) x2 += offset[0];
        if (sides._bottom) y2 += offset[1];
        self.setWindowInfo(win, .{
            .pos = .{ x1, y1 },
            .size = .{ x2 - x1, y2 - y1 },
            ._minitial = mpos, // ideally we wouldn't modify this I think?
        });
    }
    pub fn endResize(self: *Manager, win: WM.FrameID) void {
        var wi = self.getWindowInfo(win).*;
        wi._minitial = null;
        self.setWindowInfo(win, wi);
    }

    pub fn idForFrame(self: *Manager, src: std.builtin.SourceLocation, frame: WM.FrameID) B2.ID {
        return self.id_for_frame.?.value(src, frame);
    }

    pub fn beginFrame(self: *Manager, cfg: FrameCfg) void {
        std.debug.assert(self.active == null);
        self.active = cfg;

        // clean id_to_final / final_to_id maps of closed windows
        {
            var i: usize = 0;
            while (i < self.final_to_id_map.keys().len) {
                const keys = self.final_to_id_map.keys();
                const values = self.final_to_id_map.values();
                const final = keys[i];
                if (!self.wm.existsFrame(final)) {
                    // delete
                    std.debug.assert(self.id_to_final_map.swapRemove(values[i]));
                    values[i].deinitOwned(self.wm.gpa);
                    self.final_to_id_map.swapRemoveAt(i);
                } else {
                    i += 1;
                }
            }
        }
        // clean top_level_window_positions_and_sizes of closed windows
        {
            var i: usize = 0;
            while (i < self.top_level_window_positions_and_sizes.keys().len) {
                const keys = self.top_level_window_positions_and_sizes.keys();
                const final = keys[i];
                if (!self.wm.existsFrame(final)) {
                    self.top_level_window_positions_and_sizes.swapRemoveAt(i);
                } else {
                    i += 1;
                }
            }
        }

        self.final_rdl = cfg.id.b2.draw();
        self.id_for_frame = cfg.id.pushLoop(@src(), WM.FrameID);
    }
    pub const RenderBlockArg = struct {
        call_info: B2.StandardCallInfo,
        block: ?*db_mod.BlockRef,
    };
    pub const RenderBlockCB = util.Callback(RenderBlockArg, *B2.RepositionableDrawList);
    pub fn endFrame(self: *Manager, cb: RenderBlockCB) *B2.RepositionableDrawList {
        std.debug.assert(self.active != null);
        const cfg = self.active.?;
        self.active = null;

        // at end of frame vs during frame:
        // - during frame:
        //   - 0 frame delay for closing windows because that is handled between frames
        //   - 1 frame delay for a window closed by an if statement, but only if it is a subframe of a frame with another frame
        //     - must make sure to call requiresRerender in this case
        //   - Theme provides a function to render a given root frame
        //   - window may be rendered inside of another window's callback
        //     - but collapsing the outer window will close the inner window. and uncollapsing the outer window will spawn
        //       a new inner window with reset size & position. so this seems like odd behaviour.
        //   - callback is run during the addWindow function call, which is expected
        // - at end of frame:
        //   - 0 frame delay for closing windows, including windows closed by an if statement
        //   - Theme provides a function to render an entire WM instance
        //     - excluding fullscreen overlays, dropdown menus, and some other things
        //   - callback must only point to frame-allocated memory, not stack-allocated. this is unusual, as typically component
        //     callbacks are called immediately
        //   - windows may not be rendered inside another window's callback. dropdown menus and other overlays will be
        //     handled by a different fn. dropdowns can't be handled by the Theme render.

        // 1. update wm:
        //     - remove closed windows
        //       - ideally most windows are closed between frames rather than during a frame. a window
        //         that is closed during a frame could have been closed by an if statement, which is weird.
        //     - save titles

        // 2. call Theme.renderWindows();
        const rdl = Theme.renderWindows(.{ .b2 = cfg.id.b2, .cb = cb, .man = self }, cfg.size);

        self.this_frame.clearRetainingCapacity();

        self.final_rdl.?.place(rdl, .{});
        self.id_for_frame = null;
        defer self.final_rdl = null;
        return self.final_rdl.?;
    }

    /// callback will be called at the end of the frame! callback data ptr must be allocated by the frame arena! no stack data!
    pub fn addWindow(self: *Manager, id_unowned: B2.ID, title: []const u8, cb: B2.Component(B2.StandardCallInfo, void, *B2.RepositionableDrawList)) void {
        std.debug.assert(self.active != null);

        // 1. get the final frame id for the passed in id_unowned
        //    - not found? create a new frame
        const frame_id_gpres = self.id_to_final_map.getOrPut(self.wm.gpa, id_unowned) catch @panic("oom");
        if (!frame_id_gpres.found_existing) {
            frame_id_gpres.key_ptr.* = id_unowned.dupeToOwned(self.wm.gpa);
            const frame_id = self.wm.addFrame(.{ .final = .{} });
            self.wm.moveFrameNewWindow(frame_id);
            frame_id_gpres.value_ptr.* = frame_id;
            self.final_to_id_map.putNoClobber(self.wm.gpa, frame_id_gpres.value_ptr.*, frame_id_gpres.key_ptr.*) catch @panic("oom");
        }
        const frame_id = frame_id_gpres.value_ptr.*;

        self.this_frame.append(self.wm.gpa, .{
            .id_unowned = id_unowned,
            .frame_id = frame_id,
            .title = id_unowned.b2.frame.arena.dupe(u8, title) catch @panic("oom"),
            .cb = cb,
        }) catch @panic("oom");
    }

    pub fn addFullscreenOverlay(self: *Manager, id_unowned: B2.ID, cb: B2.Component(B2.StandardCallInfo, void, *B2.RepositionableDrawList)) void {
        std.debug.assert(self.active != null);
        std.debug.assert(self.current_window == null);
        const result = cb.call(.{ .caller_id = id_unowned.sub(@src()), .constraints = .{ .available_size = .{ .w = self.active.?.size[0], .h = self.active.?.size[1] } } }, {});
        self.final_rdl.?.place(result, .{});
    }
};

// next todo:
// - information:
//   - top level window has position, size
//   - split has percentages (or absolute sizes for all but one?) for each child
//   - move & resize top level
//   - resize split boundaries
// - alwaysonbottom items
// - fullscreen_overlay items
// - bring to front
// - collapsing: have to decide what can be collapsed? eg all but one of a split window
// - dragging window from top level to tab, then dragging out from tab back to top level should preserve size.
//   - this means each 'final' window has a 'top_level_size' that is used when it becomes top level
// - figure out what to do about preview vs commit. and how to do smooth tab reordering.
