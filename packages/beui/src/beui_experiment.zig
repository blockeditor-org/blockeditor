const std = @import("std");

const Beui = @import("Beui.zig");
const render_list = @import("render_list.zig");
const tracy = @import("anywhere").tracy;
const util = @import("anywhere").util;
const LayoutCache = @import("LayoutCache.zig");
pub const Theme = @import("Theme.zig");
pub const WM = @import("wm.zig");
pub const ImageCache = @import("ImageCache.zig");

pub const components = struct {
    pub const Icon = @import("components/Icon.zig");
    pub const Tree = @import("components/Tree.zig");
};

pub fn IdMap(comptime V: type) type {
    const IDContext = struct {
        pub fn hash(_: @This(), id: ID) u64 {
            return id.hash();
        }
        pub fn eql(_: @This(), a: ID, b: ID) bool {
            return a.eql(b);
        }
    };
    return std.HashMap(ID, V, IDContext, std.hash_map.default_max_load_percentage);
}
pub fn IdMapUnmanaged(comptime V: type) type {
    const IDContext = struct {
        pub fn hash(_: @This(), id: ID) u64 {
            return id.hash();
        }
        pub fn eql(_: @This(), a: ID, b: ID) bool {
            return a.eql(b);
        }
    };
    return std.HashMapUnmanaged(ID, V, IDContext, std.hash_map.default_max_load_percentage);
}
pub fn IdArrayMap(comptime V: type) type {
    const IDContext = struct {
        pub fn hash(_: @This(), id: ID) u32 {
            return @truncate(id.hash());
        }
        pub fn eql(_: @This(), a: ID, b: ID, _: usize) bool {
            return a.eql(b);
        }
    };
    // store_hash is set to false. eql is just `std.mem.eql()` but for long strings that could take longer than we want?
    // shouldn't store_hash be true?
    return std.ArrayHashMap(ID, V, IDContext, false);
}
pub fn IdArrayMapUnmanaged(comptime V: type) type {
    const IDContext = struct {
        pub fn hash(_: @This(), id: ID) u32 {
            return @truncate(id.hash());
        }
        pub fn eql(_: @This(), a: ID, b: ID, _: usize) bool {
            return a.eql(b);
        }
    };
    // store_hash is set to false. eql is just `std.mem.eql()` but for long strings that could take longer than we want?
    // shouldn't store_hash be true?
    return std.ArrayHashMapUnmanaged(ID, V, IDContext, false);
}

const Beui2FrameCfg = struct {
    size: @Vector(2, f32),
};
const Beui2Frame = struct {
    arena: std.mem.Allocator,
    frame_cfg: Beui2FrameCfg,
    scroll_target: ?ScrollTarget,
    overlay_rdl: *RepositionableDrawList,
};
const ScrollTarget = struct {
    id: ID,
    scroll: @Vector(2, f32),
};
const MouseEventInfo = struct {
    offset: @Vector(2, f32),
    observed_mouse_down: bool = false,
};
const StateValue = struct {
    data: []u8,
    log2_align: u8,
    type_id: [*:0]const u8,
    fn initUndefined(gpa: std.mem.Allocator, comptime T: type) StateValue {
        const log2_align = comptime std.math.log2_int(u64, @alignOf(T));
        const result = gpa.vtable.alloc(gpa.ptr, @sizeOf(T), log2_align, @returnAddress()) orelse @panic("oom");
        return .{
            .data = result[0..@sizeOf(T)],
            .log2_align = log2_align,
            .type_id = @typeName(T),
        };
    }
    fn cast(self: StateValue, comptime T: type) *T {
        std.debug.assert(self.type_id == @typeName(T));
        std.debug.assert(self.data.len == @sizeOf(T));
        std.debug.assert(self.log2_align == comptime std.math.log2_int(u64, @alignOf(T)));
        return @ptrCast(@alignCast(self.data.ptr));
    }
    fn deinit(self: StateValue, gpa: std.mem.Allocator) void {
        gpa.vtable.free(gpa.ptr, self.data, self.log2_align, @returnAddress());
    }
};
const Beui2Persistent = struct {
    gpa: std.mem.Allocator,

    arenas: [2]std.heap.ArenaAllocator,
    current_arena: u1 = 0,

    id_scopes: std.array_list.Managed(IDSegment),
    draw_lists: std.array_list.Managed(*RepositionableDrawList),
    last_frame_mouse_events: std.array_list.Managed(MouseEventEntry),
    last_frame_mouse2_events: std.array_list.Managed(RepositionableDrawList.Mouse2),
    prev_frame_mouse_event_to_offset: IdMap(MouseEventInfo),
    prev_frame_draw_list_states: IdMap(GenericDrawListState),
    this_frame_ids: IdMap(void),
    click_target: ?ID = null,
    state2_storage: IdArrayMap(Beui2.StateInfo),
    image_cache: ImageCache.Cache,

    frame_num: u64 = 10,

    verdana_ttf: ?[]const u8,
    layout_cache: LayoutCache,

    beui1: *Beui,

    mouse_pos: ?@Vector(2, f32) = null,
    mouse_pos_on_drag_start: ?@Vector(2, f32) = null,
    mouse_focus: ?ID = null,
    uncommitted_move_offset: @Vector(2, f32) = .{ 0, 0 },
};
pub const Beui2 = struct {
    frame: Beui2Frame,
    persistent: Beui2Persistent,

    pub fn init(self: *Beui2, beui1: *Beui, gpa: std.mem.Allocator) void {
        const verdana_ttf: ?[]const u8 = for (&[_][]const u8{
            // cwd
            "Verdana.ttf",
            // linux
            "/usr/share/fonts/TTF/verdana.ttf",
            // mac
            "/System/Library/Fonts/Supplemental/Verdana.ttf",
            // windows
            "c:\\WINDOWS\\Fonts\\VERDANA.TTF",
        }) |search_path| {
            break std.fs.cwd().readFileAlloc(gpa, search_path, std.math.maxInt(usize)) catch continue;
        } else null;
        if (verdana_ttf == null) std.log.info("Verdana could not be found. Falling back to Noto Sans.", .{});
        const font = LayoutCache.Font.init(verdana_ttf orelse Beui.font_experiment.NotoSansMono_wght) orelse @panic("no font");

        self.* = .{
            .frame = undefined,
            .persistent = .{
                .gpa = gpa,
                .arenas = .{ .init(gpa), .init(gpa) },
                .id_scopes = .init(gpa),
                .draw_lists = .init(gpa),
                .last_frame_mouse_events = .init(gpa),
                .last_frame_mouse2_events = .init(gpa),
                .prev_frame_mouse_event_to_offset = .init(gpa),
                .prev_frame_draw_list_states = .init(gpa),
                .this_frame_ids = .init(gpa),
                .state2_storage = .init(gpa),
                .image_cache = .init(gpa),

                .verdana_ttf = verdana_ttf,
                .layout_cache = .init(gpa, font),

                .beui1 = beui1,
            },
        };
    }
    pub fn deinit(self: *Beui2) void {
        {
            // loop in reverse so we don't invalidate a pointer early
            const a = self.persistent.state2_storage.values();
            var i = a.len;
            while (i > 0) {
                i -= 1;
                a[i].deinit(self); // only gpa is used so it's ok to pass self in here
            }
        }
        self.persistent.image_cache.deinit();
        self.persistent.state2_storage.deinit();
        self.persistent.prev_frame_draw_list_states.deinit();
        self.persistent.layout_cache.deinit();
        if (self.persistent.verdana_ttf) |v| self.persistent.gpa.free(v);
        self.persistent.this_frame_ids.deinit();
        self.persistent.prev_frame_mouse_event_to_offset.deinit();
        self.persistent.last_frame_mouse2_events.deinit();
        self.persistent.last_frame_mouse_events.deinit();
        for (&self.persistent.arenas) |*a| a.deinit();
        self.persistent.id_scopes.deinit();
        self.persistent.draw_lists.deinit();
    }

    // TODO: add fns for handling events here:
    // ie onMouseClick()
    // it will look through last_frame_mouse2_events

    pub fn onMouseMove(self: *Beui2, new_pos: ?@Vector(2, f32)) void {
        const prev_pos = self.persistent.mouse_pos;
        self.persistent.mouse_pos = new_pos;
        if (prev_pos != null and new_pos != null) {
            self.persistent.uncommitted_move_offset += new_pos.? - prev_pos.?;
        } else {
            self.persistent.uncommitted_move_offset = .{ 0, 0 };
        }
    }
    pub fn onMouseEvent(self: *Beui2, btn: MouseButton, ev: enum { down, up }) void {
        commitMouseMoveEvents(self);
        switch (ev) {
            .down => {
                const mpos = self.persistent.mouse_pos orelse return;
                self.persistent.mouse_pos_on_drag_start = mpos;
                // find who captures this event
                for (self.persistent.last_frame_mouse2_events.items) |item| {
                    if (!item.cfg.buttons.matches(btn)) continue;
                    if (pointInRect(mpos, item.pos, item.size)) {
                        if (item.cfg.onMouseEvent) |onMouseEventFn| {
                            if (onMouseEventFn.call(self, .{
                                .button = btn,
                                .capture_pos = item.pos,
                                .capture_size = item.size,
                                .pos = mpos,
                                .action = .down,
                                .drag_start_pos = self.persistent.mouse_pos_on_drag_start.?,
                            })) |cursor| {
                                self.persistent.beui1.frame.cursor = cursor;
                                // it ate the event, so we set it as the mouse focus
                                self.persistent.mouse_focus = item.id;
                                break;
                            }
                        }
                    }
                }
            },
            .up => {
                // we give the event to the mouse focus
                const mfid = self.persistent.mouse_focus orelse return;
                for (self.persistent.last_frame_mouse2_events.items) |item| {
                    if (!item.cfg.buttons.matches(btn)) continue;
                    if (item.id.eql(mfid)) {
                        if (item.cfg.onMouseEvent) |onMouseEventFn| {
                            self.persistent.beui1.frame.cursor = onMouseEventFn.call(self, .{
                                .button = btn,
                                .capture_pos = item.pos,
                                .capture_size = item.size,
                                .pos = self.persistent.mouse_pos,
                                .action = .up,
                                .drag_start_pos = self.persistent.mouse_pos_on_drag_start.?,
                            }).?;
                        }
                    }
                }
                self.persistent.mouse_focus = null;
            },
        }
    }
    fn commitMouseMoveEvents(self: *Beui2) void {
        defer self.persistent.uncommitted_move_offset = .{ 0, 0 };
        // if (@reduce(.And, self.persistent.uncommitted_move_offset == @Vector(2, f32){ 0, 0 })) return;
        const mpos = self.persistent.mouse_pos orelse return;
        if (self.persistent.mouse_focus) |mfid| {
            // if there is a mouse focus:
            for (self.persistent.last_frame_mouse2_events.items) |item| {
                if (item.id.eql(mfid)) {
                    if (item.cfg.onMouseEvent) |onMouseEventFn| {
                        self.persistent.beui1.frame.cursor = onMouseEventFn.call(self, .{
                            .button = null,
                            .capture_pos = item.pos,
                            .capture_size = item.size,
                            .pos = mpos,
                            .action = .move_while_down,
                            .drag_start_pos = self.persistent.mouse_pos_on_drag_start.?,
                        }).?;
                    }
                }
            }
        } else {
            // else, give it to whoever can see it:
            // TODO: any item which recieved a move_while_up event last frame but did not this frame should
            // get a move_while_up event with mpos=null
            // TODO: the cursor needs to be preserved even if the mouse didn't move
            for (self.persistent.last_frame_mouse2_events.items) |item| {
                if (pointInRect(mpos, item.pos, item.size)) {
                    if (item.cfg.onMouseEvent) |onMouseEventFn| {
                        if (onMouseEventFn.call(self, .{
                            .button = null,
                            .capture_pos = item.pos,
                            .capture_size = item.size,
                            .pos = mpos,
                            .action = .move_while_up,
                            .drag_start_pos = mpos,
                        })) |cursor| {
                            self.persistent.beui1.frame.cursor = cursor;
                            break;
                        }
                    }
                }
            }
        }
    }

    pub fn newFrame(self: *Beui2, frame_cfg: Beui2FrameCfg) ID {
        const beui = self.persistent.beui1;
        self.persistent.image_cache.notifyFrameStart();
        self.persistent.layout_cache.tick(self);
        self.commitMouseMoveEvents();
        self.persistent.last_frame_mouse2_events.clearRetainingCapacity();
        if (self.persistent.mouse_focus) |*mf| mf.* = mf.refresh();
        // handle events
        // - scroll: if there is a scroll event, hit test to find which handler it touched
        const mousepos_int: @Vector(2, f32) = beui.persistent.mouse_pos;
        var scroll_target: ?ScrollTarget = null;
        if (@reduce(.Or, @abs(beui.frame.scroll_px) > @as(@Vector(2, f32), @splat(0.0)))) {
            for (self.persistent.last_frame_mouse_events.items) |item| {
                if (item.cfg.capture_scroll.x or item.cfg.capture_scroll.y) {
                    if (item.coversPoint(mousepos_int)) {
                        // found. its id is still valid for one more frame.
                        scroll_target = .{ .id = item.id, .scroll = beui.frame.scroll_px };
                        break;
                    }
                }
            }
        }
        // - mouse: store offsets
        self.persistent.prev_frame_mouse_event_to_offset.clearRetainingCapacity();
        for (self.persistent.last_frame_mouse_events.items) |item| {
            if (item.cfg.capture_click != null or item.cfg.observe_mouse_down) {
                self.persistent.prev_frame_mouse_event_to_offset.putNoClobber(item.id, .{ .offset = item.pos }) catch @panic("oom");
            }
        }
        // - mouse: set cursor
        if (self.persistent.click_target == null) {
            for (self.persistent.last_frame_mouse_events.items) |item| {
                if (item.cfg.capture_click) |cursor| {
                    if (item.coversPoint(mousepos_int)) {
                        beui.frame.cursor = cursor;
                        break;
                    }
                }
            }
        } else {
            for (self.persistent.last_frame_mouse_events.items) |item| {
                if (item.id.eql(self.persistent.click_target.?)) {
                    beui.frame.cursor = item.cfg.capture_click.?;
                    break;
                }
            }
        }
        // - mouse: store focus
        if (beui.isKeyPressed(.mouse_left)) {
            self.persistent.click_target = null;
            // find click target
            for (self.persistent.last_frame_mouse_events.items) |item| {
                if (item.cfg.observe_mouse_down) {
                    if (item.coversPoint(mousepos_int)) {
                        const info = self.persistent.prev_frame_mouse_event_to_offset.getPtr(item.id).?;
                        info.observed_mouse_down = true;
                    }
                }
                if (item.cfg.capture_click != null) {
                    if (item.coversPoint(mousepos_int)) {
                        // found.
                        self.persistent.click_target = item.id;
                        break;
                    }
                }
            }
        } else if (beui.isKeyHeld(.mouse_left)) {
            // refresh click target to keep its id valid
            if (self.persistent.click_target) |*target| {
                target.* = target.refresh();
            }
        } else {
            // remove click target, not clicking.
            self.persistent.click_target = null;
        }

        // state2: refresh ids & delete unused
        // (we shouldn't have to refresh ids; we can make them OwnedIDs and skip that mess)
        {
            const a = self.persistent.state2_storage.keys();
            const b = self.persistent.state2_storage.values();
            var i = a.len;
            while (i > 0) {
                i -= 1;
                a[i] = a[i].refresh();
                if (b[i].referenced_frame != self.persistent.frame_num) {
                    std.log.info("discarding state", .{});
                    // looping in reverse so this is ok
                    b[i].deinit(self);
                    self.persistent.state2_storage.orderedRemoveAt(i);
                }
            }
        }

        for (self.persistent.draw_lists.items) |pdl| if (!pdl.placed) @panic("not all draw lists were placed last frame.");
        self.persistent.draw_lists.clearRetainingCapacity();
        if (self.persistent.id_scopes.items.len != 0) @panic("not all scopes were popped last frame. maybe missing popScope()?");
        self.persistent.last_frame_mouse_events.clearRetainingCapacity();

        self.persistent.this_frame_ids.clearRetainingCapacity();
        self.persistent.current_arena +%= 1;
        const next_arena = &self.persistent.arenas[self.persistent.current_arena];
        _ = next_arena.reset(.retain_capacity);
        self.persistent.frame_num += 1;
        self.frame = .{
            .arena = next_arena.allocator(),
            .frame_cfg = frame_cfg,
            .scroll_target = scroll_target,
            .overlay_rdl = undefined,
        };
        self.frame.overlay_rdl = self.draw();

        const res_id: ID = .{
            .b2 = self,
            .frame = self.persistent.frame_num,
            .str = &.{},
        };

        return res_id;
    }
    pub fn endFrame(self: *Beui2, rdl: *RepositionableDrawList, renderlist: ?*render_list.RenderList) void {
        self.frame.overlay_rdl.place(rdl, .{});
        self.persistent.prev_frame_draw_list_states.clearRetainingCapacity();
        self.frame.overlay_rdl.finalize(.{
            .out_list = renderlist,
            .out_events = &self.persistent.last_frame_mouse_events,
            .out_mouse_events = &self.persistent.last_frame_mouse2_events,
            .out_rdl_states = &self.persistent.prev_frame_draw_list_states,
        }, .{}, .{ .ul = .{ 0, 0 }, .br = self.frame.frame_cfg.size });
    }

    pub fn draw(self: *Beui2) *RepositionableDrawList {
        const res = self.frame.arena.create(RepositionableDrawList) catch @panic("oom");
        res.* = .{ .b2 = self, .content = .init(self.frame.arena) }; // not the best to use an arena for an arraylist
        self.persistent.draw_lists.append(res) catch @panic("oom");
        return res;
    }

    pub fn dupeOne(self: *Beui2, value: anytype) *@TypeOf(value) {
        const res = self.frame.arena.create(@TypeOf(value)) catch @panic("oom");
        res.* = value;
        return res;
    }

    pub fn mouseCaptureResults(self: *Beui2, capture_id: ID) MouseCaptureResults {
        var mouse_left_held = false;
        if (self.persistent.click_target) |ct| {
            if (ct.eql(capture_id)) {
                mouse_left_held = true;
            }
        }
        var mouse_pos: @Vector(2, f32) = .{ 0, 0 };
        var observed_mouse_down: bool = false;
        if (self.persistent.prev_frame_mouse_event_to_offset.getPtr(capture_id)) |mof| {
            const b1pos: @Vector(2, f32) = self.persistent.beui1.persistent.mouse_pos;
            mouse_pos = b1pos - mof.offset;
            observed_mouse_down = mof.observed_mouse_down;
        }
        return .{
            .mouse_left_pressed_down_this_frame = if (mouse_left_held) self.persistent.beui1.isKeyPressed(.mouse_left) else false,
            .mouse_left_held = mouse_left_held,
            .mouse_pos = mouse_pos,
            .observed_mouse_down = observed_mouse_down,
        };
    }
    pub fn scrollCaptureResults(self: *Beui2, capture_id: ID) @Vector(2, f32) {
        if (self.frame.scroll_target) |st| {
            if (st.id.eql(capture_id)) {
                return st.scroll;
            }
        }
        return .{ 0, 0 };
    }
    /// - to preserve state while not rendering a child, eg in a details element, call
    ///   beui2.preserveStateTree(root_id). must preserve identifiers! use a PersistedID
    ///   rather than a regular ID within state, otherwise if your component gets hidden for
    ///   a few frames, when it returns all its IDs will be invalid.
    /// - your state's context pointer must stay the same for the whole time the state is alive.
    /// - if you invalidate your state's context pointer, you must stop posting the state immediately
    ///   so it can be deleted.
    /// (how do we make sure state destroy()s get called in the right order so if one feeds into another
    ///  the outer ctx isn't destroyed before the inner ctx? maybe just go in reverse order and that is enough?)
    pub fn state2(self: *Beui2, self_id: ID, init_ctx: anytype, comptime StateType: type) *StateType {
        const helper = struct {
            fn destroy(value: *anyopaque, b2: *Beui2) void {
                const state_val: *StateType = @ptrCast(@alignCast(value));
                state_val.deinit();
                b2.persistent.gpa.destroy(state_val);
            }
            const fns: StateVtable = .{
                .destroy = &destroy,
            };
        };

        const gpres = self.persistent.state2_storage.getOrPut(self_id) catch @panic("oom");
        if (!gpres.found_existing) {
            const state_val = self.persistent.gpa.create(StateType) catch @panic("oom");
            state_val.init(init_ctx);
            gpres.value_ptr.* = .{
                .vtable = &helper.fns,
                .state = @ptrCast(@alignCast(state_val)),
                .referenced_frame = undefined,
            };
        }
        gpres.value_ptr.referenced_frame = self.persistent.frame_num;

        return @ptrCast(@alignCast(gpres.value_ptr.state));
    }
    const StateInfo = struct {
        vtable: *const StateVtable,
        state: *anyopaque,
        referenced_frame: u64,

        fn deinit(self: *StateInfo, b2: *Beui2) void {
            self.vtable.destroy(self.state, b2);
            self.state = undefined;
        }
    };
    const StateVtable = struct {
        destroy: *const fn (value: *anyopaque, b2: *Beui2) void,
    };
    fn StateResult(comptime StateType: type) type {
        return struct { initialized: bool, value: *StateType };
    }

    pub fn getPrevFrameDrawListState(self: *Beui2, state_id: ID) ?*const GenericDrawListState {
        if (self.persistent.prev_frame_draw_list_states.getPtr(state_id)) |prev_frame_draw_list_state| {
            return prev_frame_draw_list_state;
        } else {
            return null;
        }
    }

    pub fn fmt(self: *Beui2, comptime format: []const u8, args: anytype) []u8 {
        return std.fmt.allocPrint(self.frame.arena, format, args) catch @panic("oom");
    }
};
const GenericDrawListState = struct {
    offset_from_screen_ul: @Vector(2, f32),
    state: *const anyopaque,
    type_id: [*:0]const u8,

    pub fn cast(self: GenericDrawListState, comptime T: type) *const T {
        std.debug.assert(@typeName(T) == self.type_id);
        return @ptrCast(@alignCast(self.state));
    }
};

pub const MouseCaptureResults = struct {
    mouse_left_pressed_down_this_frame: bool,
    mouse_left_held: bool,
    mouse_pos: @Vector(2, f32),
    observed_mouse_down: bool,
};

const IDSegment = struct {
    const IDSegmentSize = 8 * 3;
    comptime {
        std.debug.assert(std.meta.hasUniqueRepresentation(IDSegment));
    }
    value: [IDSegmentSize]u8,
    tag: Tag,
    const Tag = enum { src, loop, loop_child, unique, str };
    const SrcStruct = struct {
        filename: [*:0]const u8,
        fn_name: [*:0]const u8,
        line: u32,
        col: u32,
    };
    const LoopStruct = struct {
        child_t: [*:0]const u8,
    };

    pub fn fromSrc(src: std.builtin.SourceLocation) IDSegment {
        return .fromTagValue(.src, SrcStruct, .{ .filename = src.file.ptr, .fn_name = src.fn_name.ptr, .line = src.line, .col = src.column });
    }
    pub fn fromStr(str: []const u8) IDSegment {
        return .fromTagSlice(.str, str);
    }
    fn fromTagValue(tag: Tag, comptime VT: type, value: VT) IDSegment {
        comptime std.debug.assert(@sizeOf(VT) <= IDSegmentSize);
        comptime std.debug.assert(std.meta.hasUniqueRepresentation(VT));
        return .fromTagSlice(tag, std.mem.asBytes(&value));
    }
    fn fromTagSlice(tag: Tag, value_slice: []const u8) IDSegment {
        std.debug.assert(value_slice.len <= IDSegmentSize);
        var result = std.mem.zeroes([IDSegmentSize]u8);
        @memcpy(result[0..value_slice.len], value_slice);
        return .{ .value = result, .tag = tag };
    }
    pub fn readAsType(self: *const IDSegment, comptime VT: type) *align(1) const VT {
        comptime std.debug.assert(@sizeOf(VT) <= IDSegmentSize);
        comptime std.debug.assert(std.meta.hasUniqueRepresentation(VT));
        return std.mem.bytesAsValue(VT, self.value[0..@sizeOf(VT)]);
    }

    fn eql(self: IDSegment, other: IDSegment) bool {
        return std.mem.eql(u8, std.mem.asBytes(&self), std.mem.asBytes(&other));
    }
};
const IDSegmentNode = struct {
    segment: IDSegment,
    parent: ?*const IDSegmentNode,

    // eventually we can have an id tree in b2
    // and that way comparing ids is as simple as id_1 == id_2 because the pointers will
    // be the same if the ids are the same.
    //
    // pushing an id for the first time costs a memorypool allocation.
    // subsequent times, it finds the same one as last time.
    // id storage longer than two frames requires ref()ing the id or something
};
pub const ID = struct {
    var unique_id_idx: u64 = 0;
    b2: *Beui2,
    frame: u64,
    /// DO NOT READ POINTER WITHOUT CALLING .assertValid() FIRST.
    str: []const IDSegment,

    const duplicate_id_safety = std.debug.runtime_safety;

    pub fn format(value: ID, writer: *std.Io.Writer) !void {
        // const seen_srcs_for_fmt = struct {
        //     var seen_srcs_for_fmt = std.StringArrayHashMapUnmanaged(usize);
        // };

        value.assertValid();
        try writer.print("%", .{});
        for (value.str) |seg| {
            if (seg.tag == .str) {
                try writer.print(".\"{f}\"", .{std.zig.fmtString(std.mem.trimRight(u8, &seg.value, &.{0}))});
            } else if (seg.tag == .src) {
                const dec: IDSegment.SrcStruct = std.mem.bytesAsValue(IDSegment.SrcStruct, seg.value[0..@sizeOf(IDSegment.SrcStruct)]).*;
                try writer.print(".\"{f}\"@{d}:{d}", .{ std.zig.fmtString(std.mem.span(dec.filename)), dec.line, dec.col });
            } else {
                try writer.print(".{s}", .{@tagName(seg.tag)});
            }
        }
        // var hres: [16]u8 = undefined;
        // const hstr = std.fmt.bufPrint(&hres, "{X:0>16}", .{value.hash()}) catch unreachable;
        // std.debug.assert(hstr.len == hres.len);
        // try writer.print("{s}", .{hres[0..4]});
    }

    pub fn assertValid(self: ID) void {
        std.debug.assert(self.frame == 0 or self.frame == self.b2.persistent.frame_num or self.frame + 1 == self.b2.persistent.frame_num);
    }
    pub fn hash(self: ID) u64 {
        self.assertValid();
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.sliceAsBytes(self.str));
        return hasher.final();
    }
    pub fn eql(self: ID, other: ID) bool {
        self.assertValid();
        other.assertValid();
        if (self.str.len != other.str.len) return false;
        if (self.str.ptr == other.str.ptr) return true;
        if (!std.mem.eql(u8, std.mem.sliceAsBytes(self.str), std.mem.sliceAsBytes(other.str))) return false;
        return true;
    }
    pub fn refresh(self: ID) ID {
        self.assertValid();
        std.debug.assert(self.frame != 0);
        const self_cp = self.b2.frame.arena.dupe(IDSegment, self.str) catch @panic("oom");
        return .{ .b2 = self.b2, .frame = self.b2.persistent.frame_num, .str = self_cp };
    }

    pub fn dupeToOwned(self: ID, gpa: std.mem.Allocator) ID {
        const self_cp = gpa.dupe(IDSegment, self.str) catch @panic("oom");
        return .{ .b2 = self.b2, .frame = 0, .str = self_cp };
    }
    pub fn deinitOwned(self: *ID, gpa: std.mem.Allocator) void {
        std.debug.assert(self.frame == 0);
        gpa.free(self.str);
        self.frame = 1;
    }

    fn _addInternal(self: ID, items: []const IDSegment) ID {
        const tctx = tracy.trace(@src());
        defer tctx.end();

        self.assertValid();
        const self_cp = self.b2.frame.arena.alloc(IDSegment, self.str.len + items.len) catch @panic("oom");
        @memcpy(self_cp[0..self.str.len], self.str);
        @memcpy(self_cp[self.str.len..], items);
        const result: ID = .{ .b2 = self.b2, .frame = self.b2.persistent.frame_num, .str = self_cp };
        if (duplicate_id_safety) {
            self.b2.persistent.this_frame_ids.putNoClobber(result, {}) catch @panic("oom"); // if this fails then there is a duplicate id
        }
        return result;
    }

    pub fn unique(b2: *Beui2) ID {
        unique_id_idx += 1;
        const res = b2.frame.arena.alloc(IDSegment, 1) catch @panic("oom");
        res[0] = .fromTagValue(.unique, u64, unique_id_idx);
        // no need for duplicate safety; it's guaranteed not to be a duplicate
        return .{ .b2 = b2, .frame = b2.persistent.frame_num, .str = res };
    }
    pub fn LoopValue(comptime Child: type) type {
        comptime {
            if (@sizeOf(Child) > IDSegment.IDSegmentSize) @compileError("loop Child size > max size");
            if (!std.meta.hasUniqueRepresentation(Child)) @compileError("loop Child must have unique representation");
        }
        return struct {
            _id: ID,
            pub fn value(self: @This(), src: std.builtin.SourceLocation, child_t: Child) ID {
                return self._id.pushLoopValue(src, child_t);
            }
            pub fn valueNoSrc(self: @This(), child_t: Child) ID {
                return self._id.pushLoopValueNoSrc(child_t);
            }
        };
    }
    pub fn pushLoop(self: ID, src: std.builtin.SourceLocation, comptime Child: type) LoopValue(Child) {
        return .{ ._id = self._pushLoopTypeName(src, @typeName(Child)) };
    }
    fn _pushLoopTypeName(self: ID, src: std.builtin.SourceLocation, child_t: [*:0]const u8) ID {
        return self._addInternal(&.{ .fromSrc(src), .fromTagValue(.loop, IDSegment.LoopStruct, .{ .child_t = child_t }) });
    }
    fn pushLoopValue(self: ID, src: std.builtin.SourceLocation, child_t: anytype) ID {
        return self._addInternal(&.{ .fromSrc(src), self._loopValue(@typeName(@TypeOf(child_t)), std.mem.asBytes(&child_t)) });
    }
    fn pushLoopValueNoSrc(self: ID, child_t: anytype) ID {
        return self._addInternal(&.{self._loopValue(@typeName(@TypeOf(child_t)), std.mem.asBytes(&child_t))});
    }
    fn _loopValue(self: ID, child_t: [*:0]const u8, child_v: []const u8) IDSegment {
        self.assertValid();
        if (self.str.len == 0) @panic("pushLoopValue called without pushLoop");
        const last = self.str[self.str.len - 1];
        if (last.tag != .loop) @panic("pushLoopValue called but last push was not pushLoop");
        const last_loop = last.readAsType(IDSegment.LoopStruct);
        if (last_loop.child_t != child_t) @panic("pushLoopValue called with different type than from pushLoop");
        std.debug.assert(child_v.len <= IDSegment.IDSegmentSize);
        return .fromTagSlice(.loop_child, child_v);
    }

    pub fn sub(self: ID, src: std.builtin.SourceLocation) ID {
        return self._addInternal(&.{.fromSrc(src)});
    }
    pub fn subStr(self: ID, str: []const u8) ID {
        return self._addInternal(&.{.fromStr(str)});
    }
};

const MouseEventEntry = struct {
    id: ID,
    pos: @Vector(2, f32),
    size: @Vector(2, f32),
    cfg: MouseEventCaptureConfig,

    pub fn coversPoint(self: MouseEventEntry, point: @Vector(2, f32)) bool {
        return pointInRect(point, self.pos, self.size);
    }
};
pub fn pointInRect(point: ?@Vector(2, f32), rect_pos: @Vector(2, f32), rect_size: @Vector(2, f32)) bool {
    if (point == null) return false;
    return @reduce(.And, point.? >= rect_pos) and @reduce(.And, point.? < rect_pos + rect_size);
}
const MouseEventCaptureConfig = struct {
    /// if there was a click within the area of this, report it but keep processing the event until it is captured
    observe_mouse_down: bool = false,
    capture_click: ?Beui.Cursor = null,
    capture_scroll: struct { x: bool = false, y: bool = false } = .{},
};
pub const Direction = enum {
    left,
    top,
    right,
    bottom,
    pub fn toAxis(self: Direction) Axis {
        return switch (self) {
            .left, .right => .x,
            .top, .bottom => .y,
        };
    }
    pub fn idx(self: Direction) u1 {
        return switch (self) {
            .left, .top => 0,
            .right, .bottom => 1,
        };
    }
};
pub const Axis = enum {
    x,
    y,
    pub fn flip(a: Axis, b: anytype) @TypeOf(b) {
        return switch (a) {
            .x => .{ b[0], b[1] },
            .y => .{ b[1], b[0] },
        };
    }
};
pub const LR = enum {
    left,
    right,
    pub fn idx(self: LR) u1 {
        return @intFromBool(self == .right);
    }
};
pub const Corners = packed struct(u4) {
    top_left: bool = false,
    top_right: bool = false,
    bottom_left: bool = false,
    bottom_right: bool = false,
    pub const top: Corners = .{ .top_left = true, .top_right = true };
    pub const left: Corners = .{ .top_left = true, .bottom_left = true };
    pub const bottom: Corners = .{ .bottom_left = true, .bottom_right = true };
    pub const right: Corners = .{ .top_right = true, .bottom_right = true };
    pub const all: Corners = .{ .top_left = true, .top_right = true, .bottom_left = true, .bottom_right = true };
};
pub const Sides = packed struct(u4) {
    _top: bool = false,
    _left: bool = false,
    _bottom: bool = false,
    _right: bool = false,
    pub const top: Sides = .{ ._top = true };
    pub const top_right: Sides = .{ ._top = true, ._right = true };
    pub const right: Sides = .{ ._right = true };
    pub const bottom_right: Sides = .{ ._bottom = true, ._right = true };
    pub const bottom: Sides = .{ ._bottom = true };
    pub const bottom_left: Sides = .{ ._bottom = true, ._left = true };
    pub const left: Sides = .{ ._left = true };
    pub const left_right: Sides = .{ ._left = true, ._right = true };
    pub const top_left: Sides = .{ ._top = true, ._left = true };
    pub const all: Sides = .{ ._top = true, ._left = true, ._bottom = true, ._right = true };
    pub const top_bottom: Sides = .{ ._top = true, ._left = false, ._bottom = true, ._right = false };
    pub const top_bottom_right: Sides = .{ ._top = true, ._left = false, ._bottom = true, ._right = true };
    pub const top_bottom_left: Sides = .{ ._top = true, ._left = true, ._bottom = true, ._right = false };
    pub const none: Sides = .{ ._top = false, ._left = false, ._bottom = false, ._right = false };
    fn andTop(a: Sides) Sides {
        return .{ ._top = true, .left = a._left, ._bottom = a._bottom, .right = a._right };
    }
    fn andLeft(a: Sides) Sides {
        return .{ ._top = a._top, .left = true, ._bottom = a._bottom, .right = a._right };
    }
    fn andBottom(a: Sides) Sides {
        return .{ ._top = a._top, .left = a._left, ._bottom = true, .right = a._right };
    }
    fn andRight(a: Sides) Sides {
        return .{ ._top = a._top, .left = a._left, ._bottom = a._bottom, .right = true };
    }
};
pub const MouseButton = enum(u4) { left, middle, right, _ };
pub const RepositionableDrawList = struct {
    pub const Reservation = struct {
        index: usize,
        frame: u64,
        for_draw_list: *RepositionableDrawList,
    };
    const Mouse2 = struct {
        pos: @Vector(2, f32),
        size: @Vector(2, f32),
        id: ID,
        cfg: MouseEventCapture2Config,
    };
    const RepositionableDrawChild = union(enum) {
        geometry: struct {
            vertices: []const render_list.RenderListVertex,
            indices: []const render_list.RenderListIndex,
            image: ?render_list.RenderListImage,
        },
        mouse: struct {
            pos: @Vector(2, f32),
            size: @Vector(2, f32),
            id: ID,
            cfg: MouseEventCaptureConfig,
        },
        mouse2: Mouse2,
        embed: struct {
            child: ?*RepositionableDrawList,
            cfg: PlaceCfg,
        },
        clip: struct {
            child: *RepositionableDrawList,
            rect: ClipCfg,
            // for fancy clips in the future, we could implement clips by defining
            // a 'geometry' command that writes to a clip buffer and then all renders
            // go through that buffer. not sure how to have a clipping stack though.
        },
        user_state: struct {
            id: ID,
            data: *const anyopaque,
            type_id: [*:0]const u8,
            // calling getState(id) returns your state pointer along with the offset of the item on the previous frame
        },
    };
    b2: *Beui2,
    content: std.array_list.Managed(RepositionableDrawChild),
    placed: bool = false,
    pub const PlaceCfg = struct {
        offset: @Vector(2, f32) = .{ 0, 0 },
        // ie: disable_mouse_events to disable mouse events for the whole tree
        // ie: transformation matrix to apply to the rendered image but not event handlers for nice animations
        pub fn add(a: PlaceCfg, b: PlaceCfg) PlaceCfg {
            return .{ .offset = a.offset + b.offset };
        }
    };
    pub const ClipCfg = struct {
        ul: @Vector(2, f32),
        br: @Vector(2, f32),
        pub fn sub(a: ClipCfg, add: @Vector(2, f32), b: ClipCfg) ClipCfg {
            return .{ .ul = @max(a.ul, add + b.ul), .br = @min(a.br, add + b.br) };
        }
    };
    pub fn place(self: *RepositionableDrawList, child: *RepositionableDrawList, cfg: PlaceCfg) void {
        std.debug.assert(!child.placed);
        self.content.append(.{ .embed = .{ .child = child, .cfg = cfg } }) catch @panic("oom");
    }
    pub fn reserve(self: *RepositionableDrawList) Reservation {
        self.content.append(.{ .embed = .{ .child = null, .cfg = .{} } }) catch @panic("oom");
        return .{ .frame = self.b2.persistent.frame_num, .index = self.content.items.len - 1, .for_draw_list = self };
    }
    pub fn fill(self: *RepositionableDrawList, slot: Reservation, child: *RepositionableDrawList, cfg: PlaceCfg) void {
        std.debug.assert(self.b2.persistent.frame_num == slot.frame);
        std.debug.assert(self == slot.for_draw_list);
        self.content.items[slot.index].embed = .{ .child = child, .cfg = cfg };
    }
    pub fn addUserState(self: *RepositionableDrawList, id: ID, comptime StateT: type, state: *const StateT) void {
        self.content.append(.{ .user_state = .{
            .id = id,
            .data = @ptrCast(state),
            .type_id = @typeName(StateT),
        } }) catch @panic("oom");
    }
    pub fn addClip(self: *RepositionableDrawList, child: *RepositionableDrawList, rect: struct { pos: @Vector(2, f32), size: @Vector(2, f32) }) void {
        self.content.append(.{ .clip = .{ .child = child, .rect = .{ .ul = rect.pos, .br = rect.pos + rect.size } } }) catch @panic("oom");
    }
    //  if (image) |img| {
    //     const image_uv = self.b2.persistent.image_cache.getImageUVOnRenderFromRdl(img);
    //     for (vertices_dupe) |*vertex| {
    //         vertex.uv = vertex.uv / image_uv.size + image_uv.pos;
    //     }
    // }
    pub fn addVertices(self: *RepositionableDrawList, image: ?render_list.RenderListImage, vertices: []const render_list.RenderListVertex, indices: []const render_list.RenderListIndex) void {
        const vertices_dupe = self.b2.frame.arena.dupe(render_list.RenderListVertex, vertices) catch @panic("oom");

        self.content.append(.{
            .geometry = .{
                .vertices = vertices_dupe,
                .indices = self.b2.frame.arena.dupe(render_list.RenderListIndex, indices) catch @panic("oom"),
                .image = image,
            },
        }) catch @panic("oom");
    }
    pub fn addRegion(self: *RepositionableDrawList, opts: struct {
        pos: @Vector(2, f32),
        size: @Vector(2, f32),
        region: @import("Texpack.zig").Region,
        image: ?render_list.RenderListImage,
        image_size: u32,
        tint: Beui.Color = .fromHexRgb(0xFFFFFF),
    }) void {
        const uv = opts.region.calculateUV(opts.image_size);
        return self.addRect(.{
            .pos = opts.pos,
            .size = opts.size,
            .uv_pos = .{ uv.pos[0], uv.pos[1] },
            .uv_size = .{ uv.size[0], uv.size[1] },
            .image = opts.image,
            .tint = opts.tint,
        });
    }
    pub fn addRect(
        self: *RepositionableDrawList,
        opts_in: struct {
            pos: @Vector(2, f32),
            size: @Vector(2, f32),
            uv_pos: @Vector(2, f32) = .{ -1.0, -1.0 },
            uv_size: @Vector(2, f32) = .{ 0, 0 },
            image: ?render_list.RenderListImage = null,
            tint: Beui.Color = .fromHexRgb(0xFFFFFF),
            rounding: struct {
                corners: Corners = .{},
                style: enum {
                    none,
                    angle, // can be done using tris but we probably won't have smoothing. so maybe not tris.
                    round,
                } = .round,
                radius: f32,
            } = .{ .style = .none, .radius = 0 },
            circle: [4]@Vector(2, f32) = .{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } },
        },
    ) void {
        var opts = opts_in;
        if (opts.rounding.style == .round and opts.rounding.radius > 0.0 and (opts.rounding.corners.top_left or opts.rounding.corners.top_right or opts.rounding.corners.bottom_left or opts.rounding.corners.bottom_right)) {
            const maximum_round: f32 = @reduce(.Min, opts.size / @Vector(2, f32){ 2, 2 });
            const actual_round = @min(maximum_round, opts.rounding.radius);
            // TODO support UVs

            const round_none: [4]@Vector(2, f32) = .{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } };
            self.addRect(.{
                .pos = opts.pos,
                .size = .{ actual_round, actual_round },
                .circle = if (opts.rounding.corners.top_left) .{ .{ 1, 1 }, .{ 1, 0 }, .{ 0, 1 }, .{ 0, 0 } } else round_none,
                .tint = opts.tint,
            });
            self.addRect(.{
                .pos = opts.pos + @Vector(2, f32){ actual_round, 0 },
                .size = .{ opts.size[0] - actual_round * 2, actual_round },
                .tint = opts.tint,
            });
            self.addRect(.{
                .pos = opts.pos + @Vector(2, f32){ opts.size[0] - actual_round, 0 },
                .size = .{ actual_round, actual_round },
                .circle = if (opts.rounding.corners.top_right) .{ .{ 1, 0 }, .{ 1, 1 }, .{ 0, 0 }, .{ 0, 1 } } else round_none,
                .tint = opts.tint,
            });
            self.addRect(.{
                .pos = opts.pos + @Vector(2, f32){ 0, actual_round },
                .size = .{ opts.size[0], opts.size[1] - actual_round * 2 },
                .tint = opts.tint,
            });
            self.addRect(.{
                .pos = opts.pos + @Vector(2, f32){ 0, opts.size[1] - actual_round },
                .size = .{ actual_round, actual_round },
                .circle = if (opts.rounding.corners.bottom_left) .{ .{ 1, 0 }, .{ 0, 0 }, .{ 1, 1 }, .{ 0, 1 } } else round_none,
                .tint = opts.tint,
            });
            self.addRect(.{
                .pos = opts.pos + @Vector(2, f32){ actual_round, opts.size[1] - actual_round },
                .size = .{ opts.size[0] - actual_round * 2, actual_round },
                .tint = opts.tint,
            });
            self.addRect(.{
                .pos = opts.pos + @Vector(2, f32){ opts.size[0] - actual_round, opts.size[1] - actual_round },
                .size = .{ actual_round, actual_round },
                .circle = if (opts.rounding.corners.bottom_right) .{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 0 }, .{ 1, 1 } } else round_none,
                .tint = opts.tint,
            });
            return;
        }
        if (opts.image == null) {
            opts.uv_pos = .{ -1.0, -1.0 };
            opts.uv_size = .{ 0, 0 };
        }
        const pos = opts.pos;
        const size = opts.size;

        const ul = pos;
        const ur = pos + @Vector(2, f32){ size[0], 0 };
        const bl = pos + @Vector(2, f32){ 0, size[1] };
        const br = pos + size;

        const uv_ul = opts.uv_pos;
        const uv_ur = opts.uv_pos + @Vector(2, f32){ opts.uv_size[0], 0 };
        const uv_bl = opts.uv_pos + @Vector(2, f32){ 0, opts.uv_size[1] };
        const uv_br = opts.uv_pos + opts.uv_size;

        self.addVertices(opts.image, &.{
            .{ .pos = ul, .uv = uv_ul, .tint = opts.tint.value, .circle = opts.circle[0] },
            .{ .pos = ur, .uv = uv_ur, .tint = opts.tint.value, .circle = opts.circle[1] },
            .{ .pos = bl, .uv = uv_bl, .tint = opts.tint.value, .circle = opts.circle[2] },
            .{ .pos = br, .uv = uv_br, .tint = opts.tint.value, .circle = opts.circle[3] },
        }, &.{
            // have to go clockwise to not get culled
            0, 1, 3,
            0, 3, 2,
        });
    }
    pub fn addChar(self: *RepositionableDrawList, char: u8, pos: @Vector(2, f32), color: Beui.Color) void {
        const conv: @Vector(2, u4) = @bitCast(char);
        const tile_id: @Vector(2, f32) = .{ @floatFromInt(conv[0]), @floatFromInt(conv[1]) };
        const tile_pos: @Vector(2, f32) = tile_id * @Vector(2, f32){ 6, 10 } + @Vector(2, f32){ 1, 1 };
        const tile_size: @Vector(2, f32) = .{ 5, 9 };
        const font_size: @Vector(2, f32) = .{ 256, 256 };
        const tile_uv_pos = tile_pos / font_size;
        const tile_uv_size = tile_size / font_size;
        self.addRect(.{
            .pos = pos,
            .size = tile_size,
            .uv_pos = tile_uv_pos,
            .uv_size = tile_uv_size,
            .image = .beui_font,
            .tint = color,
        });
    }
    pub fn addMouseEventCapture(self: *RepositionableDrawList, id: ID, pos: @Vector(2, f32), size: @Vector(2, f32), cfg: MouseEventCaptureConfig) void {
        self.content.append(.{ .mouse = .{ .pos = pos, .size = size, .id = id, .cfg = cfg } }) catch @panic("oom");
    }
    pub const MouseEventCapture2Config = struct {
        // lifetimes:
        // - this is called between frames. so if something gets destroyed on frame 1,
        //   don't add a betweenframecallback for it.
        buttons: struct {
            _left: bool = false,
            _middle: bool = false,
            _right: bool = false,
            pub const left: @This() = .{ ._left = true };
            pub const middle: @This() = .{ ._middle = true };
            pub const right: @This() = .{ ._right = true };
            pub const all: @This() = .{ ._left = true, ._middle = true, ._right = true };
            fn matches(this: @This(), btn: MouseButton) bool {
                return switch (btn) {
                    .left => this._left,
                    .middle => this._middle,
                    .right => this._right,
                    else => false,
                };
            }
        },
        onMouseEvent: ?BetweenFrameCallback(*Beui2, MouseEvent, ?Beui.Cursor) = null,
        onScrollEvent: ?BetweenFrameCallback(*Beui2, ScrollEvent, bool) = null,
    };
    pub fn addMouseEventCapture2(self: *RepositionableDrawList, id: ID, pos: @Vector(2, f32), size: @Vector(2, f32), cfg: MouseEventCapture2Config) void {
        self.content.append(.{ .mouse2 = .{ .pos = pos, .size = size, .id = id, .cfg = cfg } }) catch @panic("oom");
    }

    const FinalizeCfg = struct {
        out_list: ?*render_list.RenderList,
        out_events: ?*std.array_list.Managed(MouseEventEntry),
        out_mouse_events: ?*std.array_list.Managed(Mouse2),
        out_rdl_states: ?*IdMap(GenericDrawListState),
    };
    fn finalize(self: *RepositionableDrawList, res: FinalizeCfg, cfg: PlaceCfg, clip: ClipCfg) void {
        std.debug.assert(!self.placed); // double place of rdl
        self.placed = true;
        for (self.content.items) |item| {
            switch (item) {
                .geometry => |geo| {
                    if (res.out_list) |v| v.addVertices(geo.image, geo.vertices, geo.indices, cfg.offset, clip);
                },
                .mouse => |mev| {
                    if (res.out_events) |v| v.append(.{
                        .id = mev.id,
                        .pos = mev.pos + cfg.offset,
                        .size = mev.size,
                        .cfg = mev.cfg,
                    }) catch @panic("oom");
                },
                .mouse2 => |mev| {
                    if (res.out_mouse_events) |v| v.append(.{
                        .id = mev.id,
                        .pos = mev.pos + cfg.offset,
                        .size = mev.size,
                        .cfg = mev.cfg,
                    }) catch @panic("oom");
                },
                .embed => |eev| {
                    if (eev.child) |c| c.finalize(res, cfg.add(eev.cfg), clip);
                },
                .user_state => |usv| {
                    if (res.out_rdl_states) |v| {
                        v.putNoClobber(usv.id, .{
                            .offset_from_screen_ul = cfg.offset,
                            .state = usv.data,
                            .type_id = usv.type_id,
                        }) catch @panic("oom");
                    }
                },
                .clip => |c| {
                    c.child.finalize(res, cfg, clip.sub(cfg.offset, c.rect));
                },
            }
        }
    }
};

// fn harfbuzzText(call_info: StandardCallInfo, text: []const u8, color: Beui.Color) StandardChild {
//     const ui = call_info.ui(@src());

//     const draw = ui.id.b2.draw();
// }

pub fn textOnly(
    call_info: StandardCallInfo,
    text_v: []const u8,
    color: Beui.Color,
) StandardChild {
    const ui = call_info.ui(@src());
    const b2 = ui.id.b2;

    const draw = b2.draw();

    var char_pos: @Vector(2, f32) = .{ 0, 0 };
    for (text_v) |char| {
        draw.addChar(char, char_pos, color);
        char_pos += .{ 6, 0 };
    }

    return .{
        .size = .{ char_pos[0], 10 },
        .rdl = draw,
    };
}

const TextLine = struct {
    text: []const u8,
};

pub fn textLine(call_info: StandardCallInfo, line: TextLine) StandardChild {
    const tctx = tracy.trace(@src());
    defer tctx.end();

    const ui = call_info.ui(@src());
    const b2 = ui.id.b2;
    const lc = &b2.persistent.layout_cache;

    const result = lc.renderLine(b2, .{ .text = line.text, .max_width = call_info.constraints.available_size.w });
    const resdraw = b2.draw();
    resdraw.addVertices(result.image, result.vertices, result.indices);

    return .{
        .size = .{ result.single_line_width, result.height },
        .rdl = resdraw,
    };
}

const ListIndex = struct {
    comptime {
        std.debug.assert(std.meta.hasUniqueRepresentation(ListIndex));
    }
    i: usize,
    pub fn first(_: usize) ListIndex {
        return .{ .i = 0 };
    }
    pub fn update(itm: ListIndex, len: usize) ?ListIndex {
        if (itm.i >= len) return if (len == 0) null else .{ .i = len - 1 };
        return .{ .i = itm.i };
    }
    pub fn prev(itm: ListIndex, _: usize) ?ListIndex {
        if (itm.i == 0) return null;
        return .{ .i = itm.i - 1 };
    }
    pub fn next(itm: ListIndex, len: usize) ?ListIndex {
        if (itm.i == len - 1) return null;
        return .{ .i = itm.i + 1 };
    }
};

const ContextMenuConstraints = struct {
    screen_size: @Vector(2, f32),
    click_pos: @Vector(2, f32),
};
const StandardConstraints = struct {

    // so for each axis, we have:
    // target width, max available width
    // if target width is 0, that means to use intrinsic width

    // rendering a button:
    // - the child will be measured given the same constraints, minus any
    //   padding for the target width
    // - then, if the child width is less than the target width, the button
    //   will expand to fill the target width and center the child
    // but will the child width ever be less than the target width? won't
    // every child try to fill its target space?

    // so the item will be as small as possible
    // if you want it bigger, you'll need to add some kind of expander
    // ie for a button:
    // Button( BG(.blue, HLayout( Text("hello", .white), 1fr ) ) )
    // HLayout in that case uses all available space because of the '1fr'

    available_size: struct { w: ?f32, h: ?f32 },
};
pub const StandardChild = struct {
    size: @Vector(2, f32),
    rdl: *RepositionableDrawList,
};

pub fn ConstrainedCallInfo(comptime Constraints: type) type {
    return struct {
        pub const CallInfo = struct {
            caller_id: ID,
            constraints: Constraints,
            pub fn ui(self: CallInfo, src: std.builtin.SourceLocation) UI {
                return .{ .id = self.caller_id.sub(src), .constraints = self.constraints };
            }
        };
        pub const UI = struct {
            id: ID,
            constraints: Constraints,
            pub fn sub(self: UI, src: std.builtin.SourceLocation) CallInfo {
                return .{ .caller_id = self.id.sub(src), .constraints = self.constraints };
            }
            pub fn subWithOffset(self: UI, src: std.builtin.SourceLocation, subtract_size: @Vector(2, f32)) StandardCallInfo {
                var res_constraints = self.constraints;
                if (res_constraints.available_size.w) |*w| w.* -= subtract_size[0];
                if (res_constraints.available_size.h) |*h| h.* -= subtract_size[1];
                return .{ .caller_id = self.id.sub(src), .constraints = res_constraints };
            }
        };
    };
}
pub const SizedCallInfo = ConstrainedCallInfo(@Vector(2, f32)).CallInfo;
pub const SizedUI = ConstrainedCallInfo(@Vector(2, f32)).UI;
pub const StandardCallInfo = ConstrainedCallInfo(StandardConstraints).CallInfo;
pub const StandardUI = ConstrainedCallInfo(StandardConstraints).UI;
pub const ContextMenuCallInfo = ConstrainedCallInfo(ContextMenuConstraints).CallInfo;
pub const ContextMenuUI = ConstrainedCallInfo(ContextMenuConstraints).UI;
pub const BetweenFrameCallback = Component;
pub fn Component(comptime Arg1: type, comptime Arg2: type, comptime Ret: type) type {
    // TODO: replace with anywhere.util.Callback
    return struct {
        ctx: *anyopaque,
        fn_ptr: *const fn (ctx: *anyopaque, arg1: Arg1, arg2: Arg2) Ret,
        pub fn from(ctx_0: anytype, comptime fn_val: fn (ctx: @TypeOf(ctx_0), arg1: Arg1, arg2: Arg2) Ret) @This() {
            return .{
                .ctx = @ptrCast(@constCast(ctx_0)),
                .fn_ptr = struct {
                    fn fn_ptr(ctx_1: *const anyopaque, arg1: Arg1, arg2: Arg2) Ret {
                        return fn_val(@ptrCast(@alignCast(@constCast(ctx_1))), arg1, arg2);
                    }
                }.fn_ptr,
            };
        }
        pub fn call(self: @This(), arg1: Arg1, arg2: Arg2) Ret {
            return self.fn_ptr(self.ctx, arg1, arg2);
        }
    };
}
fn defaultTextButton(call_info: StandardCallInfo, msg: []const u8, ehdl: ButtonEhdl) StandardChild {
    const ui = call_info.ui(@src());
    return button(ui.sub(@src()), ehdl, .from(&msg, defaultTextButton_1));
}
fn defaultTextButton_1(msg: *const []const u8, caller_id: StandardCallInfo, evres: ButtonState) StandardChild {
    const ui = caller_id.ui(@src());
    const color: Beui.Color = if (evres.active) .fromHexRgb(0x0000FF) else .fromHexRgb(0x000099);
    return setBackground(ui.sub(@src()), color, .from(msg, defaultTextButton_2));
}
fn defaultTextButton_2(msg: *const []const u8, caller_id: StandardCallInfo, _: void) StandardChild {
    const ui = caller_id.ui(@src());
    return textOnly(ui.sub(@src()), msg.*, .fromHexRgb(0xFFFF00));
}

pub const ContextMenuLineEhdl = struct {
    onClick: BetweenFrameCallback(*Beui2, void, void),
};
pub const ContextMenuLineState = struct {
    active: bool,
    ehdl: ContextMenuLineEhdl,
};
/// rather than 'button', we want 'contextmenuitem'. these will follow context menu
/// behaviour:
/// - arrow keys to navigate
/// - click activates & closes context menu
/// - click & drag lets you switch to a different item to activate
/// - when you open the context menu by right clicking & hold, it shouldn't activate items
///   until you have held at least (min_time)ms and dragged at least (min_dist)px, then it
///   should act the same as if you clicked and dragged on an item
/// - the context menu is the one holding the mouse event. if you click and drag from a
///   spot without a mouse handler, it will highlight items.
/// how does this work?
/// - in the context menu's click handler, we can ask for the subtree. we know it, it was just
///   last frame. then, we can dispatch our custom event.
pub fn contextMenuLine(call_info: StandardCallInfo, ehdl: ContextMenuLineEhdl, child_component: Component(StandardCallInfo, ContextMenuLineState, StandardChild)) StandardChild {
    const tctx = tracy.trace(@src());
    defer tctx.end();

    const ui = call_info.ui(@src());

    const draw = ui.id.b2.draw();

    const draw_list_state_id = ui.id.sub(@src());
    const prev_state = ui.id.b2.getPrevFrameDrawListState(draw_list_state_id);
    const next_state = ui.id.b2.frame.arena.create(ContextMenuLineState) catch @panic("oom");
    next_state.* = .{
        .active = if (prev_state) |p| p.cast(ContextMenuLineState).active else false,
        .ehdl = ehdl,
    };
    draw.addUserState(draw_list_state_id, ContextMenuLineState, next_state);

    const child = child_component.call(ui.sub(@src()), next_state.*);
    draw.place(child.rdl, .{});
    draw.addMouseEventCapture2(ui.id.sub(@src()), .{ 0, 0 }, child.size, .{
        .buttons = .left,
        .onMouseEvent = .from(next_state, contextMenuLine__onMouseEvent),
    });
    return .{ .size = child.size, .rdl = draw };
}
fn contextMenuLine__onMouseEvent(st: *ContextMenuLineState, b2: *Beui2, ev: MouseEvent) ?Beui.Cursor {
    if (ev.action == .move_while_up) return .arrow;
    st.active = pointInRect(ev.pos, ev.capture_pos, ev.capture_size);
    if (ev.action == .up) {
        if (st.active) st.ehdl.onClick.call(b2, {});
        st.active = false;
    }
    return .arrow;
}
pub const ButtonEhdl = struct {
    onClick: BetweenFrameCallback(*Beui2, void, void),
};
pub const ButtonState = struct {
    active: bool,
    ehdl: ButtonEhdl,
};
pub fn button(call_info: StandardCallInfo, ehdl: ButtonEhdl, child_component: Component(StandardCallInfo, ButtonState, StandardChild)) StandardChild {
    const tctx = tracy.trace(@src());
    defer tctx.end();

    const ui = call_info.ui(@src());

    const draw = ui.id.b2.draw();

    const draw_list_state_id = ui.id.sub(@src());
    const prev_state = ui.id.b2.getPrevFrameDrawListState(draw_list_state_id);
    const next_state = ui.id.b2.frame.arena.create(ButtonState) catch @panic("oom");
    next_state.* = .{
        .active = if (prev_state) |p| p.cast(ButtonState).active else false,
        .ehdl = ehdl,
    };
    draw.addUserState(draw_list_state_id, ButtonState, next_state);

    const child = child_component.call(ui.sub(@src()), next_state.*);
    draw.place(child.rdl, .{});
    draw.addMouseEventCapture2(ui.id.sub(@src()), .{ 0, 0 }, child.size, .{
        .buttons = .left,
        .onMouseEvent = .from(next_state, button__onMouseEvent),
    });
    return .{ .size = child.size, .rdl = draw };
}
fn button__onMouseEvent(st: *ButtonState, b2: *Beui2, ev: MouseEvent) ?Beui.Cursor {
    if (ev.action == .move_while_up) return .arrow;
    st.active = pointInRect(ev.pos, ev.capture_pos, ev.capture_size);
    if (ev.action == .up) {
        if (st.active) st.ehdl.onClick.call(b2, {});
        st.active = false;
    }
    return .arrow;
}
const CxState = struct {
    anchor_pos: ?@Vector(2, f32),
    fn init(res: *CxState, _: void) void {
        res.* = .{ .anchor_pos = null };
    }
    fn deinit(res: *CxState) void {
        _ = res;
    }
};
fn contextMenuHolder__overlay__onMouseEvent(cxs: *CxState, b2: *Beui2, ev: MouseEvent) ?Beui.Cursor {
    if (ev.action == .down) {
        cxs.anchor_pos = null;
    }
    _ = b2;
    return .arrow;
}
fn contextMenuHolder__clickArea__onMouseEvent(cxs: *CxState, b2: *Beui2, ev: MouseEvent) ?Beui.Cursor {
    _ = b2;
    if (ev.action == .down) {
        cxs.anchor_pos = ev.pos.?;
    }
    if (ev.action == .up) {
        // if held for more than ?ms, allow click-and-release
    }
    return .arrow;
}
pub fn contextMenuHolder(call_info: SizedCallInfo, context_menu: Component(ContextMenuCallInfo, void, StandardChild)) *RepositionableDrawList {
    const ui = call_info.ui(@src());
    const cxs = ui.id.b2.state2(ui.id.sub(@src()), {}, CxState);
    if (cxs.anchor_pos) |anchor_pos| {
        var res_pos = anchor_pos;
        const screen_size = ui.id.b2.frame.frame_cfg.size;
        // consider:
        // - based on anchor_pos, limit size to @max( res_pos, screen_size - res_pos )
        // - then, based on size choose whether to place the thing above or below the anchor pos, prefer below
        // - we will have one frame delay if we want the unrounded corner to show up in the right place unless
        //   we make it draw the contents first and then draw the background in a second call, which we could
        //   do if we want

        // append a render to the final rdl
        const render_res = context_menu.call(.{ .caller_id = ui.id.sub(@src()), .constraints = .{ .screen_size = screen_size, .click_pos = res_pos } }, {});
        // position
        for (0..2) |i| if (res_pos[i] + render_res.size[i] > screen_size[i]) {
            res_pos[i] = screen_size[i] - render_res.size[i];
        };
        // place in the final
        ui.id.b2.frame.overlay_rdl.place(render_res.rdl, .{});
        // place click eater
        ui.id.b2.frame.overlay_rdl.addMouseEventCapture2(ui.id.sub(@src()), .{ 0, 0 }, screen_size, .{
            .buttons = .all,
            .onMouseEvent = .from(cxs, contextMenuHolder__overlay__onMouseEvent),
        });
    }
    const rdl = ui.id.b2.draw();
    rdl.addMouseEventCapture2(ui.id.sub(@src()), .{ 0, 0 }, ui.constraints, .{
        .buttons = .right,
        .onMouseEvent = .from(cxs, contextMenuHolder__clickArea__onMouseEvent),
    });

    // this thing has state
    // on right click: set context menu true
    // when context menu true: add a context menu render to the global draw list
    // inside the context menu: render it with max width & max height = to the screen size
    // also behind it we render a rectangle where clicks fall through but if you click it it closes the menu
    // if this component is deleted, the menu closes instantly (because it's no longer being rendered)
    return rdl;
}
// child: contextMenuEntry[ disabled, label, onclick ]
pub fn contextMenuList(call_info: ContextMenuCallInfo, child: Component(StandardCallInfo, void, StandardChild)) StandardChild {
    const ui = call_info.ui(@src());
    const rdl = ui.id.b2.draw();
    // this should be done in theme and the caller should get to set it
    const child_res = child.call(.{ .caller_id = ui.id.sub(@src()), .constraints = .{ .available_size = .{
        .w = @min(ui.constraints.screen_size[0], 300) - Theme.border_width * 2,
        .h = ui.constraints.screen_size[1] - Theme.border_width * 2,
    } } }, {});
    rdl.place(child_res.rdl, .{ .offset = ui.constraints.click_pos + @Vector(2, f32){ Theme.border_width, Theme.border_width } });
    rdl.addRect(.{
        .pos = ui.constraints.click_pos + @Vector(2, f32){ Theme.border_width, Theme.border_width },
        .size = .{ child_res.size[0], child_res.size[1] },
        .tint = Theme.colors.window_bg,
        .rounding = .{ .corners = .{ .top_right = true, .bottom_left = true, .bottom_right = true }, .radius = Theme.border_width },
    });
    rdl.addRect(.{
        .pos = ui.constraints.click_pos,
        .size = .{ child_res.size[0] + Theme.border_width * 2, child_res.size[1] + Theme.border_width * 2 },
        .tint = Theme.colors.window_border,
        .rounding = .{ .corners = .{ .top_right = true, .bottom_left = true, .bottom_right = true }, .radius = Theme.border_width * 2 },
    });
    rdl.addMouseEventCapture2(ui.id.sub(@src()), ui.constraints.click_pos, .{ child_res.size[0] + Theme.border_width * 2, child_res.size[1] + Theme.border_width * 2 }, .{
        .buttons = .left,
        .onMouseEvent = .from(&{}, contextMenuList__backgroundClick),
    });
    return .{ .size = @splat(0), .rdl = rdl };
}
fn contextMenuList__backgroundClick(_: *const void, _: *Beui2, _: MouseEvent) ?Beui.Cursor {
    return .arrow;
}
pub fn contextMenuEntry(call_info: ContextMenuCallInfo, child_component: Component(StandardCallInfo, void, StandardChild)) StandardChild {
    // this will have a default renderer in Theme
    // this one just exists to provide the hover style, keyboard nav, ...
    _ = call_info;
    _ = child_component;
}
pub const MouseEvent = struct {
    button: ?MouseButton,
    capture_pos: @Vector(2, f32),
    capture_size: @Vector(2, f32),
    pos: ?@Vector(2, f32),
    drag_start_pos: ?@Vector(2, f32),
    action: enum { down, up, move_while_down, move_while_up },
};
pub const ScrollEvent = struct {
    capture_pos: @Vector(2, f32),
    capture_size: @Vector(2, f32),
    pos: ?@Vector(2, f32),
    scroll: @Vector(2, f32),
};

fn setBackground(call_info: StandardCallInfo, color: Beui.Color, child_component: Component(StandardCallInfo, void, StandardChild)) StandardChild {
    const ui = call_info.ui(@src());
    const child = child_component.call(ui.sub(@src()), {});

    const draw = ui.id.b2.draw();
    draw.place(child.rdl, .{});
    draw.addRect(.{ .pos = .{ 0, 0 }, .size = child.size, .tint = color });
    return .{ .size = child.size, .rdl = draw };
}
const ScrollState = struct {
    offset: f32,
    anchor: util.AnySized(IDSegment.IDSegmentSize, 8),
    pub fn init(self: *ScrollState, ctx: util.AnySized(IDSegment.IDSegmentSize, 8)) void {
        self.* = .{ .offset = 0, .anchor = ctx };
    }
    pub fn deinit(_: *ScrollState) void {}
};

var _scroll_state: ?ScrollState = null;

pub fn virtualScroller(call_info: StandardCallInfo, context: anytype, comptime Index: type, child_component: Component(StandardCallInfo, Index, StandardChild)) StandardChild {
    // TODO sticky lines:
    // - sticky items stick to the top
    // - Index.parentSticky(current_node) -> sticky item to render
    // how it works:
    // - after finishing rendering children, get the parentSticky of the current first line
    // - then, render it at the top
    // - add an overlay click handler over it that says: if mouse down within bounds, jump to line
    //   (next frame, at the beginning, if there was mouse down within its bounds, we set the scroll target to its index and the scroll offset to 0)
    //   it also clicks through and does any regular click events because it's just a capturing handler.
    // TODO: scrollbar
    // - can't render a scrollbar without a height. so we'll need to set up height estimation.

    const ui = call_info.ui(@src());
    if (ui.constraints.available_size.w == null or ui.constraints.available_size.h == null) @panic("scroller2 requires known available size");

    const rdl = ui.id.b2.draw();
    const capture_sticky_click_rdl = ui.id.b2.draw();
    const capture_sticky_reservation = rdl.reserve();
    const height = ui.constraints.available_size.h.?;

    const scroll_ev_capture_id = ui.id.sub(@src());
    const scroll_by = ui.id.b2.scrollCaptureResults(scroll_ev_capture_id);

    const scroll_state = ui.id.b2.state2(ui.id.sub(@src()), util.AnySized(IDSegment.IDSegmentSize, 8).from(Index, .first(context)), ScrollState);

    scroll_state.offset += scroll_by[1];

    var cursor: f32 = scroll_state.offset;

    const idx_initial = scroll_state.anchor.as(Index);
    var idx = idx_initial.update(context);
    if (idx) |val| scroll_state.anchor = .from(Index, val);

    const loop_index = ui.id.pushLoop(@src(), Index);
    if (cursor > 0 and idx != null) {
        // seek backwards
        var backwards_cursor = cursor;
        var backwards_index = idx.?;
        while (backwards_cursor > 0) {
            backwards_index = backwards_index.prev(context) orelse break;

            const child = child_component.call(.{ .caller_id = loop_index.valueNoSrc(backwards_index), .constraints = .{
                .available_size = .{ .w = ui.constraints.available_size.w.?, .h = null },
            } }, backwards_index);

            backwards_cursor -= child.size[1];
            scroll_state.anchor = .from(Index, backwards_index);
            scroll_state.offset -= child.size[1];
            rdl.place(child.rdl, .{ .offset = .{ 0, backwards_cursor } });
        }
    }
    while (idx != null) {
        if (cursor > height) break;

        const child = child_component.call(.{ .caller_id = loop_index.valueNoSrc(idx.?), .constraints = .{
            .available_size = .{ .w = ui.constraints.available_size.w.?, .h = null },
        } }, idx.?);

        if (cursor < -child.size[1]) blk: {
            scroll_state.anchor = .from(Index, idx.?.next(context) orelse break :blk);
            scroll_state.offset += child.size[1];
        }
        rdl.place(child.rdl, .{ .offset = .{ 0, cursor } });
        cursor += child.size[1];

        idx = idx.?.next(context);
    }

    var capture_sticky_offset: f32 = 0;
    // disabled for now because it doesn't work right and I'm not sure how to make it work.
    // some kind of you have to look at where items rendered on screen or something
    if (@hasDecl(Index, "parentSticky") and false) blk: {
        var sticky = scroll_state.anchor.as(Index);
        if (scroll_state.offset > 0) break :blk; // we're off the top of the page! no need for stickies
        if (scroll_state.offset < 0) sticky = sticky.next(context) orelse break :blk;
        var i: usize = 0;
        const STICKY_LIMIT = 1;
        while (true) : (i += 1) {
            if (i >= STICKY_LIMIT) break;
            sticky = sticky.parentSticky(context) orelse break;

            // ideally we would call pushLoopValueNoSrc() but to do that first we need to see if we've already rendered
            // this item, and if we have, use it and take it out of the render list instead of rerendering it.
            const child = child_component.call(.{ .caller_id = loop_index.pushLoopValue(@src(), sticky), .constraints = .{
                .available_size = .{ .w = ui.constraints.available_size.w.?, .h = null },
            } }, sticky);

            capture_sticky_offset += child.size[1];
            // TODO: place click observer
            capture_sticky_click_rdl.place(child.rdl, .{ .offset = .{ 0, -capture_sticky_offset } });
        }
    }

    rdl.fill(capture_sticky_reservation, capture_sticky_click_rdl, .{ .offset = .{ 0, capture_sticky_offset } });

    rdl.addMouseEventCapture(
        scroll_ev_capture_id,
        .{ 0, 0 },
        .{ ui.constraints.available_size.w.?, ui.constraints.available_size.h.? },
        .{ .capture_scroll = .{ .y = true } },
    );

    return .{ .size = .{ ui.constraints.available_size.w.?, ui.constraints.available_size.h.? }, .rdl = rdl };
}

pub fn scrollDemo(call_info: StandardCallInfo) StandardChild {
    const ui = call_info.ui(@src());

    const my_list: []const []const []const u8 = &[_][]const []const u8{
        &[_][]const u8{ "flying", "searing", "lesser", "greater", "weak", "durable", "enchanted", "magic" },
        &[_][]const u8{ "apple", "banana", "cherry", "durian", "etobicoke", "fig", "grape" },
        &[_][]const u8{ "goblin", "blaster", "cannon", "cook", "castle" },
    };
    var my_list_len: usize = 1;
    for (my_list) |item| {
        my_list_len *= item.len;
    }

    return virtualScroller(ui.sub(@src()), my_list_len, ListIndex, .from(&my_list, scrollDemo_0_3));
}
fn scrollDemo_0_3(my_list: *const []const []const []const u8, caller_id: StandardCallInfo, index: ListIndex) StandardChild {
    const ui = caller_id.ui(@src());

    var res_str: []const u8 = "";

    var i = index.i;
    for (my_list.*, 0..) |items, j| {
        const sub_i = i % items.len;
        res_str = ui.id.b2.fmt("{s}{s}{s}", .{ res_str, if (j == 0) "" else " ", items[sub_i] });
        i = @divFloor(i, items.len);
    }

    return defaultTextButton(ui.sub(@src()), res_str, null);
}

pub const B2Tester = struct {
    // this is way overcomplicated! we need to:
    // - merge b1 into b2
    // - simplify b2 initialization and usage
    arena: std.heap.ArenaAllocator,
    b1: Beui,
    b2: Beui2,
    draw_list: Beui.draw_lists.RenderList,
    vtable: BeuiVtable,

    const BeuiVtable = struct {
        fn setClipboard(_: *const Beui.FrameCfg, _: [:0]const u8) void {
            std.log.info("TODO setClipboard", .{});
        }
        fn getClipboard(_: *const Beui.FrameCfg, _: *std.array_list.Managed(u8)) void {
            std.log.info("TODO getClipboard", .{});
        }
        pub const vtable: *const Beui.FrameCfgVtable = &.{
            .type_id = @typeName(@This()),
            .set_clipboard = &setClipboard,
            .get_clipboard = &getClipboard,
        };
    };
    pub fn init(self: *B2Tester, gpa: std.mem.Allocator) void {
        self.arena = std.heap.ArenaAllocator.init(gpa);
        self.b1 = .{};
        self.b2.init(&self.b1, gpa);
        self.draw_list = .init(gpa);
        self.vtable = .{};
    }
    pub fn deinit(self: *B2Tester) void {
        self.draw_list.deinit();
        self.b2.deinit();
        self.arena.deinit();
    }

    pub fn startFrame(self: *B2Tester, now: i64, size: @Vector(2, f32)) ID {
        self.draw_list.clear();
        _ = self.arena.reset(.retain_capacity);
        self.b1.newFrame(.{
            .arena = self.arena.allocator(),
            .now_ms = now,
            .user_data = @ptrCast(@alignCast(&self.vtable)),
            .vtable = BeuiVtable.vtable,
        });
        const id = self.b2.newFrame(.{ .size = size });
        return id;
    }
    pub fn endFrame(self: *B2Tester, rdl: *RepositionableDrawList) void {
        self.b2.endFrame(rdl, &self.draw_list);
        self.b1.endFrame();
    }
};

test "state2" {
    const gpa = std.testing.allocator;

    var tester: B2Tester = undefined;
    tester.init(gpa);
    defer tester.deinit();

    _ = tester.startFrame(1000, .{ 1000, 500 });
    tester.endFrame(tester.b2.draw());

    // TODO: test state2
    // TODO: clean up beui setup, what a mess!
}

test {
    _ = @import("wm.zig");
}
