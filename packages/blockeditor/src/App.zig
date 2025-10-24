const std = @import("std");
const blocks_mod = @import("blocks");
const bi = blocks_mod.blockinterface2;
const db_mod = blocks_mod.blockdb;
const Beui = @import("beui").Beui;
const blocks_net = @import("blocks_net");
const anywhere = @import("anywhere");
const tracy = anywhere.tracy;
const zgui = anywhere.zgui;
const B2 = Beui.beui_experiment;
const WM = B2.WM;
const util = anywhere.util;

pub const std_options = std.Options{
    .log_scope_levels = &.{
        .{ .scope = .emu, .level = .err },
    },
};

const App = @This();

gpa: std.mem.Allocator,

db: db_mod.BlockDB,
db_sync: ?blocks_net.TcpSync,

counter_block: *db_mod.BlockRef,
counter_component: db_mod.TypedComponentRef(bi.CounterComponent),

wm: WM.Manager,

pub fn init(self: *App, gpa: std.mem.Allocator) void {
    return self.initWithCfg(gpa, .{});
}
pub fn initWithCfg(self: *App, gpa: std.mem.Allocator, cfg: struct { enable_db_sync: bool = true }) void {
    self.gpa = gpa;

    self.db = db_mod.BlockDB.init(gpa);
    if (@import("builtin").target.os.tag != .wasi and cfg.enable_db_sync) {
        self.db_sync = @as(blocks_net.TcpSync, undefined);
        self.db_sync.?.init(gpa, &self.db);
    } else {
        self.db_sync = null;
    }

    self.counter_block = self.db.createBlock(bi.CounterBlock.deserialize(gpa, bi.CounterBlock.default) catch @panic("oom"));
    self.counter_component = self.counter_block.typedComponent(bi.CounterBlock).?;

    self.wm = .init(self.gpa);
}
pub fn deinit(self: *App) void {
    self.wm.deinit();

    self.counter_component.unref();
    self.counter_block.unref();
    if (self.db_sync) |*s| s.deinit();
    self.db.deinit();
}

pub fn addTab(self: *App, file_cont: []const u8) *db_mod.BlockRef {
    const text_block = self.db.createBlock(bi.TextDocumentBlock.deserialize(self.gpa, bi.TextDocumentBlock.default) catch unreachable);
    defer text_block.unref();
    {
        const text_component = text_block.typedComponent(bi.TextDocumentBlock).?;
        defer text_component.unref();

        text_component.applySimpleOperation(.{
            .position = text_component.value.positionFromDocbyte(0),
            .delete_len = 0,
            .insert_text = file_cont,
        }, null);
    }
    text_block.ref();
    return text_block;
}

pub fn render(self: *App, call_id: B2.ID) *B2.RepositionableDrawList {
    const id = call_id.sub(@src());

    self.wm.beginFrame(.{ .id = id.sub(@src()), .size = id.b2.frame.frame_cfg.size });

    self.db.tickBegin();
    defer self.db.tickEnd();

    if (zgui.beginWindow("My counter (editor 1)", .{})) {
        defer zgui.endWindow();
        renderCounter(self.counter_component);
    }

    // const wm = b2.windowManager();
    // b2.windows.add()

    // const id_loop_2 = id.pushLoop(@src(), *db_mod.BlockRef);
    // for (self.wm.wm.frames.items) |fi| {
    //     // the crash here is because self.wm.wm.frames.items is getting invalidated during self.wm.addWindow / self.wm.addFullscreenOverlay
    //     // we need to have Theme directly call our render fn directly.
    //     std.log.info("frame: {s}", .{@tagName(fi.self)});
    //     if (fi.self == .final and fi.self.final.ref != null) {
    //         std.log.info("  reading back ref: {x}", .{@intFromPtr(fi.self.final.ref)});
    //         const bwi = fi.self.final.ref.?;
    //         const id_sub = id_loop_2.pushLoopValue(@src(), bwi);
    //         if (bwi.contents().?.vtable.uuid == bi.BouncyBallViewer.uuid) {
    //             // temporary hack, not sure what the final solution will be
    //             self.wm.addFullscreenOverlay(id.sub(@src()), .from(bwi, render__block));
    //         } else {
    //             self.wm.addWindow(id_sub.sub(@src()), "Block Window", .from(bwi, render__block));
    //         }
    //     }
    // }

    const result = self.wm.endFrame(.from(self, render__block));
    // bg right click handler
    result.place(B2.contextMenuHolder(.{ .constraints = id.b2.frame.frame_cfg.size, .caller_id = id.sub(@src()) }, .from(self, render__contextMenu)), .{});
    result.addRect(.{ .pos = .{ 0, 0 }, .size = id.b2.frame.frame_cfg.size, .tint = B2.Theme.colors.window_bg });
    return result;
}

fn render__contextMenu(self: *App, sci: B2.ContextMenuCallInfo, _: void) B2.StandardChild {
    const ui = sci.ui(@src());
    return B2.contextMenuList(ui.sub(@src()), .from(self, render__contextMenu__child));
}
const render__contextMenu__child__child_Data = struct {
    const Details = struct {
        label: []const u8,
        kind: enum {
            debug_1,
            debug_2,
            debug_wm,
            minigamer,
            file_tree,
            bouncy_ball,
            editor_app_zig,
            editor_empty,
        },
    };
    self: *App,
    details: Details,
};
fn render__contextMenu__child(self: *App, sci: B2.StandardCallInfo, _: void) B2.StandardChild {
    const ui = sci.ui(@src());
    var size: @Vector(2, f32) = @splat(0);
    const rdl = ui.id.b2.draw();
    const id_outer = ui.id.pushLoop(@src(), usize);
    for (&[_]render__contextMenu__child__child_Data.Details{
        .{
            .label = "Debug 1",
            .kind = .debug_1,
        },
        .{
            .label = "Debug 2",
            .kind = .debug_2,
        },
        .{
            .label = "Debug WM",
            .kind = .debug_wm,
        },
        .{
            .label = "Minigamer",
            .kind = .minigamer,
        },
        .{
            .label = "File Tree",
            .kind = .file_tree,
        },
        .{
            .label = "Bouncy Ball",
            .kind = .bouncy_ball,
        },
        .{
            .label = "Editor (App.zig)",
            .kind = .editor_app_zig,
        },
        .{
            .label = "Editor (Empty)",
            .kind = .editor_empty,
        },
    }, 0..) |ctxm_stack, i| {
        const id_inner = id_outer.valueNoSrc(i);
        const ui_inner: B2.StandardUI = .{ .constraints = ui.constraints, .id = id_inner };
        const ctxm = ui_inner.id.b2.dupeOne(render__contextMenu__child__child_Data{ .self = self, .details = ctxm_stack });
        const itm = B2.contextMenuLine(ui_inner.sub(@src()), .{ .onClick = .from(ctxm, render__contextMenu__child__onClick) }, .from(ctxm, render__contextMenu__child__child));
        rdl.place(itm.rdl, .{ .offset = .{ 0, size[1] } });
        size[0] = @max(size[0], itm.size[0]);
        size[1] += itm.size[1];
    }

    return .{
        .size = size,
        .rdl = rdl,
    };
}
fn render__contextMenu__child__onClick(ctx: *render__contextMenu__child__child_Data, _: *B2.Beui2, _: void) void {
    const self = ctx.self;
    switch (ctx.details.kind) {
        .debug_1 => {
            const debug_1 = self.db.createBlock(bi.DebugViewer.deserialize(self.gpa, bi.DebugViewer.default) catch @panic("oom"));
            self.wm.wm.moveFrameNewWindow(self.wm.wm.addFrame(.{ .final = .{ .ref = debug_1 } }));
        },
        .debug_2 => {
            const debug_2 = self.db.createBlock(bi.DebugViewer.deserialize(self.gpa, bi.DebugViewer.default) catch @panic("oom"));
            {
                const debug_2_component = debug_2.typedComponent(bi.DebugViewer).?;
                defer debug_2_component.unref();
                debug_2_component.applySimpleOperation(.{ .set = 1 }, null);
            }
            self.wm.wm.moveFrameNewWindow(self.wm.wm.addFrame(.{ .final = .{ .ref = debug_2 } }));
        },
        .debug_wm => {
            const debugwm_viewer = self.db.createBlock(bi.DebugWMViewer.deserialize(self.gpa, bi.DebugWMViewer.default) catch @panic("oom"));
            self.wm.wm.moveFrameNewWindow(self.wm.wm.addFrame(.{ .final = .{ .ref = debugwm_viewer } }));
        },
        .minigamer => {
            const minigamer_viewer = self.db.createBlock(bi.MinigamerViewer.deserialize(self.gpa, bi.MinigamerViewer.default) catch @panic("oom"));
            self.wm.wm.moveFrameNewWindow(self.wm.wm.addFrame(.{ .final = .{ .ref = minigamer_viewer } }));
        },
        .file_tree => {
            const filetree_viewer = self.db.createBlock(bi.FileTreeViewer.deserialize(self.gpa, bi.FileTreeViewer.default) catch @panic("oom"));
            self.wm.wm.moveFrameNewWindow(self.wm.wm.addFrame(.{ .final = .{ .ref = filetree_viewer } }));
        },
        .bouncy_ball => {
            const bouncy_ball = self.db.createBlock(bi.BouncyBallViewer.deserialize(self.gpa, bi.BouncyBallViewer.default) catch @panic("oom"));
            self.wm.wm.moveFrameNewWindow(self.wm.wm.addFrame(.{ .final = .{ .ref = bouncy_ball } }));
        },
        .editor_app_zig => {
            const editor_full = self.addTab(@embedFile("App.zig"));
            self.wm.wm.moveFrameNewWindow(self.wm.wm.addFrame(.{ .final = .{ .ref = editor_full } }));
        },
        .editor_empty => {
            const editor_empty = self.addTab("abc\ndef\nghi");
            self.wm.wm.moveFrameNewWindow(self.wm.wm.addFrame(.{ .final = .{ .ref = editor_empty } }));
        },
    }
}
fn render__contextMenu__child__child(ctx: *render__contextMenu__child__child_Data, sci: B2.StandardCallInfo, _: B2.ContextMenuLineState) B2.StandardChild {
    return B2.textLine(sci, .{ .text = ctx.details.label });
}

const BounceBallState = struct {
    ball_pos_px: @Vector(2, f32),
    ball_vel_per_frame: @Vector(2, f32),
    ball_dragging: bool,
    fixed_timestep_manager: anywhere.util.FixedTimestep,

    prev_mouse_pos: ?@Vector(2, f32) = null,
    prev_mouse_time: f64 = 0.0,
    prev2_mouse_pos: ?@Vector(2, f32) = null,
    prev2_mouse_time: f64 = 0.0,
    prev3_mouse_pos: ?@Vector(2, f32) = null,
    prev3_mouse_time: f64 = 0.0,

    pub fn init(self: *BounceBallState, whole_size: @Vector(2, f32)) void {
        self.* = .{
            .ball_pos_px = whole_size / @Vector(2, f32){ 2.0, 2.0 },
            .ball_vel_per_frame = .{ 0, 0 },
            .ball_dragging = false,
            .fixed_timestep_manager = .init(anywhere.util.fpsToMspf(120.0)),
        };
    }
    pub fn deinit(_: *BounceBallState) void {}
};
const ball_diameter: f32 = 80.0;
const ball_size: @Vector(2, f32) = @splat(ball_diameter);
const ball_size_half: @Vector(2, f32) = @splat(ball_diameter / 2.0);
fn render__bounceBall(call_info: B2.StandardCallInfo) *B2.RepositionableDrawList {
    const whole_size: @Vector(2, f32) = .{ call_info.constraints.available_size.w.?, call_info.constraints.available_size.h.? };

    const ui = call_info.ui(@src());
    const b2 = ui.id.b2;

    const state = b2.state2(ui.id.sub(@src()), whole_size, BounceBallState);

    // correct if the window was resized
    state.ball_pos_px = @max(state.ball_pos_px, ball_size_half);
    state.ball_pos_px = @min(state.ball_pos_px, whole_size - ball_size_half);

    // to update this to variable timestep:
    // - change gravity to `+= 0.5 * dt`
    // - change air resistance to ` *= @splat( std.math.pow(f64, dt, 0.99) )`
    // where 16.6666 ms = 1.0 dt
    for (0..state.fixed_timestep_manager.advance(@floatFromInt(b2.persistent.beui1.frame.frame_cfg.?.now_ms))) |_| {
        // gravity
        if (!state.ball_dragging) state.ball_vel_per_frame[1] += 0.5;

        // move
        state.ball_pos_px += state.ball_vel_per_frame;

        // air resistance
        state.ball_vel_per_frame *= @splat(0.99);

        // bounce wall
        if (state.ball_pos_px[0] < ball_size_half[0]) {
            state.ball_vel_per_frame[0] = -state.ball_vel_per_frame[0];
            state.ball_pos_px[0] = ball_size_half[0];
        }
        if (state.ball_pos_px[1] < ball_size_half[1]) {
            state.ball_vel_per_frame[1] = -state.ball_vel_per_frame[1];
            state.ball_pos_px[1] = ball_size_half[1];
        }
        if (state.ball_pos_px[0] > whole_size[0] - ball_size_half[0]) {
            state.ball_vel_per_frame[0] = -state.ball_vel_per_frame[0];
            state.ball_pos_px[0] = whole_size[0] - ball_size_half[0];
        }
        if (state.ball_pos_px[1] > whole_size[1] - ball_size_half[1]) {
            state.ball_vel_per_frame[1] = -state.ball_vel_per_frame[1];
            state.ball_pos_px[1] = whole_size[1] - ball_size_half[1];
        }
    }

    // TODO:
    // - [x] drag with mouse
    // - [ ] consistent throwing on mouse up
    // - [ ] detect when at rest (vel 0 & on ground)
    // - [ ] request an animation frame when not at rest (so when you throw the ball
    //       it keeps moving. once screen refreshing is only enabled for a real action,
    //       this will matter.)
    // - [ ] support scroll wheel to throw the ball
    // nice to have:
    // - [ ] make the ball squash and stretch. that would be fun.

    const rdl = b2.draw();

    rdl.addRect(.{
        .pos = state.ball_pos_px - ball_size_half,
        .size = ball_size,
        .tint = .fromHexRgb(0xFF0000),
        .rounding = .{ .corners = .all, .style = .round, .radius = ball_diameter / 2 },
    });
    rdl.addMouseEventCapture2(ui.id.sub(@src()), state.ball_pos_px - ball_size_half, ball_size, .{
        .buttons = .left,
        .onMouseEvent = .from(state, render__bounceBall__onMouseEvent),
    });

    return rdl;
}
fn render__bounceBall__onMouseEvent(state: *BounceBallState, b2: *B2.Beui2, ev: B2.MouseEvent) ?Beui.Cursor {
    const now: f64 = @floatFromInt(b2.persistent.beui1.frame.frame_cfg.?.now_ms);
    if (ev.action == .down or ev.action == .move_while_up) {
        const cpos = ((ev.pos.? - ev.capture_pos) - ball_size_half) / ball_size_half;
        const dist = @sqrt(cpos[0] * cpos[0] + cpos[1] * cpos[1]);
        if (dist <= 1.0) {
            // actually touching
            if (ev.action == .down) {
                state.ball_dragging = true;
                state.ball_vel_per_frame = .{ 0, 0 };
                state.prev_mouse_pos = ev.pos.?;
                state.prev_mouse_time = now;
                state.prev2_mouse_pos = ev.pos.?;
                state.prev2_mouse_time = now;
                state.prev3_mouse_pos = ev.pos.?;
                state.prev3_mouse_time = now;
            }
            return .arrow;
        } else {
            // not touching; ignore event
            return null;
        }
    } else {
        if (ev.action == .up) {
            const diff = ev.pos.? - state.prev3_mouse_pos.?;
            const tdiff: f32 = @floatCast(now - state.prev3_mouse_time);

            state.ball_dragging = false;
            if (tdiff < 1) {
                // std.log.info("throw failed; missing average", .{});
            } else {
                // std.log.info("throwing {d} over {d}ms", .{ diff, tdiff });
                state.ball_vel_per_frame = diff / @as(@Vector(2, f32), @splat(tdiff / @as(f32, @floatCast(anywhere.util.fpsToMspf(120)))));
            }
        } else {
            const diff = ev.pos.? - state.prev_mouse_pos.?;
            // currently dragging
            state.prev3_mouse_pos = state.prev2_mouse_pos;
            state.prev3_mouse_time = state.prev2_mouse_time;

            state.prev2_mouse_pos = state.prev_mouse_pos;
            state.prev2_mouse_time = state.prev_mouse_time;

            state.prev_mouse_pos = ev.pos.?;
            state.prev_mouse_time = now;

            state.ball_pos_px += diff;
        }

        return .arrow;
    }
}

const EditorState = struct {
    view: Beui.EditorView,
    zig_language: Beui.EditorView.Core.highlighters_zig.HlZig,
    markdown_language: Beui.EditorView.Core.highlighters_markdown.HlMd,
    const Cfg = struct { gpa: std.mem.Allocator, doc: db_mod.TypedComponentRef(bi.text_component.TextDocument) };
    pub fn init(self: *EditorState, cfg: Cfg) void {
        self.zig_language = Beui.EditorView.Core.highlighters_zig.HlZig.init(cfg.gpa);
        self.markdown_language = Beui.EditorView.Core.highlighters_markdown.HlMd.init();

        self.view.initFromDoc(cfg.gpa, cfg.doc);
        self.view.core.setSynHl(self.zig_language.language());
        self.view.core.executeCommand(.{ .set_cursor_pos = .{ .position = cfg.doc.value.positionFromDocbyte(0) } });
    }
    pub fn deinit(self: *EditorState) void {
        self.zig_language.deinit();
        self.markdown_language.deinit();
        self.view.deinit();
    }
};
fn render__editor(text: db_mod.TypedComponentRef(bi.text_component.TextDocument), call_info: B2.StandardCallInfo) *B2.RepositionableDrawList {
    const tctx = tracy.traceNamed(@src(), "App editor");
    defer tctx.end();

    const ui = call_info.ui(@src());
    const state = ui.id.b2.state2(ui.id.sub(@src()), EditorState.Cfg{ .doc = text, .gpa = ui.id.b2.persistent.gpa }, EditorState);

    const res = state.view.gui(ui.sub(@src()), ui.id.b2.persistent.beui1);
    return res.rdl;
}

const RenderTreeIndex = struct {
    i: usize,
    pub fn first(_: usize) RenderTreeIndex {
        return .{ .i = 0 };
    }
    pub fn update(itm: RenderTreeIndex, len: usize) ?RenderTreeIndex {
        if (itm.i >= len) return if (len == 0) null else .{ .i = len - 1 };
        return .{ .i = itm.i };
    }
    pub fn prev(itm: RenderTreeIndex, _: usize) ?RenderTreeIndex {
        if (itm.i == 0) return null;
        return .{ .i = itm.i - 1 };
    }
    pub fn next(itm: RenderTreeIndex, len: usize) ?RenderTreeIndex {
        if (itm.i == len - 1) return null;
        return .{ .i = itm.i + 1 };
    }
};
fn render__block(self: *App, arg: WM.Manager.RenderBlockArg) *B2.RepositionableDrawList {
    const ui = arg.call_info.ui(@src());

    const block = arg.block orelse {
        return B2.textLine(ui.sub(@src()), .{ .text = "placeholder" }).rdl;
    };

    if (block.contents()) |c| switch (c.vtable.uuid) {
        bi.DebugViewer.uuid => {
            const rdl = ui.id.b2.draw();

            const value = block.typedComponent(bi.DebugViewer).?;
            defer value.unref();

            // TODO should be scrollable, vertical and horizontal
            // maybe window can autoscroll when content exceeds its bounds
            rdl.addRect(.{
                .pos = .{ 0, 0 },
                .size = .{ 2048, 2048 },
                .uv_pos = .{ 0, 0 },
                .uv_size = .{ 1, 1 },
                .image = if (value.value.count == 0) .grayscale else .rgba,
            });
            rdl.addRect(.{
                .pos = .{ 0, 0 },
                .size = .{ ui.constraints.available_size.w.?, ui.constraints.available_size.h.? },
                .tint = B2.Theme.colors.window_bg,
                .rounding = .{ .corners = .all, .radius = 6.0 },
            });

            return rdl;
        },
        bi.MinigamerViewer.uuid => {
            return @import("mini.zig").render(&{}, ui.sub(@src()), {});
        },
        bi.FileTreeViewer.uuid => {
            return render__tree(self, ui.sub(@src()), {});
        },
        bi.TextDocumentBlock.uuid => {
            // TODO: this should be a TextEditor containing the TextDocumentBlock, not the TextDocumentBlock itself.
            const text_component = block.typedComponent(bi.TextDocumentBlock).?;
            defer text_component.unref();

            return render__editor(text_component, ui.sub(@src()));
        },
        bi.BouncyBallViewer.uuid => {
            return render__bounceBall(ui.sub(@src()));
        },
        bi.DebugWMViewer.uuid => {
            var al = std.array_list.Managed(u8).init(self.gpa);
            defer al.deinit();
            const msg = if (self.wm.wm.testingRenderToString(&al)) |val| val else |e| @errorName(e);
            const rdl = ui.id.b2.draw();
            var split = std.mem.splitScalar(u8, msg, '\n');
            // ideally we could have a generic text component that would use diff-match-patch maybe to preserve
            // selection & scroll position across updates?
            const lp = ui.id.pushLoop(@src(), usize);
            var i: usize = 0;
            var pos: @Vector(2, f32) = .{ 0, 0 };
            while (split.next()) |itm| : (i += 1) {
                const line = B2.textLine(.{
                    .caller_id = lp.valueNoSrc(i),
                    .constraints = ui.constraints,
                }, .{ .text = itm });
                rdl.place(line.rdl, .{ .offset = pos });
                pos[1] += line.size[1];
            }
            return rdl;
        },
        else => {
            return B2.textLine(ui.sub(@src()), .{ .text = ui.id.b2.fmt("no ui provided for: {s}", .{std.mem.span(c.vtable.type_id)}) }).rdl;
        },
    } else {
        return B2.textLine(ui.sub(@src()), .{ .text = "loading" }).rdl;
    }
}
const TreeState = struct {
    tree: FsTree2,
    pub fn init(self: *TreeState, gpa: std.mem.Allocator) void {
        var outbuf: [std.fs.max_path_bytes]u8 = undefined;
        var res: FsTree2 = .init(if (@import("builtin").os.tag == .wasi) (
            // realpath should never be used. but until then:
            "/") else std.fs.cwd().realpath("../..", &outbuf) catch |e| blk: {
            std.log.err("unable to get realpath: {s}", .{@errorName(e)});
            break :blk "";
        }, gpa);
        res.createRootNode();
        self.* = .{ .tree = res };
    }
    pub fn deinit(self: *TreeState) void {
        self.tree.deinit();
    }
};
fn render__tree(self: *App, call_info: B2.StandardCallInfo, _: void) *B2.RepositionableDrawList {
    const ui = call_info.ui(@src());
    const state = ui.id.b2.state2(ui.id.sub(@src()), ui.id.b2.persistent.gpa, TreeState);
    const tree = &state.tree;

    const rdl = ui.id.b2.draw();
    const tco = ui.id.b2.dupeOne(TreeChildOpts{ .tree = tree, .app = self });
    const chres = B2.virtualScroller(ui.sub(@src()), tree, FsTree2.Index, .from(tco, render__tree__child));
    rdl.place(chres.rdl, .{});
    rdl.addRect(.{
        .pos = .{ 0, 0 },
        .size = chres.size,
        .tint = B2.Theme.colors.window_bg,
        .rounding = .{ .corners = .all, .radius = 6.0 },
    });
    return rdl;
}
const TreeChildOpts = struct { tree: *FsTree2, app: *App };
fn render__tree__child(tco: *TreeChildOpts, call_info: B2.StandardCallInfo, index: FsTree2.Index) B2.StandardChild {
    const tctx = tracy.trace(@src());
    defer tctx.end();

    const ui = call_info.ui(@src());

    const tree = tco.tree;
    const app = tco.app;

    const tree_node = index.current_node orelse unreachable;

    const tree_data = ui.id.b2.frame.arena.create(render__tree__child_onClick_data) catch @panic("oom");
    tree_data.* = .{ .tree = tree, .tree_node = tree_node, .app = app };
    const ehdl: B2.ButtonEhdl = .{
        .onClick = .from(tree_data, render__tree__child_onClick),
    };
    return B2.button(ui.sub(@src()), ehdl, .from(&TreeChild{ .tree = tree, .node = tree_node }, render__tree__child__child));
}
const render__tree__child_onClick_data = struct {
    tree: *FsTree2,
    tree_node: *FsTree2.Node,
    app: *App,
};
fn render__tree__child_onClick(data: *render__tree__child_onClick_data, b2: *B2.Beui2, _: void) void {
    const tree = data.tree;
    const tree_node = data.tree_node;
    // if App was deinitialized at the end of this frame, self & tree_node won't exist.
    // luckily that (probably? what if we run two apps?) won't happen with App, but this
    // issue needs to be solved. like somehow in deinit fns we also need to have a list
    // of callbacks to deactivate.
    if (tree_node.node_type == .file) {
        // what's the reason to require double click again? so you can select a file without opening it in order to rename it
        // or something like that?
        // if (ui.id.b2.persistent.beui1.leftMouseClickedCount() == 2) {
        var file_path = std.array_list.Managed(u8).init(b2.frame.arena);
        tree.getPath(tree_node, &file_path);
        if (std.fs.cwd().readFileAlloc(b2.frame.arena, file_path.items, std.math.maxInt(usize))) |file_cont| {
            data.app.wm.wm.moveFrameNewWindow(data.app.wm.wm.addFrame(.{ .final = .{ .ref = data.app.addTab(file_cont) } }));
        } else |e| {
            std.log.err("Failed to open file: {s}", .{@errorName(e)});
        }
    } else {
        if (!tree_node.opened) {
            tree.expand(tree_node) catch |e| {
                std.log.err("Failed to open directory: {s}", .{@errorName(e)});
            };
        } else {
            tree.contract(tree_node);
        }
    }
}
const TreeChild = struct { tree: *FsTree2, node: *FsTree2.Node };
fn render__tree__child__child(tc: *const TreeChild, call_info: B2.StandardCallInfo, state: B2.ButtonState) B2.StandardChild {
    const tree_node = tc.node;
    const ui = call_info.ui(@src());

    const offset_x: f32 = @as(f32, @floatFromInt(tree_node.indent_level)) * 6;

    const draw = ui.id.b2.draw();
    const icon = switch (tc.node.node_type) {
        .dir => switch (tc.node.opened) {
            true => B2.components.Icon.Icon(ui.sub(@src()), B2.Theme.icons.arrow_revealed, "Collapse"),
            false => B2.components.Icon.Icon(ui.sub(@src()), B2.Theme.icons.arrow_collapsed, "Reveal"),
        },
        else => B2.components.Icon.Icon(ui.sub(@src()), B2.Theme.icons.bullet, "Open"),
    };
    const res = B2.textLine(ui.subWithOffset(@src(), .{ offset_x + icon.size[0], 0 }), .{ .text = tree_node.basename_owned }); //, .fromHexRgb(0xFFFFFF));
    const container_max = @max(icon.size[1], res.size[1]);
    // HSplit(.(.self_x, .center_y) Icon(), .(.rem_x, .center_y) textLine())
    // (to run hsplit, it has to run all 'rem's last, which is interesting.)
    draw.place(icon.rdl, .{ .offset = .{ offset_x, util.centerIn(container_max, icon.size[1]) } });
    draw.place(res.rdl, .{ .offset = .{ offset_x + icon.size[0], util.centerIn(container_max, res.size[1]) } });
    if (state.active) {
        draw.addRect(.{ .pos = .{ 0, 0 }, .size = .{ call_info.constraints.available_size.w.?, container_max }, .tint = .fromHexRgb(0x747474) });
    }
    return .{ .rdl = draw, .size = .{ call_info.constraints.available_size.w.?, container_max } };
}

fn renderCounter(counter: db_mod.TypedComponentRef(bi.CounterComponent)) void {
    zgui.text("Count: {d}", .{counter.value.count});
    if (zgui.button("Increment!", .{})) {
        counter.applySimpleOperation(.{ .add = 1 }, null);
    }
    if (zgui.button("Zero!", .{})) {
        counter.applySimpleOperation(.{ .set = 0 }, null);
    }
    if (zgui.button("Undo!", .{})) {
        @panic("TODO: someone needs to keep an undo list");
    }
    if (zgui.button("Redo!", .{})) {
        @panic("TODO: someone needs to keep a redo list");
    }
}

test "app renders" {
    var app: App = undefined;
    app.initWithCfg(std.testing.allocator, .{ .enable_db_sync = false });
    defer app.deinit();

    var tester: B2.B2Tester = undefined;
    tester.init(std.testing.allocator);
    defer tester.deinit();

    // render two frames
    for (0..2) |_| {
        const root_id = tester.startFrame(0, .{ 200, 200 });

        const rdl = app.render(root_id.sub(@src()));

        tester.endFrame(rdl);
    }
}
const testing_vtable: Beui.FrameCfgVtable = .{
    .type_id = @typeName(void),
};

const FsTree2 = struct {
    // if we could embed virutalized scrollers inside other virtualized scrollers then
    // we wouldn't have to keep nodes around forever
    // TODO: if you open a dir and open some dirs within it, then close the outer dir and reopen it,
    // the inner dirs should stay open. might require a bit of a rethink?
    const Node = struct {
        basename_owned: []u8,
        child_index: usize,
        node_type: enum { dir, file, other },
        parent: ?*Node,
        children_owned: []*Node, // MUST BE SORTED BY std.mem.order IF opened IS false
        opened: bool,
        is_deleted: bool,
        indent_level: usize,
        fn deinit(self: *Node, gpa: std.mem.Allocator) void {
            gpa.free(self.basename_owned);
            gpa.free(self.children_owned);
        }
    };
    root_dir_owned: []const u8,
    root_node: ?*Node,
    node_pool: std.heap.ArenaAllocator,
    all_nodes: std.array_list.Managed(*Node),
    deleted_nodes: std.array_list.Managed(*Node),

    pub const Index = struct {
        // pointer stays valid because we never delete nodes. if they are to be reused, they stay valid until
        // they are replaced with a new value.
        current_node: ?*Node,

        pub fn first(self: *FsTree2) Index {
            return .{ .current_node = self.root_node };
        }
        pub fn update(itm_in: Index, self: *FsTree2) ?Index {
            if (itm_in.current_node == null) return null;
            var node = itm_in.current_node.?;
            while (node.is_deleted) {
                if (node.parent) |parent| {
                    node = parent;
                } else {
                    // deleted node has no parent
                    if (self.root_node) |root_node| return .{ .current_node = root_node };
                    return null;
                }
            }
            return .{ .current_node = node };
        }
        pub fn prev(itm: Index, self: *FsTree2) ?Index {
            _ = self;
            if (itm.current_node == null) return null;
            const parent = itm.current_node.?.parent orelse return null;
            if (itm.current_node.?.child_index == 0) return .{ .current_node = parent };
            if (!parent.opened) return .{ .current_node = parent }; // weird state
            const prev_index = itm.current_node.?.child_index - 1;
            if (prev_index >= parent.children_owned.len) return .{ .current_node = parent }; // child index out of range
            var lastchild = parent.children_owned[prev_index];
            while (lastchild.opened and lastchild.children_owned.len > 0) {
                lastchild = lastchild.children_owned[lastchild.children_owned.len - 1];
            }
            return .{ .current_node = lastchild };
        }
        pub fn next(itm: Index, self: *FsTree2) ?Index {
            _ = self;
            if (itm.current_node == null) return null;
            if (itm.current_node.?.opened) {
                const children = itm.current_node.?.children_owned;
                if (children.len > 0) return .{ .current_node = children[0] };
            }
            var current = itm.current_node.?;
            while (true) {
                const parent = current.parent orelse return null;
                if (!parent.opened) return .{ .current_node = parent }; // weird state
                const next_index = std.math.add(usize, current.child_index, 1) catch return .{ .current_node = parent };
                if (next_index < parent.children_owned.len) return .{ .current_node = parent.children_owned[next_index] };
                current = parent;
            }
        }
    };

    pub fn init(root_dir: []const u8, gpa: std.mem.Allocator) FsTree2 {
        return .{
            .root_dir_owned = gpa.dupe(u8, root_dir) catch @panic("oom"),
            .root_node = null,
            .node_pool = .init(gpa),
            .all_nodes = .init(gpa),
            .deleted_nodes = .init(gpa),
        };
    }
    pub fn deinit(self: *FsTree2) void {
        self.all_nodes.allocator.free(self.root_dir_owned);
        for (self.all_nodes.items) |node| node.deinit(self.all_nodes.allocator);
        self.all_nodes.deinit();
        self.deleted_nodes.deinit();
        self.node_pool.deinit();
    }

    pub fn createRootNode(self: *FsTree2) void {
        self.root_node = self._addNode(.{
            .basename_owned = self.all_nodes.allocator.dupe(u8, ".") catch @panic("oom"),
            .node_type = .dir,
            .parent = null,
            .opened = false,
            .children_owned = &.{},
            .is_deleted = false,
            .indent_level = 0,
            .child_index = 0,
        });
    }

    pub fn getPath(self: *FsTree2, dir: *Node, result: *std.array_list.Managed(u8)) void {
        if (dir.parent) |parent| {
            self.getPath(parent, result);
        } else {
            result.appendSlice(self.root_dir_owned) catch @panic("oom");
        }
        result.appendSlice("/") catch @panic("oom");
        result.appendSlice(dir.basename_owned) catch @panic("oom");
    }
    fn binarySearchCompareFn(ctx: []const u8, t: *Node) std.math.Order {
        return std.mem.order(u8, ctx, t.basename_owned);
    }
    pub fn expand(self: *FsTree2, dir: *Node) !void {
        if (dir.opened) return;

        var whole_path = std.array_list.Managed(u8).init(self.all_nodes.allocator);
        defer whole_path.deinit();
        self.getPath(dir, &whole_path);

        var res_children = std.array_list.Managed(*Node).init(self.all_nodes.allocator);
        defer res_children.deinit();
        errdefer for (res_children.items) |item| self._removeNode(item);

        var dirent = try std.fs.cwd().openDir(whole_path.items, .{ .iterate = true });
        defer dirent.close();
        var iter = dirent.iterateAssumeFirstIteration();
        while (try iter.next()) |entry| {
            const prev_entry_idx_opt = std.sort.binarySearch(*Node, dir.children_owned, entry.name, binarySearchCompareFn);
            const newnode = if (prev_entry_idx_opt) |idx| dir.children_owned[idx] else self._addNode(.{
                .basename_owned = self.all_nodes.allocator.dupe(u8, entry.name) catch @panic("oom"),
                .child_index = std.math.maxInt(usize),
                .node_type = switch (entry.kind) {
                    .directory => .dir,
                    .file => .file,
                    else => .other,
                },
                .parent = dir,
                .children_owned = &.{},
                .opened = false,
                .is_deleted = false,
                .indent_level = dir.indent_level + 1,
            });
            if (prev_entry_idx_opt != null) newnode.is_deleted = true; // HACK: mark "is_deleted". the flag will be removed later.
            res_children.append(newnode) catch @panic("oom");
        }

        // sort
        std.mem.sort(*Node, res_children.items, self, Node_lessThanFn);
        // fill indices
        for (res_children.items, 0..) |v, i| v.child_index = i;

        for (dir.children_owned) |prev_ch| {
            if (!prev_ch.is_deleted) {
                self._removeNode(prev_ch);
            }
            prev_ch.is_deleted = false;
        }
        self.all_nodes.allocator.free(dir.children_owned);
        dir.children_owned = res_children.toOwnedSlice() catch @panic("oom");
        dir.opened = true;
    }
    fn Node_lessThanFn(_: *FsTree2, a: *Node, b: *Node) bool {
        if (a.node_type == .dir and b.node_type != .dir) return true; // dirs go first
        if (b.node_type == .dir and a.node_type != .dir) return false;
        return std.mem.order(u8, a.basename_owned, b.basename_owned) == .lt;
    }
    fn Node_orderOnly(_: *FsTree2, a: *Node, b: *Node) bool {
        return std.mem.order(u8, a.basename_owned, b.basename_owned) == .lt;
    }

    pub fn contract(self: *FsTree2, dir: *Node) void {
        return self._contract(dir, dir);
    }
    fn _contract(self: *FsTree2, dir: *Node, setparent: *Node) void {
        // setparent is just so large trees can exit instantly and have less chance of jumping to a
        // newly overwritten node.
        if (!dir.opened) return;
        dir.opened = false;
        var new_children: std.array_list.Managed(*Node) = .init(self.all_nodes.allocator);
        defer new_children.deinit();
        for (dir.children_owned) |child| {
            if (child.opened) {
                new_children.append(child) catch @panic("oom");
            } else {
                self._contract(child, setparent);
                child.parent = setparent;
                self._removeNode(child);
            }
        }
        std.mem.sort(*Node, new_children.items, self, Node_orderOnly); // must be std.mem.order sorted
        self.all_nodes.allocator.free(dir.children_owned);
        dir.children_owned = new_children.toOwnedSlice() catch @panic("oom");
    }

    fn _addNode(self: *FsTree2, value: Node) *Node {
        std.debug.assert(!value.is_deleted);
        if (self.deleted_nodes.items.len > 0) {
            const res = self.deleted_nodes.pop().?;
            res.deinit(self.all_nodes.allocator);
            res.* = value;
            return res;
        }
        const new_node = self.node_pool.allocator().create(Node) catch @panic("oom");
        new_node.* = value;
        self.all_nodes.append(new_node) catch @panic("oom");
        return new_node;
    }
    fn _removeNode(self: *FsTree2, value: *Node) void {
        std.debug.assert(!value.is_deleted);
        value.is_deleted = true;
        value.child_index = std.math.maxInt(usize);
        self.deleted_nodes.append(value) catch @panic("oom");
    }
};
