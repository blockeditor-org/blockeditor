const std = @import("std");
const blocks_mod = @import("blocks");
const db_mod = blocks_mod.blockdb;
const bi = blocks_mod.blockinterface2;
const util = @import("anywhere").util;
const draw_lists = Beui.draw_lists;
const Beui = @import("Beui.zig");
const tracy = @import("anywhere").tracy;
const zgui = @import("anywhere").zgui;
const LayoutCache = @import("LayoutCache.zig");
const B2 = Beui.beui_experiment;

const ft = Beui.font_experiment.ft;
const hb = Beui.font_experiment.hb;
const sb = Beui.font_experiment.sb;

pub const Core = @import("texteditor").Core;
const EditorView = @This();

gpa: std.mem.Allocator,
core: Core,
selecting: bool = false,
_layout_temp_al: std.array_list.Managed(u8),
mouse_info: struct {
    mouse_pos: @Vector(2, f32) = .{ -10, -10 },
    mouse_left_pressed_down_this_frame: bool = false,
    mouse_left_held: bool = false,
} = .{},

config: struct {
    syntax_highlighting: bool = true,
} = .{},

const ScrollIndex = struct {
    is_first_line: enum(u64) { no, yes, _ },
    line_before_this_line: Core.Position,

    pub fn first(_: *EditorView) ScrollIndex {
        return .{ .is_first_line = .yes, .line_before_this_line = .end };
    }
    pub fn update(itm: ScrollIndex, _: *EditorView) ?ScrollIndex {
        return itm; // nothing to update really. we could positionFromDocbyte(docbyteFromPosition()) or getLineStart() but does it matter?
    }
    pub fn prev(itm: ScrollIndex, self: *EditorView) ?ScrollIndex {
        const block = self.core.document.value;

        if (itm.is_first_line == .yes) return null;
        const prev_line = self.core.getPrevLineStart(itm.line_before_this_line);
        if (block.docbyteFromPosition(prev_line) == block.docbyteFromPosition(itm.line_before_this_line)) {
            return .{ .is_first_line = .yes, .line_before_this_line = .end };
        }
        return .{ .is_first_line = .no, .line_before_this_line = prev_line };
    }
    pub fn next(itm: ScrollIndex, self: *EditorView) ?ScrollIndex {
        const block = self.core.document.value;
        const next_line = itm.thisLine(self);
        if (block.docbyteFromPosition(next_line) == block.docbyteFromPosition(self.core.getLineStart(block.positionFromDocbyte(block.length())))) {
            return null;
        }
        return .{ .is_first_line = .no, .line_before_this_line = next_line };
    }
    pub fn parentSticky(itm: ScrollIndex, self: *EditorView) ?ScrollIndex {
        // make the first two lines sticky (assuming the second line is 28 long)
        // TODO: use tree-sitter or indentation to determine which lines should actually be sticky
        const block = self.core.document.value;

        if (itm.is_first_line == .yes) return null;
        const docbyte = block.docbyteFromPosition(itm.line_before_this_line);
        if (docbyte == 0) return first(self);
        return .{ .is_first_line = .no, .line_before_this_line = block.positionFromDocbyte(0) };
    }

    /// returns the start docbyte of the line to render
    fn thisLine(itm: ScrollIndex, self: *EditorView) Core.Position {
        if (itm.is_first_line == .no) {
            return self.core.getNextLineStart(itm.line_before_this_line);
        } else {
            return self.core.document.value.positionFromDocbyte(0);
        }
    }
};

pub fn initFromDoc(self: *EditorView, gpa: std.mem.Allocator, document: db_mod.TypedComponentRef(bi.text_component.TextDocument)) void {
    self.* = .{
        .gpa = gpa,
        .core = undefined,
        ._layout_temp_al = .init(gpa),
    };
    self.core.initFromDoc(gpa, document);
}
pub fn deinit(self: *EditorView) void {
    self._layout_temp_al.deinit();
    self.core.deinit();
}

fn layoutLine(self: *EditorView, b2: *B2.Beui2, layout_cache: *LayoutCache, line_middle: Core.Position) LayoutCache.LayoutInfo {
    const tctx = tracy.trace(@src());
    defer tctx.end();

    std.debug.assert(self._layout_temp_al.items.len == 0);
    defer self._layout_temp_al.clearRetainingCapacity();

    const line_start = self.core.getLineStart(line_middle);
    const line_end = self.core.getNextLineStart(line_start); // includes the '\n' character because that shows up in invisibles selection
    const line_start_docbyte = self.core.document.value.docbyteFromPosition(line_start);
    const line_len = self.core.document.value.docbyteFromPosition(line_end) - line_start_docbyte;

    {
        const tctx_ = tracy.traceNamed(@src(), "readSlice");
        defer tctx_.end();
        self.core.document.value.readSlice(line_start, self._layout_temp_al.addManyAsSlice(@intCast(line_len)) catch @panic("oom"));
    }

    return layout_cache.layoutLine(b2, self._layout_temp_al.items);
}

pub fn gui(self: *EditorView, call_info: B2.StandardCallInfo, beui: *Beui) B2.StandardChild {
    const tctx = tracy.trace(@src());
    defer tctx.end();

    const ui = call_info.ui(@src());
    const b2 = ui.id.b2;
    const layout_cache = &b2.persistent.layout_cache;
    const rdl = b2.draw();

    const content_region_size: @Vector(2, f32) = .{ call_info.constraints.available_size.w.?, call_info.constraints.available_size.h.? };

    const block = self.core.document.value;

    if (beui.hotkey(.{ .alt = .maybe, .ctrl_or_cmd = .maybe, .shift = .maybe }, &.{ .left, .right })) |hk| {
        self.core.executeCommand(.{ .move_cursor_left_right = .{
            .direction = switch (hk.key) {
                .left => .left,
                .right => .right,
            },
            .stop = switch (hk.alt or hk.ctrl_or_cmd) {
                false => .unicode_grapheme_cluster,
                true => .word,
            },
            .mode = switch (hk.shift) {
                false => .move,
                true => .select,
            },
        } });
    }
    if (beui.hotkey(.{ .shift = .maybe }, &.{ .home, .end })) |hk| {
        // maybe should be .move_cursor_to_line_side
        self.core.executeCommand(.{ .move_cursor_left_right = .{
            .direction = switch (hk.key) {
                .home => .left,
                .end => .right,
            },
            .stop = .line,
            .mode = switch (hk.shift) {
                false => .move,
                true => .select,
            },
        } });
    }
    if (beui.hotkey(.{ .alt = .maybe, .ctrl_or_cmd = .maybe }, &.{ .backspace, .delete })) |hk| {
        self.core.executeCommand(.{ .delete = .{
            .direction = switch (hk.key) {
                .backspace => .left,
                .delete => .right,
            },
            .stop = switch (hk.alt or hk.ctrl_or_cmd) {
                false => .unicode_grapheme_cluster,
                true => .word,
            },
        } });
    }
    if (beui.hotkey(.{ .alt = .yes }, &.{ .down, .up })) |hk| {
        self.core.executeCommand(.{ .ts_select_node = .{
            .direction = switch (hk.key) {
                .down => .child,
                .up => .parent,
            },
        } });
    }
    if (beui.hotkey(.{ .shift = .maybe }, &.{ .down, .up })) |hk| {
        self.core.executeCommand(.{ .move_cursor_up_down = .{
            .direction = switch (hk.key) {
                .down => .down,
                .up => .up,
            },
            .metric = .byte,
            .stop = .unicode_grapheme_cluster,
            .mode = switch (hk.shift) {
                false => .move,
                true => .select,
            },
        } });
    }
    if (beui.hotkey(.{ .alt = .yes, .ctrl_or_cmd = .yes }, &.{ .down, .up })) |hk| {
        self.core.executeCommand(.{ .move_cursor_up_down = .{
            .direction = switch (hk.key) {
                .down => .down,
                .up => .up,
            },
            .metric = .byte,
            .stop = .unicode_grapheme_cluster,
            .mode = .duplicate,
        } });
    }
    if (beui.hotkey(.{}, &.{.enter})) |_| {
        self.core.executeCommand(.newline);
    }
    if (beui.hotkey(.{ .ctrl_or_cmd = .yes, .shift = .maybe }, &.{.enter})) |hk| {
        self.core.executeCommand(.{ .insert_line = .{
            .direction = switch (hk.shift) {
                false => .down,
                true => .up,
            },
        } });
    }
    if (beui.hotkey(.{ .shift = .maybe }, &.{.tab})) |hk| {
        self.core.executeCommand(.{ .indent_selection = .{
            .direction = switch (hk.shift) {
                false => .right,
                true => .left,
            },
        } });
    }
    if (beui.hotkey(.{ .ctrl_or_cmd = .yes }, &.{.a})) |_| {
        self.core.executeCommand(.select_all);
    }
    if (beui.hotkey(.{ .ctrl_or_cmd = .yes, .shift = .maybe }, &.{.z})) |hk| {
        self.core.executeCommand(switch (hk.shift) {
            false => .undo,
            true => .redo,
        });
    }
    if (beui.hotkey(.{ .ctrl_or_cmd = .yes }, &.{.y})) |_| {
        self.core.executeCommand(.redo);
    }
    if (beui.hotkey(.{ .ctrl_or_cmd = .yes, .shift = .yes }, &.{.d})) |_| {
        self.core.executeCommand(.{ .duplicate_line = .{ .direction = .down } });
    }
    if (beui.hotkey(.{ .ctrl_or_cmd = .yes }, &.{ .x, .c })) |hk| {
        var copy_txt = std.array_list.Managed(u8).init(self.gpa);
        defer copy_txt.deinit();
        self.core.copyArrayListUtf8(&copy_txt, switch (hk.key) {
            .x => .cut,
            .c => .copy,
        });
        copy_txt.append('\x00') catch @panic("oom");
        beui.setClipboard(copy_txt.items[0 .. copy_txt.items.len - 1 :0]);
    }
    if (beui.hotkey(.{ .ctrl_or_cmd = .yes }, &.{.v})) |_| {
        var paste_txt = std.array_list.Managed(u8).init(self.gpa);
        defer paste_txt.deinit();
        beui.getClipboard(&paste_txt);
        self.core.executeCommand(.{ .paste = .{ .text = paste_txt.items } });
    }

    // if(beui.uncommittedTextInput()) |text| // on android, this text doesn't even have to be at the position of the cursor
    if (beui.textInput()) |text| {
        self.core.executeCommand(.{ .insert_text = .{ .text = text } });
    }

    const user_state_id = ui.id.sub(@src());
    const last_frame_state = b2.getPrevFrameDrawListState(user_state_id);

    const click_info = &self.mouse_info;

    var click_target: ?Core.Position = null;
    // ok this is complicated
    // here's an alternative:
    // for each line, put a y top, y bottom
    //   within the line, for each char put an x left and x right
    // now, sort these both and find the nearest to the mouse cursor
    // that way clicking halfway through works, last char works, top and bottom
    // select works implicitly, ...
    if (last_frame_state) |lfs| {
        const data = lfs.cast(std.array_list.Managed(B2.ID));
        for (data.items, 0..) |item, j| {
            const line_state = b2.getPrevFrameDrawListState(item).?; // it was posted last frame and we know because it's in the arraylist.
            const offset = line_state.offset_from_screen_ul - lfs.offset_from_screen_ul;
            const lps = line_state.cast(LinePostedState);

            if ((j != 0 and click_info.mouse_pos[1] < offset[1]) or (j != data.items.len - 1 and click_info.mouse_pos[1] >= offset[1] + lps.line_height)) {
                continue; // not this line
            }
            for (lps.chars, 0..) |char_itm, i| {
                if (char_itm.isNull()) continue;
                if (i == 0 or @reduce(.And, click_info.mouse_pos >= offset + char_itm.char_up_left_offset) or (j == 0 and click_info.mouse_pos[0] >= offset[0] + char_itm.char_up_left_offset[0])) {
                    click_target = char_itm.char_position;
                }
            }
        }
    }

    // have each line post state:
    // - array of: [x offset, docbyte]
    // and have each line add its id to an arraylist that goes into the user state so we can iterate over all the lines
    // that were rendered last frame

    // TODO:
    // - figure out which docbyte was clicked *last frame*
    // - update cursor positions before the getCursorPositions call below for 0 frame delay

    if (click_target) |clicked_pos| {
        // TODO: ask core to give two positions:
        // - return the next left stop (allowing the current char)
        // - return the next right stop
        // then, get the x positions of these two chars. use the one that is closest to
        // the mouse x position.
        // - maybe we'll have to move 'click' and 'drag' back out of executeCommand so
        //   they can tell us the info they need

        const shift_held = beui.isKeyHeld(.left_shift) or beui.isKeyHeld(.right_shift);
        const alt_held = (beui.isKeyHeld(.left_alt) or beui.isKeyHeld(.right_alt)) != (beui.isKeyHeld(.left_control) or beui.isKeyHeld(.right_control));

        // if we're going to support ctrl+left click to jump to definition, then maybe select ts node needs to be on ctrl right click

        // we would like:
        // - alt click -> jump to defintion
        // - ctrl click -> add multi cursor
        //   - dragging this should select with the just-added multicursor. onDrag isn't set up for that yet, but we'll fix it
        //   - ideally if you drag over a previous cursor and drag back, it won't eat up the previous cursor. but vscode does eat it
        //     so we can eat it too for now
        // - some kind of click -> select ts node
        //   - ideally you can both add multi cursor and select ts node, so if it's alt right click then you should be able to
        //     hold ctrl and the new multicursor you're adding with select_ts_node true
        // - these conflict on mac. that's why vscode has different buttons for these two on mac, windows, and linux. you can
        //   never learn the right buttons

        if (click_info.mouse_left_pressed_down_this_frame) {
            const mode: ?Core.DragSelectionMode = switch (beui.leftMouseClickedCount()) {
                1 => .{ .stop = .unicode_grapheme_cluster, .select = false },
                2 => .{ .stop = .word, .select = true },
                3 => .{ .stop = .line, .select = true },
                else => null,
            };
            if (mode) |sel_mode| {
                self.core.executeCommand(.{ .click = .{
                    .pos = clicked_pos,
                    .mode = sel_mode,
                    .extend = shift_held,
                    .select_ts_node = alt_held,
                } });
            } else {
                self.core.executeCommand(.select_all);
            }
            self.selecting = true;
        } else if (self.selecting and click_info.mouse_left_held) {
            self.core.executeCommand(.{ .drag = .{ .pos = clicked_pos } });
        }
    }
    if (!beui.isKeyHeld(.mouse_left)) {
        self.selecting = false;
    }

    //
    // Render. No more mutation after this point to preserve frame-perfect-ness.
    //

    var cursor_positions = self.core.getCursorPositions();
    defer cursor_positions.deinit();

    var syn_hl = self.core.highlight();
    defer syn_hl.deinit();

    const posted_state_ids_al = b2.frame.arena.create(std.array_list.Managed(B2.ID)) catch @panic("oom");
    posted_state_ids_al.* = .init(b2.frame.arena);

    var ctx = GuiRenderLineCtx{
        .self = self,
        .beui = beui,
        .cursor_positions = &cursor_positions,
        .posted_state_ids = posted_state_ids_al,
        .syn_hl = &syn_hl,
        .replace = .{
            .space = layout_cache.font.ft_face.getCharIndex('·') orelse layout_cache.font.ft_face.getCharIndex('_'),
            .tab = layout_cache.font.ft_face.getCharIndex('⇥') orelse layout_cache.font.ft_face.getCharIndex('→') orelse layout_cache.font.ft_face.getCharIndex('>'),
            .newline = layout_cache.font.ft_face.getCharIndex('⏎') orelse layout_cache.font.ft_face.getCharIndex('␊') orelse layout_cache.font.ft_face.getCharIndex('\\'),
            .cr = layout_cache.font.ft_face.getCharIndex('␍') orelse layout_cache.font.ft_face.getCharIndex('<'),
        },
    };
    const res = B2.virtualScroller(ui.sub(@src()), self, ScrollIndex, .from(&ctx, gui_renderLine));

    if (zgui.beginWindow("Editor Debug", .{})) {
        defer zgui.endWindow();

        zgui.text("click_target: {?d}", .{click_target});

        if (last_frame_state) |lss| zgui.text("last_frame_state: {d}", .{lss.offset_from_screen_ul});

        zgui.checkbox("Syntax Highlighting", &self.config.syntax_highlighting);

        for (self.core.cursor_positions.items) |cursor| {
            const lyncol = block.lynColFromPosition(cursor.pos.focus);
            zgui.text("current pos: Ln {d}, Col {d}", .{ lyncol.lyn + 1, lyncol.col + 1 });
        }
    }

    if (zgui.beginWindow("Tree Sitter Info", .{})) {
        defer zgui.endWindow();

        for (self.core.cursor_positions.items) |cursor_pos| {
            const range = self.core.selectionToPosLen(cursor_pos.pos);
            if (self.core.syn_hl_ctx) |*c| c.guiInspectNodeUnderCursor(range.left_docbyte, range.right_docbyte);
        }
    }

    // background
    rdl.place(res.rdl, .{});
    rdl.addRect(.{ .pos = .{ 0, 0 }, .size = content_region_size, .tint = DefaultTheme.editor_bg, .rounding = .{ .corners = .all, .radius = 6.0 } });
    rdl.addMouseEventCapture2(ui.id.sub(@src()), .{ 0, 0 }, content_region_size, .{
        .buttons = .left,
        .onMouseEvent = .from(self, handleMouseEvent),
    });
    self.mouse_info.mouse_left_pressed_down_this_frame = false;
    rdl.addUserState(user_state_id, std.array_list.Managed(B2.ID), posted_state_ids_al);
    return .{ .rdl = rdl, .size = content_region_size };
}

fn handleMouseEvent(self: *EditorView, b2: *B2.Beui2, mev: B2.MouseEvent) ?Beui.Cursor {
    // TODO: handle the click in the event handler
    self.mouse_info.mouse_pos = (mev.pos orelse @Vector(2, f32){ -10, -10 }) - mev.capture_pos;
    if (mev.action == .down) {
        self.mouse_info.mouse_left_pressed_down_this_frame = true;
        self.mouse_info.mouse_left_held = true;
    }
    if (mev.action == .up) {
        self.mouse_info.mouse_left_held = false;
    }
    _ = b2;
    return .text_input;
}

const LineCharState = struct {
    const null_offset: @Vector(2, f32) = .{ std.math.nan(f32), std.math.nan(f32) };
    char_up_left_offset: @Vector(2, f32),
    height: f32,
    char_position: Core.Position,
    fn isNull(self: LineCharState) bool {
        return std.math.isNan(self.char_up_left_offset[0]);
    }
};
const LinePostedState = struct {
    chars: []const LineCharState,
    line_height: f32,
};

const GuiRenderLineCtx = struct {
    self: *EditorView,
    beui: *Beui,
    cursor_positions: *Core.CursorPositions,
    syn_hl: *Core.Highlighter.TreeSitterSyntaxHighlighter,
    posted_state_ids: *std.array_list.Managed(B2.ID),
    replace: struct {
        space: ?u32,
        tab: ?u32,
        newline: ?u32,
        cr: ?u32,
    },
};
fn gui_renderLine(ctx: *GuiRenderLineCtx, call_info: B2.StandardCallInfo, index: ScrollIndex) B2.StandardChild {
    const tctx = tracy.traceNamed(@src(), "handle line");
    defer tctx.end();
    const ui = call_info.ui(@src());

    const self = ctx.self;
    const block = self.core.document.value;
    const layout_cache = &ui.id.b2.persistent.layout_cache;

    const text_bg_rdl = ui.id.b2.draw();
    const text_rdl = ui.id.b2.draw();
    const text_cursor_rdl = ui.id.b2.draw();
    text_bg_rdl.place(text_cursor_rdl, .{});
    text_bg_rdl.place(text_rdl, .{});

    const line_to_render = index.thisLine(self);

    // line breaking:
    // - we can do a pre-pass looping over the line. add up the width. if it gets greater than the
    //   maximum container width, append to the break points array the first valid text break point
    //   to the left of the current item.
    //   - if the first valid break point is very far away (>x pixels), just break right here.
    //   - we can have precedence. break at word (preferred). break at glyph (acceptable). break anywhere (:/)
    // - then, when rendering, we know where to break at without having to do any backtracking. it's still
    //   O(n) but now it's O(2n) because we loop twice.

    const layout_test = self.layoutLine(ui.id.b2, layout_cache, line_to_render);
    const line_start_docbyte = block.docbyteFromPosition(line_to_render);
    const rendered_area_end_docbyte = block.docbyteFromPosition(self.core.getNextLineStart(line_to_render));
    const rendered_area_len = rendered_area_end_docbyte - line_start_docbyte;

    const line_state = ui.id.b2.frame.arena.alloc(LineCharState, @intCast(rendered_area_len)) catch @panic("oom");
    for (line_state) |*ls| ls.* = .{ .char_up_left_offset = LineCharState.null_offset, .height = 0, .char_position = .end };

    var cursor_pos: @Vector(2, f32) = .{ B2.Theme.window_padding, 0 };
    var length_with_no_selection_render: f32 = 0.0;
    for (layout_test.items, 0..) |item, i| {
        const tctx_ = tracy.traceNamed(@src(), "handle char");
        defer tctx_.end();
        // eventually, we would like to make this a beui.renderText() call, with spans specifying color zones and font changes
        // then, renderText can completely cache the drawn vertices and append them as long as nothing changed since last frame
        // - if the text changes, have to re-layout and rerender
        // - if the glyphs image gets rewritten, have to rerender because the uvs will all be wrong
        // so the only thing we have to do here is call tree sitter fns to assemble an arraylist of zones. and we don't even have to
        // query each byte anymore, we have to set up some kind of iterator within the line zone.

        const item_docbyte = line_start_docbyte + item.docbyte_offset_from_layout_line_start;
        const next_glyph_docbyte: u64 = if (i + 1 >= layout_test.items.len) item_docbyte + 1 else line_start_docbyte + layout_test.items[i + 1].docbyte_offset_from_layout_line_start;
        const len = next_glyph_docbyte - item_docbyte;
        if (next_glyph_docbyte == item_docbyte) {
            length_with_no_selection_render += item.advance[0];
        } else {
            length_with_no_selection_render = 0;
        }
        const single_char: u8 = if (len == 1) blk: {
            break :blk block.read(block.positionFromDocbyte(item_docbyte))[0];
        } else '?';
        const replace_invisible_glyph_id: ?u32 = switch (single_char) {
            '\n' => ctx.replace.newline,
            '\r' => ctx.replace.cr,
            ' ' => ctx.replace.space,
            '\t' => ctx.replace.tab,
            else => null,
        };
        const start_docbyte_selected = ctx.cursor_positions.advanceAndRead(item_docbyte).selected;
        const item_offset = @round(item.offset);

        if (replace_invisible_glyph_id) |invis_glyph| {
            // TODO: also show invisibles for trailing whitespace
            // ^ we can precalculate the number of bytes of trailing whitespace and count a glyph
            //    to show as invisible if its byte is within the trailing whitespace bytes
            if (start_docbyte_selected) {
                const tint = DefaultTheme.synHlColor(.invisible);

                const invis_glyph_info = layout_cache.renderGlyph(ui.id.b2, invis_glyph, layout_test.height);
                if (invis_glyph_info.region) |region| {
                    const glyph_size: @Vector(2, f32) = @floatFromInt(invis_glyph_info.size);
                    const glyph_offset: @Vector(2, f32) = invis_glyph_info.offset;

                    text_rdl.addRegion(.{
                        .pos = cursor_pos + item_offset + glyph_offset,
                        .size = glyph_size,
                        .region = region,
                        .image = .grayscale,
                        .image_size = LayoutCache.getGlyphs(ui.id.b2).texpack.size,
                        .tint = tint,
                    });
                }
            }
        } else {
            const glyph_info = layout_cache.renderGlyph(ui.id.b2, item.glyph_id, layout_test.height);
            if (glyph_info.region) |region| {
                const glyph_size: @Vector(2, f32) = @floatFromInt(glyph_info.size);
                const glyph_offset: @Vector(2, f32) = glyph_info.offset;

                const tint: Core.Highlighter.SynHlColorScope = switch (self.config.syntax_highlighting) {
                    true => ctx.syn_hl.advanceAndRead(@intCast(item_docbyte)),
                    false => .unstyled,
                };
                text_rdl.addRegion(.{
                    .pos = cursor_pos + item_offset + glyph_offset,
                    .size = glyph_size,
                    .region = region,
                    .image = .grayscale,
                    .image_size = LayoutCache.getGlyphs(ui.id.b2).texpack.size,
                    .tint = DefaultTheme.synHlColor(tint),
                });
            }
        }

        const total_width: f32 = length_with_no_selection_render + item.advance[0];
        // "…" is composed of "\xE2\x80\xA6" - this means it has three valid cursor positions (when moving with .byte). Include them all.
        for (0..@intCast(len)) |docbyte_offset| {
            const docbyte = item_docbyte + docbyte_offset;
            const cursor_info = ctx.cursor_positions.advanceAndRead(docbyte);

            const portion = @floor(@as(f32, @floatFromInt(docbyte_offset)) / @as(f32, @floatFromInt(len)) * total_width);
            const portion_next = @floor(@as(f32, @floatFromInt(docbyte_offset + 1)) / @as(f32, @floatFromInt(len)) * total_width);
            const portion_width = portion_next - portion;

            if (cursor_info.left_cursor == .focus) {
                text_cursor_rdl.addRect(.{
                    .pos = @floor(cursor_pos + @Vector(2, f32){ -length_with_no_selection_render + portion, -1 }),
                    .size = .{ 2, layout_test.height },
                    .tint = DefaultTheme.cursor_color,
                });
            }
            if (cursor_info.selected) {
                text_bg_rdl.addRect(.{
                    .pos = @floor(cursor_pos + @Vector(2, f32){ -length_with_no_selection_render + portion, 0 }),
                    .size = .{ portion_width, layout_test.height },
                    .tint = DefaultTheme.selection_color,
                });
            }

            line_state[@intCast(docbyte - line_start_docbyte)] = .{
                .char_up_left_offset = @floor(cursor_pos + @Vector(2, f32){ -length_with_no_selection_render + portion + 1, 0 }),
                .height = layout_test.height,
                .char_position = block.positionFromDocbyte(docbyte),
            };
        }

        cursor_pos += item.advance;
        cursor_pos = @floor(cursor_pos);
    }

    const res_height = layout_test.height + cursor_pos[1];

    const rs_id = ui.id.sub(@src());
    const lps = ui.id.b2.frame.arena.create(LinePostedState) catch @panic("oom");
    lps.* = .{ .chars = line_state, .line_height = res_height };
    text_bg_rdl.addUserState(rs_id, LinePostedState, lps);
    ctx.posted_state_ids.append(rs_id) catch @panic("oom");

    return .{ .size = .{ cursor_pos[0], res_height }, .rdl = text_bg_rdl };
}

const DefaultTheme = struct {
    // colors are defined in srgb
    // we can make this a simple json file with {"editor_bg": "#mycolor"}
    pub const editor_bg: Beui.Color = .fromHexRgb(0x1d252c);
    pub const selection_color: Beui.Color = .fromHexRgb(0x28323a);
    pub const cursor_color: Beui.Color = .fromHexRgb(0x5EC4FF);

    pub fn synHlColor(syn_hl_color: Core.Highlighter.SynHlColorScope) Beui.Color {
        return .fromHexRgb(switch (syn_hl_color) {
            .invalid => 0xFF0000,

            .keyword_storage => 0x008B94,
            .literal => 0xe27e8d,
            .variable_function => 0x70e1e8,
            .punctuation_important => 0xb7c5d3,
            .variable => 0x718ca1,
            .variable_parameter => 0xEBBF83,
            .literal_string => 0x68a1f0,
            .keyword_primitive_type => 0x70e1e8,
            .punctuation => 0x718ca1,
            .keyword => 0x5ec4ff,
            .variable_constant => 0x8BD49C,
            .variable_mutable => 0xB7C5D3,
            .comment => 0xff9d1c,
            .markdown_plain_text => 0xFFFFFF,

            .unstyled => 0xB7C5D3,
            .invisible => 0x43515c,
        });
    }
};

// CLIPBOARD:
// https://github.com/microsoft/vscode/blob/faf7a5c748720c4f7962f462de058da4c12b54f5/src/vs/editor/browser/controller/editContext/native/nativeEditContext.ts#L370
// - vscode stores clipboard metadata and writes text to the clipboard
// - vscode copies as an array of lines
// - we could copy a block with text fallback, or we could copy text and store a lines array somewhere and only use it if the hash matches.
// - we'll want to copy blocks eventually but it doesn't have to be now.
// copy with glfw_window.clipboard something
