//! text editing core that is mostly agnostic to the visual editor

const std = @import("std");
const blocks_mod = @import("blocks");
const seg_dep = @import("grapheme_cursor");
const db_mod = blocks_mod.blockdb;
const bi = blocks_mod.blockinterface2;
const anywhere = @import("anywhere");
const util = @import("anywhere").util;
const diffz = @import("diffz");
pub const Highlighter = @import("Highlighter.zig");
pub const highlighters_zig = @import("highlighters/zig.zig");
pub const highlighters_markdown = @import("highlighters/markdown.zig");
const ts = @import("tree_sitter");

const Core = @This();

gpa: std.mem.Allocator,
document: db_mod.TypedComponentRef(bi.text_component.TextDocument),
syn_hl_ctx: ?Highlighter,
clipboard_cache: ?struct {
    /// owned by self.gpa
    contents: []const []const u8,
    /// true only if every line copied had selection .len == 0
    paste_in_new_line: bool,
    /// Wyhash of copied string
    copied_str_hash: u64,
    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        for (self.contents) |line| gpa.free(line);
        gpa.free(self.contents);
    }
},
undo: TextStack,
undo_tokens: std.array_list.Managed(UndoTokenValue),
redo: TextStack,
redo_tokens: std.array_list.Managed(UndoTokenValue),
last_undo_token_classification: UndoTokenClassification,

cursor_positions: std.array_list.Managed(CursorPosition),

config: EditorConfig = .{
    .indent_with = .{ .spaces = 4 },
    .count_soft_tab_as_grapheme_cluster = true,
},

/// refs document
pub fn initFromDoc(self: *Core, gpa: std.mem.Allocator, document: db_mod.TypedComponentRef(bi.text_component.TextDocument)) void {
    self.* = .{
        .gpa = gpa,
        .document = document,
        .syn_hl_ctx = null,
        .clipboard_cache = null,
        .undo = .init(gpa),
        .undo_tokens = .init(gpa),
        .redo = .init(gpa),
        .redo_tokens = .init(gpa),
        .last_undo_token_classification = .always_split,

        .cursor_positions = .init(gpa),
    };
    document.ref();
    document.addUpdateListener(util.Callback(bi.text_component.TextDocument.SimpleOperation, void).from(self, cb_onEdit)); // to keep the language server up to date

}
pub fn deinit(self: *Core) void {
    if (self.syn_hl_ctx) |*pv| pv.deinit();
    for (self.undo_tokens.items) |t| self.gpa.free(t.cursor_positions_clone_owned);
    self.undo_tokens.deinit();
    self.undo.deinit();
    for (self.redo_tokens.items) |t| self.gpa.free(t.cursor_positions_clone_owned);
    self.redo_tokens.deinit();
    self.redo.deinit();
    if (self.clipboard_cache) |*v| v.deinit(self.gpa);
    self.cursor_positions.deinit();
    self.document.removeUpdateListener(util.Callback(bi.text_component.TextDocument.SimpleOperation, void).from(self, cb_onEdit));
    self.document.unref();
}

fn cb_onEdit(self: *Core, edit: bi.text_component.TextDocument.SimpleOperation) void {
    // TODO: keep tree-sitter updated
    _ = self;
    _ = edit;
}

pub fn setSynHl(self: *Core, language: ?Highlighter.Language) void {
    if (self.syn_hl_ctx) |*pv| pv.deinit();

    if (language) |l| {
        self.syn_hl_ctx = undefined;
        self.syn_hl_ctx.?.init(self.document, l, self.gpa);
    } else {
        self.syn_hl_ctx = null;
    }
}
pub fn highlight(self: *Core) Highlighter.TreeSitterSyntaxHighlighter {
    if (self.syn_hl_ctx) |*v| return v.highlight();
    return .initPlaintext();
}

pub fn getLineStart(self: *Core, pos: Position) Position {
    const block = self.document.value;
    var lyncol = block.lynColFromPosition(pos);
    lyncol.col = 0;
    return block.positionFromLynCol(lyncol).?;
}
pub fn getPrevLineStart(self: *Core, pos: Position) Position {
    const block = self.document.value;
    var lyncol = block.lynColFromPosition(pos);
    lyncol.col = 0;
    if (lyncol.lyn > 0) lyncol.lyn -= 1;
    return block.positionFromLynCol(lyncol).?;
}
pub fn getThisLineEnd(self: *Core, prev_line_start: Position) Position {
    const block = self.document.value;
    const next_line_start = self.getNextLineStart(prev_line_start);
    const next_line_start_byte = block.docbyteFromPosition(next_line_start);
    const prev_line_start_byte = block.docbyteFromPosition(prev_line_start);

    if (prev_line_start_byte == next_line_start_byte) return prev_line_start;
    if (next_line_start_byte == block.length()) return block.positionFromDocbyte(next_line_start_byte);
    std.debug.assert(next_line_start_byte > prev_line_start_byte);
    return block.positionFromDocbyte(next_line_start_byte - 1);
}
pub fn getNextLineStartMaybeInsertNewline(self: *Core, token: ?UndoToken, pos: Position) Position {
    if (token != null and self.document.value.docbyteFromPosition(pos) == self.document.value.length()) {
        self.replaceRange(token.?, .{ .position = .end, .delete_len = 0, .insert_text = "\n" });
        return .end;
    }
    return self.getNextLineStart(pos);
}
pub fn getNextLineStart(self: *Core, prev_line: Position) Position {
    const block = self.document.value;
    var lyncol = block.lynColFromPosition(prev_line);
    lyncol.col = 0;
    lyncol.lyn += 1;
    return block.positionFromLynCol(lyncol) orelse {
        return .end;
    };
}
fn measureIndent(self: *Core, line_start_pos: Position) struct { indents: u64, chars: u64 } {
    var indent_segments: u64 = 0;
    var chars: u64 = 0;

    const block = self.document.value;
    var index: u64 = block.docbyteFromPosition(line_start_pos);
    const len = block.length();
    while (index < len) : (index += 1) {
        if (index >= len) continue; // to keep readSlice in bounds
        var byte: [1]u8 = undefined;
        block.readSlice(block.positionFromDocbyte(index), &byte);
        switch (byte[0]) {
            ' ' => indent_segments += 1,
            '\t' => indent_segments += self.config.indent_with.count(),
            else => break,
        }
        chars += 1;
    }

    return .{
        .indents = std.math.divCeil(u64, indent_segments, self.config.indent_with.count()) catch unreachable,
        .chars = chars,
    };
}

fn toWordBoundary(self: *Core, pos: Position, direction: LRDirection, stop: CursorLeftRightStop, mode: enum { left, right, select }, nomove: enum { must_move, may_move }) Position {
    const block = self.document.value;
    var docdoc = DocumentDocument{ .text_doc = block };
    const gendoc = docdoc.doc();

    const src_index = block.docbyteFromPosition(pos);
    var index: u64 = src_index;
    const len = block.length();
    while (switch (direction) {
        .left => index > 0,
        .right => index < len,
    }) : ({
        if (nomove == .may_move) switch (direction) {
            .left => index -= 1,
            .right => index += 1,
        };
    }) {
        if (nomove == .must_move) switch (direction) {
            .left => index -= 1,
            .right => index += 1,
        };
        if (index <= 0 or index >= len) break; // readSlice will go out of range
        const marker = hasStop(gendoc, index, stop, .{ .count_soft_tab_as_grapheme_cluster = if (self.config.count_soft_tab_as_grapheme_cluster and self.config.indent_with == .spaces) self.config.indent_with.spaces else 0 }) orelse continue;
        switch (mode) {
            .left => switch (marker) {
                .left_or_select, .both => break,
                .right_or_select, .right_only => {},
            },
            .right => switch (marker) {
                .right_or_select, .right_only, .both => break,
                .left_or_select => {},
            },
            .select => switch (marker) {
                .left_or_select, .right_or_select, .both => break,
                .right_only => {},
            },
        }
    }
    return block.positionFromDocbyte(index);
}

pub fn selectionToPosLen(self: *Core, selection: Selection) PosLen {
    const block = self.document.value;

    const bufbyte_1 = block.docbyteFromPosition(selection.anchor);
    const bufbyte_2 = block.docbyteFromPosition(selection.focus);

    const min = @min(bufbyte_1, bufbyte_2);
    const max = @max(bufbyte_1, bufbyte_2);

    return .{
        .pos = block.positionFromDocbyte(min),
        .left_docbyte = min,
        .right = block.positionFromDocbyte(max),
        .right_docbyte = max,
        .len = max - min,
        .is_right = min == bufbyte_1,
    };
}
pub fn normalizePosition(self: *Core, pos: Position) Position {
    const block = self.document.value;
    return block.positionFromDocbyte(block.docbyteFromPosition(pos));
}
/// makes sure cursors are:
/// - on live spans, not deleted ones `hello ` `5|` `world` -> `hello `5` `|world`
/// - not overlapping `he[llo[ wor|ld|` -> `he[llo world|`
/// - in left-to-right order ``
pub fn normalizeCursors(self: *Core) void {
    const tctx = anywhere.tracy.traceNamed(@src(), "Core.normalizeCursors");
    defer tctx.end();

    const block = self.document.value;

    var positions = self.getCursorPositions();
    defer positions.deinit();

    var uncommitted_start: ?u64 = null;

    const len_start = self.cursor_positions.items.len;
    self.cursor_positions.clearRetainingCapacity();
    for (positions.positions.items) |pos| {
        const prev_selected = positions.count > 0;
        if (positions.idx >= positions.positions.items.len) break;
        if (positions.positions.items[positions.idx].docbyte > pos.docbyte) continue;
        const sel_info = positions.advanceAndRead(pos.docbyte);
        const next_selected = sel_info.selected;

        var res_cursor = sel_info.left_cursor_extra.?;
        if (prev_selected and next_selected) {
            // don't put a cursor
            continue;
        } else if (!prev_selected and next_selected) {
            uncommitted_start = pos.docbyte;
        } else if (prev_selected and !next_selected) {
            // commit
            std.debug.assert(uncommitted_start != null);
            if (sel_info.left_cursor == .focus) {
                res_cursor.pos = .range(
                    block.positionFromDocbyte(uncommitted_start.?),
                    block.positionFromDocbyte(pos.docbyte),
                );
            } else {
                res_cursor.pos = .range(
                    block.positionFromDocbyte(pos.docbyte),
                    block.positionFromDocbyte(uncommitted_start.?),
                );
            }
            self.cursor_positions.appendAssumeCapacity(res_cursor);
            uncommitted_start = null;
        } else if (!prev_selected and !next_selected) {
            // commit
            std.debug.assert(uncommitted_start == null);
            res_cursor.pos = .at(
                block.positionFromDocbyte(pos.docbyte),
            );
            self.cursor_positions.appendAssumeCapacity(res_cursor);
        } else unreachable;
    }
    std.debug.assert(uncommitted_start == null);
    const len_end = self.cursor_positions.items.len;
    std.debug.assert(len_end <= len_start);
}
pub fn select(self: *Core, selection: Selection) void {
    self.cursor_positions.clearRetainingCapacity();
    self.cursor_positions.append(.{
        .pos = selection,
    }) catch @panic("oom");
}
fn measureMetric(self: *Core, pos: Position, metric: CursorHorizontalPositionMetric) i64 {
    const block = self.document.value;
    const this_line_start = self.getLineStart(pos);
    return switch (metric) {
        .byte => std.math.lossyCast(i64, block.docbyteFromPosition(pos) - block.docbyteFromPosition(this_line_start)),
        else => @panic("TODO support metric"),
    };
}
fn applyMetric(self: *Core, new_line_start: Position, metric: CursorHorizontalPositionMetric, metric_value: i64) Position {
    const block = self.document.value;

    const new_line_start_pos = block.docbyteFromPosition(new_line_start);
    const new_line_end_pos = block.docbyteFromPosition(self.getThisLineEnd(new_line_start));
    const new_line_len = new_line_end_pos - new_line_start_pos;
    return switch (metric) {
        .byte => block.positionFromDocbyte(new_line_start_pos + @min(new_line_len, std.math.lossyCast(u64, metric_value))),
        else => @panic("TODO support metric"),
    };
}
pub fn executeCommand(self: *Core, command: EditorCommand) void {
    const tctx = anywhere.tracy.traceNamed(@src(), "Core.executeCommand");
    defer tctx.end();

    const block = self.document.value;

    self.normalizeCursors();
    defer self.normalizeCursors();

    switch (command) {
        .set_cursor_pos => |sc_op| {
            self.select(.at(sc_op.position));
        },
        .select_all => {
            self.cursor_positions.clearRetainingCapacity();
            self.cursor_positions.append(.{
                .pos = .{
                    .anchor = block.positionFromDocbyte(0),
                    .focus = block.positionFromDocbyte(block.length()), // same as Position.end
                },
            }) catch @panic("oom");
        },
        .insert_text => |text_op| {
            var classification: UndoTokenClassification = .insert_alphanumeric;
            for (text_op.text) |char| {
                if (std.ascii.isWhitespace(char)) classification = .insert_space;
                if (switch (char) {
                    // this matches vscode, but vscode only does it because it's automatically
                    // inserting a right bracket at the same time. so not sure if this makes sense to match.
                    '(', '{', '[', '<' => true,
                    else => false,
                }) classification = .always_split;
            }
            const token = self.addUndoToken(classification);

            for (self.cursor_positions.items) |*cursor_position| {
                const pos_len = self.selectionToPosLen(cursor_position.pos);

                self.replaceRange(token, .{
                    .position = pos_len.pos,
                    .delete_len = pos_len.len,
                    .insert_text = text_op.text,
                });
                const res_pos = pos_len.pos;

                cursor_position.* = .{ .pos = .{
                    .anchor = res_pos,
                    .focus = res_pos,
                } };
            }
        },
        .paste => |paste_op| {
            self.paste(paste_op.text);
        },
        .move_cursor_up_down => |ud_cmd| {
            const orig_len = self.cursor_positions.items.len;
            for (0..orig_len) |i| {
                const cursor_position = &self.cursor_positions.items[i];
                switch (ud_cmd.metric) {
                    .byte => {},
                    else => @panic("TODO impl ud_cmd metric"),
                }
                const this_line_start = self.getLineStart(cursor_position.pos.focus);
                var target_pos: Position = cursor_position.vertical_move_start orelse cursor_position.pos.focus;
                _ = &target_pos; // works around a miscompilation where target_pos changes values after writing to cursor_position :/
                const target = self.measureMetric(target_pos, ud_cmd.metric);

                const new_line_start = switch (ud_cmd.direction) {
                    .up => self.getPrevLineStart(this_line_start),
                    .down => self.getNextLineStart(this_line_start),
                };

                // special-case first and last lines
                const res_pos = if (ud_cmd.direction == .up and block.docbyteFromPosition(this_line_start) == 0) blk: {
                    break :blk new_line_start;
                } else if (ud_cmd.direction == .down and block.docbyteFromPosition(self.getThisLineEnd(this_line_start)) == block.length()) blk: {
                    break :blk self.getThisLineEnd(new_line_start);
                } else blk: {
                    break :blk self.applyMetric(new_line_start, ud_cmd.metric, target);
                };

                // align to stop
                const left_stopped = self.toWordBoundary(res_pos, .left, ud_cmd.stop, .select, .may_move);
                const right_stopped = self.toWordBoundary(res_pos, .right, ud_cmd.stop, .select, .may_move);
                const left_stopped_metric = self.measureMetric(left_stopped, ud_cmd.metric);
                const right_stopped_metric = self.measureMetric(right_stopped, ud_cmd.metric);
                // select the stopped position closest to the target metric
                const stopped_pos = switch (@abs(left_stopped_metric - target) < @abs(right_stopped_metric - target)) {
                    true => left_stopped,
                    false => right_stopped,
                };

                switch (ud_cmd.mode) {
                    .move => {
                        cursor_position.* = .{ .pos = .at(stopped_pos), .vertical_move_start = target_pos };
                        cursor_position.vertical_move_start = target_pos;
                    },
                    .select => cursor_position.* = .{ .pos = .range(cursor_position.pos.anchor, stopped_pos), .vertical_move_start = target_pos },
                    .duplicate => {
                        self.cursor_positions.append(.{ .pos = .at(stopped_pos), .vertical_move_start = target_pos }) catch @panic("oom");
                    },
                }
                // cursor_position pointer is invalidated
            }
        },
        .move_cursor_left_right => |lr_cmd| {
            for (self.cursor_positions.items) |*cursor_position| {
                const current_pos = self.selectionToPosLen(cursor_position.pos);
                if (current_pos.len > 0 and lr_cmd.mode == .move) {
                    cursor_position.* = switch (lr_cmd.direction) {
                        .left => .at(current_pos.pos),
                        .right => .at(current_pos.right),
                    };
                    continue;
                }

                const moved = self.toWordBoundary(cursor_position.pos.focus, lr_cmd.direction, lr_cmd.stop, switch (lr_cmd.direction) {
                    .left => .left,
                    .right => .right,
                }, .must_move);

                switch (lr_cmd.mode) {
                    .move => {
                        cursor_position.* = .at(moved);
                    },
                    .select => {
                        cursor_position.* = .range(cursor_position.pos.anchor, moved);
                    },
                }
            }
        },
        .delete => |lr_cmd| {
            var classification: UndoTokenClassification = .always_split;
            if (lr_cmd.stop == .byte or lr_cmd.stop == .codepoint or lr_cmd.stop == .unicode_grapheme_cluster) {
                classification = .delete_grapheme_cluster;
            }
            const token = self.addUndoToken(classification);

            for (self.cursor_positions.items) |*cursor_position| {
                const moved = self.toWordBoundary(cursor_position.pos.focus, lr_cmd.direction, lr_cmd.stop, switch (lr_cmd.direction) {
                    .left => .left,
                    .right => .right,
                }, .must_move);

                // if there is a selection, delete the selection
                // if there is no selection, delete from the focus in the direction to the stop
                var pos_len = self.selectionToPosLen(cursor_position.pos);
                if (pos_len.len != 0) {
                    self.changeClassification(token, .always_split);
                }
                if (pos_len.len == 0) {
                    pos_len = self.selectionToPosLen(.{ .anchor = cursor_position.pos.focus, .focus = moved });
                }
                if (pos_len.left_docbyte < block.length()) {
                    const first_deleted_char = block.read(pos_len.pos)[0];
                    if (first_deleted_char == '\n') self.changeClassification(token, .always_split);
                }
                self.replaceRange(token, .{
                    .position = pos_len.pos,
                    .delete_len = pos_len.len,
                    .insert_text = "",
                });
                const res_pos = pos_len.pos;

                cursor_position.* = .at(res_pos);
            }
        },
        .newline => {
            const token = self.addUndoToken(.always_split);

            for (self.cursor_positions.items) |*cursor_position| {
                const pos_len = self.selectionToPosLen(cursor_position.pos);

                const line_start = self.getLineStart(pos_len.pos);

                var temp_insert_slice = std.array_list.Managed(u8).init(self.gpa);
                defer temp_insert_slice.deinit();

                const line_indent_count = self.measureIndent(line_start);
                const dist = pos_len.left_docbyte - block.docbyteFromPosition(line_start);
                const order = line_indent_count.chars <= dist;

                if (order) temp_insert_slice.append('\n') catch @panic("oom");
                temp_insert_slice.appendNTimes(self.config.indent_with.char(), usi(self.config.indent_with.count() * line_indent_count.indents)) catch @panic("oom");
                if (!order) temp_insert_slice.append('\n') catch @panic("oom");

                self.replaceRange(token, .{
                    .position = pos_len.pos,
                    .delete_len = pos_len.len,
                    .insert_text = temp_insert_slice.items,
                });
            }
        },
        .insert_line => |cmd| {
            switch (cmd.direction) {
                .up => {
                    for (self.cursor_positions.items) |*cursor_position| cursor_position.* = .at(self.getLineStart(cursor_position.pos.focus));
                    self.executeCommand(.newline);
                    self.executeCommand(.{ .move_cursor_left_right = .{ .mode = .move, .stop = .unicode_grapheme_cluster, .direction = .left } });
                },
                .down => {
                    for (self.cursor_positions.items) |*cursor_position| cursor_position.* = .at(self.getThisLineEnd(cursor_position.pos.focus));
                    self.executeCommand(.newline);
                },
            }
        },
        .indent_selection => |indent_cmd| {
            const token = self.addUndoToken(.always_split);

            for (self.cursor_positions.items) |*cursor_position| {
                const tctx2 = anywhere.tracy.traceNamed(@src(), "indentSelection outer");
                defer tctx2.end();

                const pos_len = self.selectionToPosLen(cursor_position.pos);
                const end_pos = block.positionFromDocbyte(block.docbyteFromPosition(pos_len.pos) + pos_len.len);
                var line_start = self.getLineStart(pos_len.pos);
                while (true) {
                    const tctx3 = anywhere.tracy.traceNamed(@src(), "indentSelection inner");
                    defer tctx3.end();

                    const next_line_start = self.getNextLineStart(line_start);
                    defer line_start = next_line_start;
                    const end = block.docbyteFromPosition(next_line_start) >= block.docbyteFromPosition(end_pos);
                    const line_indent_count = self.measureIndent(line_start);
                    const new_indent_count: u64 = switch (indent_cmd.direction) {
                        .left => std.math.sub(u64, line_indent_count.indents, 1) catch 0,
                        .right => line_indent_count.indents + 1,
                    };

                    var temp_insert_slice = std.array_list.Managed(u8).init(self.gpa);
                    defer temp_insert_slice.deinit();
                    temp_insert_slice.appendNTimes(self.config.indent_with.char(), usi(self.config.indent_with.count() * new_indent_count)) catch @panic("oom");

                    self.replaceRange(token, .{
                        .position = line_start,
                        .delete_len = line_indent_count.chars,
                        .insert_text = temp_insert_slice.items,
                    });
                    if (end) break;
                }
            }
        },
        .duplicate_line => |dupe_cmd| {
            const token = self.addUndoToken(.always_split);

            for (self.cursor_positions.items) |*cursor_position| {
                const pos_len = self.selectionToPosLen(cursor_position.pos);

                const start_line = self.getLineStart(pos_len.pos);
                const end_line = self.getThisLineEnd(pos_len.right);

                const start_byte = block.docbyteFromPosition(start_line);
                const end_byte = block.docbyteFromPosition(end_line);

                var dupe_al: std.array_list.Managed(u8) = .init(self.gpa);
                defer dupe_al.deinit();
                block.readSlice(start_line, dupe_al.addManyAsSlice(@intCast(end_byte - start_byte)) catch @panic("oom"));
                switch (dupe_cmd.direction) {
                    .down => {
                        if (dupe_al.items.len == 0 or dupe_al.items[dupe_al.items.len - 1] != '\n') {
                            dupe_al.append('\n') catch @panic("oom");
                        }
                    },
                    .up => {
                        if (dupe_al.items.len != 0 and dupe_al.items[dupe_al.items.len - 1] == '\n') {
                            _ = dupe_al.pop();
                        }
                        dupe_al.insertSlice(0, &.{'\n'}) catch @panic("oom");
                    },
                }

                self.replaceRange(token, .{
                    .position = switch (dupe_cmd.direction) {
                        .down => start_line,
                        .up => end_line,
                    },
                    .delete_len = 0,
                    .insert_text = dupe_al.items,
                });

                // handle case where cursor is at the end of the line when duplicating up
                if (dupe_cmd.direction == .up) {
                    const target = block.docbyteFromPosition(end_line);
                    for (&[_]*Position{ &cursor_position.pos.anchor, &cursor_position.pos.focus }) |pos| {
                        const pos_int = block.docbyteFromPosition(pos.*);
                        if (pos_int == target) {
                            pos.* = block.positionFromDocbyte(pos_int - dupe_al.items.len);
                        }
                    }
                }
            }
        },
        .ts_select_node => |ts_sel| {
            const syn_hl_ctx = if (self.syn_hl_ctx) |*v| v else return; // no syn hl ctx; can't. todo: at least we could support select full file.
            const tree = syn_hl_ctx.getTree();

            for (self.cursor_positions.items) |*cursor_position| {
                var sel_start = cursor_position.node_select_start orelse cursor_position.pos;
                _ = &sel_start; // work around zig bug. sel_start should be 'const' but it mutates if it is
                const start_pos_len = self.selectionToPosLen(sel_start);
                const sel_curr = cursor_position.pos;
                const curr_pos_len = self.selectionToPosLen(sel_curr);

                const min_node = tree.rootNode().descendantForByteRange(@intCast(start_pos_len.left_docbyte), @intCast(start_pos_len.right_docbyte));

                var curr_node_v = min_node;
                var prev_node: ?ts.Node = null;

                while (curr_node_v) |curr_node| {
                    const node_start = curr_node.startByte();
                    const node_end = curr_node.endByte();

                    //  za[bc]de
                    //  za[bc]de
                    const db = node_start <= curr_pos_len.left_docbyte and node_end >= curr_pos_len.right_docbyte;
                    if (ts_sel.direction == .child and db) {
                        // on down: select previous node
                        break;
                    }
                    if (ts_sel.direction == .parent and db and (node_start < curr_pos_len.left_docbyte or node_end > curr_pos_len.right_docbyte)) {
                        // on up: select this node
                        break;
                    }

                    prev_node = curr_node;
                    curr_node_v = curr_node.slowParent();
                }

                const target_node = switch (ts_sel.direction) {
                    .parent => curr_node_v,
                    .child => prev_node,
                };

                if (target_node == null) switch (ts_sel.direction) {
                    .parent => {
                        // select all
                        cursor_position.* = .{
                            .pos = .range(block.positionFromDocbyte(0), .end),
                            .node_select_start = sel_start,
                        };
                        continue;
                    },
                    .child => {
                        // select min
                        cursor_position.* = .{
                            .pos = sel_start,
                            .node_select_start = sel_start,
                        };
                        continue;
                    },
                };

                cursor_position.* = .{
                    .pos = .range(block.positionFromDocbyte(target_node.?.startByte()), block.positionFromDocbyte(target_node.?.endByte())),
                    .node_select_start = sel_start,
                };
            }
        },
        .undo, .redo => {
            self.last_undo_token_classification = .always_split; // "abcd" ctrl+z ctrl+shift+z "efgh" ctrl+z should only undo "abcd"

            const take_from, const take_from_tokens, const add_to, const add_to_tokens = switch (command) {
                .undo => .{ &self.undo, &self.undo_tokens, &self.redo, &self.redo_tokens },
                .redo => .{ &self.redo, &self.redo_tokens, &self.undo, &self.undo_tokens },
                else => unreachable,
            };
            const token = take_from_tokens.pop() orelse return;
            add_to_tokens.append(.{
                .index = add_to.headers.items.len,
                .cursor_positions_clone_owned = token.cursor_positions_clone_owned,
            }) catch @panic("oom");

            self.cursor_positions.clearRetainingCapacity();
            self.cursor_positions.appendSlice(token.cursor_positions_clone_owned) catch @panic("oom");

            while (take_from.headers.items.len > token.index) {
                const op = take_from.take() orelse return;
                const al = add_to.begin() catch @panic("oom");
                self.document.applyUndoOperation(op, al);
            }
        },
        .click => |click_op| {
            self.onClick(click_op.pos, click_op.mode, click_op.extend, click_op.select_ts_node);
        },
        .drag => |drag_op| {
            self.onDrag(drag_op.pos);
        },
        .replace_whole_file => |rphf_op| {
            const token = self.addUndoToken(.always_split);

            const current_text_tmp = self.gpa.alloc(u8, @intCast(block.length())) catch @panic("oom");
            defer self.gpa.free(current_text_tmp);
            block.readSlice(block.positionFromDocbyte(0), current_text_tmp);

            var diffs = diffz.diff(.default, self.gpa, current_text_tmp, rphf_op.new_text, true) catch |e| switch (e) {
                error.OutOfMemory => @panic("oom"),
            };
            defer diffz.deinitDiffList(self.gpa, &diffs);

            var cursor: usize = 0;
            for (diffs.items) |item| {
                switch (item.operation) {
                    .equal => cursor += item.text.len,
                    .insert => {
                        self.replaceRange(token, .{
                            .delete_len = 0,
                            .insert_text = item.text,
                            .position = block.positionFromDocbyte(cursor),
                        });
                        cursor += item.text.len;
                    },
                    .delete => {
                        self.replaceRange(token, .{
                            .delete_len = item.text.len,
                            .insert_text = "",
                            .position = block.positionFromDocbyte(cursor),
                        });
                    },
                }
            }
        },
    }
}
pub const CopyMode = enum { copy, cut };
/// returned string is utf-8 encoded. caller owns the returned string and must copy it to the clipboard
pub fn copyAllocUtf8(self: *Core, alloc: std.mem.Allocator, mode: CopyMode) []const u8 {
    var result_str = std.array_list.Managed(u8).init(alloc);
    defer result_str.deinit();

    self.copyArrayListUtf8(&result_str, mode);

    return result_str.toOwnedSlice() catch @panic("oom");
}
/// written string is utf-8 encoded and does not include any null bytes
pub fn copyArrayListUtf8(self: *Core, result_str: *std.array_list.Managed(u8), mode: CopyMode) void {
    self.normalizeCursors();
    defer self.normalizeCursors();

    const token = if (mode == .cut) self.addUndoToken(.always_split) else null;

    const stored_buf = self.gpa.alloc([]const u8, self.cursor_positions.items.len) catch @panic("oom");
    var paste_in_new_line = true;
    var this_needs_newline = false;
    for (self.cursor_positions.items, stored_buf) |*cursor, *stored| {
        var pos_range = self.selectionToPosLen(cursor.pos);
        var next_needs_newline = true;
        defer this_needs_newline = next_needs_newline;
        if (pos_range.len == 0) {
            pos_range = self.selectionToPosLen(.range(self.getLineStart(pos_range.pos), self.getNextLineStartMaybeInsertNewline(token, pos_range.pos)));
            next_needs_newline = false;
        } else {
            paste_in_new_line = false;
        }
        const slice = self.gpa.alloc(u8, @intCast(pos_range.len)) catch @panic("oom");
        self.document.value.readSlice(pos_range.pos, slice);
        stored.* = slice;

        if (this_needs_newline) result_str.appendSlice("\n") catch @panic("oom");
        result_str.appendSlice(slice) catch @panic("oom");

        if (mode == .cut) {
            self.replaceRange(token.?, .{ .position = pos_range.pos, .delete_len = pos_range.len, .insert_text = "" });
        }
    }
    if (self.clipboard_cache) |*v| v.deinit(self.gpa);
    self.clipboard_cache = .{
        .contents = stored_buf,
        .copied_str_hash = std.hash.Wyhash.hash(0, result_str.items),
        .paste_in_new_line = paste_in_new_line,
    };

    anywhere.util.replaceInvalidUtf8(result_str.items);
}
fn paste(self: *Core, clipboard_contents: []const u8) void {
    self.normalizeCursors();
    defer self.normalizeCursors();

    const token = self.addUndoToken(.always_split);

    var clip_contents: []const []const u8 = &.{clipboard_contents};
    var paste_in_new_line = false;
    var preserve_copied_str_cache = false;
    if (self.clipboard_cache) |*c| if (c.copied_str_hash == std.hash.Wyhash.hash(0, clipboard_contents)) {
        clip_contents = c.contents;
        paste_in_new_line = c.paste_in_new_line;
        preserve_copied_str_cache = true;
    };
    defer if (!preserve_copied_str_cache) if (self.clipboard_cache) |*c| {
        c.deinit(self.gpa);
        self.clipboard_cache = null;
    };

    if (clip_contents.len == self.cursor_positions.items.len) {
        for (clip_contents, self.cursor_positions.items) |text, *cursor_pos| {
            self.pasteInternal(token, cursor_pos, text, paste_in_new_line);
        }
    } else {
        for (clip_contents) |text| for (self.cursor_positions.items) |*cursor_pos| {
            self.pasteInternal(token, cursor_pos, text, paste_in_new_line);
        };
    }
}
fn pasteInternal(self: *Core, token: UndoToken, cursor_pos: *const CursorPosition, text: []const u8, paste_in_new_line: bool) void {
    var pos_range = self.selectionToPosLen(cursor_pos.pos);
    var add_newline = false;
    if (pos_range.len == 0 and paste_in_new_line) {
        pos_range = self.selectionToPosLen(.at(self.getLineStart(pos_range.pos)));
        add_newline = true;
    }

    self.replaceRange(token, .{
        .position = pos_range.pos,
        .delete_len = pos_range.len,
        .insert_text = text,
    });
}
fn getEnsureOneCursor(self: *Core, default_pos: Position) *CursorPosition {
    if (self.cursor_positions.items.len == 0) {
        self.select(.at(default_pos));
    } else if (self.cursor_positions.items.len > 1) {
        self.cursor_positions.items.len = 1;
    }
    return &self.cursor_positions.items[0];
}
// change to sel_mode: DragSelectionMode, shift_held: bool?
// make this an EditorCommand?
fn onClick(self: *Core, pos: Position, sel_mode: DragSelectionMode, shift_held: bool, ctrl_or_alt_held: bool) void {
    const cursor = self.getEnsureOneCursor(pos);

    if (shift_held) {
        if (cursor.drag_info == null) {
            cursor.drag_info = .{
                .start_pos = cursor.pos.focus,
                .sel_mode = sel_mode,
                .select_ts_node = ctrl_or_alt_held,
            };
        }
        if (sel_mode.select) cursor.drag_info.?.sel_mode = sel_mode;
    } else {
        cursor.drag_info = .{
            .start_pos = pos,
            .sel_mode = sel_mode,
            .select_ts_node = ctrl_or_alt_held,
        };
    }
    self.onDrag(pos);
}
fn onDrag(self: *Core, pos: Position) void {
    const block = self.document.value;

    // TODO: support tree_sitter selection when holding ctrl|alt:
    // - given (drag_start, drag_end):
    //   - find node for range (start, end)
    //   - select from node left to node right
    // should allow for easy selection within brackets: ctrl+drag a little bit and you're done
    const cursor = self.getEnsureOneCursor(pos);
    if (cursor.drag_info == null) return;

    const drag_info = cursor.drag_info.?;
    const stop = drag_info.sel_mode.stop;
    const anchor_pos = drag_info.start_pos;
    if (drag_info.select_ts_node and self.syn_hl_ctx != null) {
        const sel_start: Selection = .range(anchor_pos, pos);
        const pos_len = self.selectionToPosLen(sel_start);

        const tree = self.syn_hl_ctx.?.getTree();
        const min_node = tree.rootNode().descendantForByteRange(@intCast(pos_len.left_docbyte), @intCast(pos_len.right_docbyte));

        const target_start = if (min_node) |m| m.startByte() else 0;
        const target_end = if (min_node) |m| m.endByte() else block.length();

        cursor.* = .{
            .pos = switch (pos_len.is_right) {
                false => .range(block.positionFromDocbyte(target_end), block.positionFromDocbyte(target_start)),
                true => .range(block.positionFromDocbyte(target_start), block.positionFromDocbyte(target_end)),
            },
            .node_select_start = sel_start,
            .drag_info = drag_info,
        };
        return;
    }
    const anchor_l = self.toWordBoundary(anchor_pos, .left, stop, .select, .may_move);
    const focus_l = self.toWordBoundary(pos, .left, stop, .select, .may_move);
    if (drag_info.sel_mode.select) {
        const anchor_r = self.toWordBoundary(anchor_pos, .right, stop, .select, .must_move);
        const focus_r = self.toWordBoundary(pos, .right, stop, .select, .must_move);

        // now:
        // we select from @min(all) to @max(all) and put the cursor on (focus_l < anchor_l ? left : right)

        const anchor_l_docbyte = block.docbyteFromPosition(anchor_l);
        const anchor_r_docbyte = block.docbyteFromPosition(anchor_r);
        const focus_l_docbyte = block.docbyteFromPosition(focus_l);
        const focus_r_docbyte = block.docbyteFromPosition(focus_r);

        const min_docbyte = @min(@min(anchor_l_docbyte, anchor_r_docbyte), @min(focus_l_docbyte, focus_r_docbyte));
        const max_docbyte = @max(@max(anchor_l_docbyte, anchor_r_docbyte), @max(focus_l_docbyte, focus_r_docbyte));
        const min_pos = block.positionFromDocbyte(min_docbyte);
        const max_pos = block.positionFromDocbyte(max_docbyte);

        if (focus_l_docbyte < anchor_l_docbyte) {
            cursor.* = .{
                .pos = .range(max_pos, min_pos),
                .drag_info = drag_info,
            };
        } else {
            cursor.* = .{
                .pos = .range(min_pos, max_pos),
                .drag_info = drag_info,
            };
        }
    } else {
        cursor.* = .{
            .pos = .range(anchor_l, focus_l),
            .drag_info = drag_info,
        };
    }
}

const UndoTokenValue = struct {
    index: usize,
    cursor_positions_clone_owned: []CursorPosition,
};
const UndoToken = struct {
    ut_len: usize,
};
const UndoTokenClassification = enum {
    always_split,
    insert_space,
    insert_alphanumeric,
    delete_grapheme_cluster, // mark always_split for deleting '\n'
};
pub fn changeClassification(self: *Core, token: UndoToken, new_classification: UndoTokenClassification) void {
    std.debug.assert(self.undo_tokens.items.len == token.ut_len);
    self.last_undo_token_classification = new_classification;
}
pub fn addUndoToken(self: *Core, classification: UndoTokenClassification) UndoToken {
    if (self.undo_tokens.items.len > 0) {
        if (self.last_undo_token_classification != .always_split) {
            if (self.last_undo_token_classification == classification) {
                return .{ .ut_len = self.undo_tokens.items.len };
            }
            if (self.last_undo_token_classification == .insert_space and classification == .insert_alphanumeric) {
                self.last_undo_token_classification = .insert_alphanumeric;
                return .{ .ut_len = self.undo_tokens.items.len };
            }
        }
    }

    for (self.redo_tokens.items) |item| self.gpa.free(item.cursor_positions_clone_owned);
    self.redo.clear();
    self.redo_tokens.clearRetainingCapacity();
    self.undo_tokens.append(.{
        .index = self.undo.headers.items.len,
        .cursor_positions_clone_owned = self.gpa.dupe(CursorPosition, self.cursor_positions.items) catch @panic("oom"),
    }) catch @panic("oom");
    self.last_undo_token_classification = classification;
    return .{ .ut_len = self.undo_tokens.items.len };
}
pub fn replaceRange(self: *Core, token: UndoToken, operation: bi.text_component.TextDocument.SimpleOperation) void {
    const tctx3 = anywhere.tracy.traceNamed(@src(), "Core.replaceRange");
    defer tctx3.end();

    std.debug.assert(self.undo_tokens.items.len == token.ut_len);
    self.redo.clear();
    const al = self.undo.begin() catch @panic("oom");
    self.document.applySimpleOperation(operation, al);
}

pub fn getCursorPositions(self: *Core) CursorPositions {
    const tctx = anywhere.tracy.traceNamed(@src(), "Core.getCursorPositions");
    defer tctx.end();

    const block = self.document.value;

    var positions: CursorPositions = .init(self.gpa);
    for (self.cursor_positions.items) |cursor| {
        const anchor = block.docbyteFromPosition(cursor.pos.anchor);
        const focus = block.docbyteFromPosition(cursor.pos.focus);

        positions.add(anchor, focus, cursor);
    }
    positions.sort();

    return positions;
}

pub const Position = bi.text_component.Position;
pub const Selection = struct {
    anchor: Position,
    focus: Position,
    pub fn at(focus: Position) Selection {
        return .{ .anchor = focus, .focus = focus };
    }
    pub fn range(anchor: Position, focus: Position) Selection {
        return .{ .anchor = anchor, .focus = focus };
    }
};
const PosLen = struct {
    pos: Position,
    left_docbyte: u64,
    right: Position,
    right_docbyte: u64,
    len: u64,
    is_right: bool,
};
pub const CursorPosition = struct {
    pos: Selection,

    /// for pressing the up/down arrow going from [aaaa|a] ↓ to [a|] to [aaaa|a]. resets on move.
    vertical_move_start: ?Position = null,
    /// for tree_sitter, the selection at the time of the first select_up command
    node_select_start: ?Selection = null,
    /// select
    drag_info: ?DragInfo = null,

    pub fn from(sel: Selection) CursorPosition {
        return .{ .pos = sel };
    }
    pub fn at(focus: Position) CursorPosition {
        return .from(.at(focus));
    }
    pub fn range(anchor: Position, focus: Position) CursorPosition {
        return .from(.range(anchor, focus));
    }
};

pub const DragInfo = struct {
    start_pos: Position,
    sel_mode: DragSelectionMode,
    select_ts_node: bool,
};
pub const DragSelectionMode = struct {
    stop: CursorLeftRightStop,
    select: bool,

    fn fromSelect(v: CursorLeftRightStop) DragSelectionMode {
        return .{ .select = true, .stop = v };
    }
    fn fromMove(v: CursorLeftRightStop) DragSelectionMode {
        return .{ .select = false, .stop = v };
    }
};

const BetweenCharsStop = enum {
    left_or_select,
    // TODO left_delete_only, for backspacing part of a grapheme cluster
    right_or_select,
    right_only,
    both,
};
const AsciiClassification = enum {
    whitespace,
    symbols,
    text,
    unicode,
};
fn asciiClassify(char: u8) AsciiClassification {
    if (std.ascii.isAlphanumeric(char) or char == '_') return .text;
    if (std.ascii.isWhitespace(char)) return .whitespace;
    if (char >= 0x80) return .unicode;
    return .symbols;
}
const StopCfg = struct {
    /// 0 = none
    count_soft_tab_as_grapheme_cluster: u4,
};
fn hasStop(doc: seg_dep.GenericDocument, docbyte: u64, stop: CursorLeftRightStop, cfg: StopCfg) ?BetweenCharsStop {
    if (docbyte == 0 or docbyte == doc.len) unreachable;

    const docl = doc.read(doc, docbyte - 1, .right);
    const left_byte = docl[0];
    const right_byte = if (docl.len > 1) docl[1] else blk: {
        const docl2 = doc.read(doc, docbyte, .right);
        break :blk docl2[0];
    };
    if (stop == .unicode_grapheme_cluster and cfg.count_soft_tab_as_grapheme_cluster >= 2 and left_byte == ' ' and right_byte == ' ') not_indent: {
        // seek left to line start and right to first non-space byte
        var tab_start = docbyte;
        is_indent: while (tab_start > 0) {
            const txt = doc.read(doc, tab_start, .left);
            std.debug.assert(txt.len > 0);
            std.debug.assert(txt.len <= tab_start);
            var j = txt.len;
            while (j > 0) {
                j -= 1;
                const byte = txt[j];
                switch (byte) {
                    ' ' => {
                        // may be tab; continue
                        tab_start -= 1;
                        continue;
                    },
                    '\n' => {
                        // is tab
                        break :is_indent;
                    },
                    else => {
                        // is not tab; exit
                        break :not_indent;
                    },
                }
            }
        }
        std.debug.assert(tab_start < docbyte); // cannot be '=' because left_byte must be ' '
        const indent_width = docbyte - tab_start;
        if (indent_width % cfg.count_soft_tab_as_grapheme_cluster == 0) {
            // definitely tab stop
            return .both;
        }
        // not a tab stop
        // TODO: mark tab stops at the end of invalid indentation. eg with count_soft_tab_as_grapheme_cluster 4:
        // `|....|....|.|.|.|` (the last indent only has three spaces so mark them all)
        return null;
    }
    if (stop == .unicode_grapheme_cluster) {
        const outer = hasStop(doc, docbyte, .codepoint, cfg);
        if (outer != .both) return null;
        return switch (seg_dep.hasBoundary(
            doc,
            docbyte,
            seg_dep.loadGraphemeDataSingleton(),
        ).shouldBreak()) {
            true => .both,
            false => null,
        };
    }
    return hasStop_bytes(left_byte, right_byte, stop);
}
fn hasStop_bytes(left_byte: u8, right_byte: u8, stop: CursorLeftRightStop) ?BetweenCharsStop {
    switch (stop) {
        .byte => {
            return .both;
        },
        .codepoint => {
            _ = std.unicode.utf8ByteSequenceLength(right_byte) catch return null;
            return .both;
        },
        .unicode_grapheme_cluster => {
            @panic("handled in hasStop()");
        },
        .word => {
            const left = asciiClassify(left_byte);
            const right = asciiClassify(right_byte);
            if (left == right) return null;
            if (left == .whitespace) return .left_or_select;
            if (right == .whitespace) return .right_or_select;
            return .both;
        },
        .unicode_word => {
            @panic("TODO: unicode_word stop");
        },
        .line => {
            // not sure what to do for empty lines?
            if (left_byte == '\n') return .left_or_select;
            if (right_byte == '\r') return .right_only;
            if (right_byte == '\n' and left_byte != '\r') return .right_only;
            return null;
        },
        .visual_line => {
            @panic("function does not have enough information to determine visual line stop");
        },
    }
}
pub const CursorLeftRightStop = enum {
    // so the way these stops should work is:
    // - the whole document has invisible stops for all of these
    // - every stop is either a 'left' stop or a 'right' stop or both.
    // - left movement moves to the next left|both stop from the current position
    // - selection selects to the previous and next either stop from the current position
    // in descriptions: '<' indicates left stop, '>' indicates right stop, '|' indicates both, '.' indicates eof
    // ']' indicates right-only stop, not counted for selections

    // TODO:
    // - 'word' can sometimes stop you in the middle of a grapheme cluster
    //   eg: "e\u{301}" is a single grapheme cluster, but 'word' will put your
    //   cursor right in the middle of it when you press <alt+right arrow>.
    //   ideally, anything after unicode_grapheme_cluster in this list will never
    //   place your cursor inside of a grapheme cluster.

    /// .|h|e|l|l|o| |w|o|r|l|d|.
    byte,
    /// .|a|…|b|.
    codepoint,
    /// .|म|नी|ष|.
    unicode_grapheme_cluster,
    /// .|fn> <demo()> <void> <{}|.
    word,
    /// like word but for natural language instead of code. there is a unicode algorithm for this.
    unicode_word,
    /// .|\n<hello]\n<\n<goodbye!]\n|.
    line,
    /// like line but includes soft wrapped start/ends
    visual_line,
};
pub const CursorHorizontalPositionMetric = enum {
    byte,
    codepoint,
    unicode_grapheme_cluster,

    screen, // view-dependant
};
pub const LRDirection = enum {
    left,
    right,
    pub fn value(dir: LRDirection) i2 {
        return switch (dir) {
            .left => -1,
            .right => 1,
        };
    }
};
pub const EditorCommand = union(enum) {
    move_cursor_left_right: struct {
        mode: enum { move, select },
        direction: LRDirection,
        stop: CursorLeftRightStop,
    },
    delete: struct {
        direction: LRDirection,
        stop: CursorLeftRightStop,
    },
    move_cursor_up_down: struct {
        direction: enum { up, down },
        mode: enum { move, select, duplicate },
        metric: CursorHorizontalPositionMetric,
        stop: CursorLeftRightStop,
    },
    select_all: void,
    insert_text: struct {
        text: []const u8,
    },
    paste: struct {
        text: []const u8,
    },
    newline: void,
    insert_line: struct {
        direction: enum { up, down },
    },
    indent_selection: struct {
        direction: LRDirection,
    },
    ts_select_node: struct {
        direction: enum { parent, child },
    },
    undo: void,
    redo: void,
    set_cursor_pos: struct {
        position: Position,
    },
    duplicate_line: struct {
        direction: enum { up, down },
    },

    click: struct {
        pos: Position,
        mode: DragSelectionMode = .fromMove(.unicode_grapheme_cluster),
        extend: bool = false,
        select_ts_node: bool = false,
    },
    drag: struct {
        pos: Position,
    },
    replace_whole_file: struct {
        // if the file is reloaded on disk and it's different, use replace_whole_file
        new_text: []const u8,
    },
};

pub const IndentMode = union(enum) {
    tabs,
    spaces: u4,
    fn char(self: IndentMode) u8 {
        return switch (self) {
            .tabs => '\t',
            .spaces => ' ',
        };
    }
    fn count(self: IndentMode) u64 {
        return switch (self) {
            .tabs => 1,
            .spaces => |s| s,
        };
    }
};
pub const EditorConfig = struct {
    /// what to indent with
    indent_with: IndentMode,
    /// when in 'unicode_grapheme_cluster' movement mode, if indentation counts as one grapheme cluster
    count_soft_tab_as_grapheme_cluster: bool,
};

const DocumentDocument = struct {
    text_doc: *bi.text_component.TextDocument,

    pub fn read(self_g: seg_dep.GenericDocument, offset: u64, direction: seg_dep.GDirection) []const u8 {
        const self = self_g.cast(DocumentDocument);

        return switch (direction) {
            .right => self.text_doc.read(self.text_doc.positionFromDocbyte(offset)),
            .left => self.text_doc.readLeft(self.text_doc.positionFromDocbyte(offset)),
        };
    }

    pub fn doc(self: *DocumentDocument) seg_dep.GenericDocument {
        return .from(DocumentDocument, self, self.text_doc.length());
    }
};

pub fn SliceStackAligned(comptime T: type, comptime alignment: ?std.mem.Alignment) type {
    if (alignment) |a| {
        if (a == std.mem.Alignment.of(T)) {
            return SliceStackAligned(T, null);
        }
    }
    return struct {
        const Range = struct { start: usize, end: if (alignment) |_| usize else void };
        const SSA = @This();
        values: std.array_list.AlignedManaged(T, alignment),
        headers: std.array_list.Managed(Header),
        const Header = struct {
            last_item_end: if (alignment) |_| usize else void,
            this_item_start: usize,
        };

        pub fn init(gpa: std.mem.Allocator) TextStack {
            return .{ .values = .init(gpa), .headers = .init(gpa) };
        }
        pub fn deinit(self: TextStack) void {
            self.values.deinit();
            self.headers.deinit();
        }

        pub fn clear(self: *TextStack) void {
            self.values.clearRetainingCapacity();
            self.headers.clearRetainingCapacity();
        }

        pub fn begin(self: *TextStack) !*std.array_list.AlignedManaged(T, alignment) {
            const last_item_end = self.values.items.len;
            if (alignment) |a| {
                const aligned_len = std.mem.alignForward(usize, last_item_end, a.toByteUnits());
                try self.values.resize(aligned_len);
            }
            const this_item_start = self.values.items.len;

            try self.headers.append(.{
                .last_item_end = if (alignment) |_| last_item_end else {},
                .this_item_start = this_item_start,
            });

            return &self.values;
        }
        pub fn cancel(self: *TextStack) void {
            _ = self.take().?;
        }
        pub fn add(self: *TextStack, value: []const T) !void {
            const al = try self.begin();
            errdefer self.cancel();

            try al.appendSlice(value);
        }
        /// pointer is only valid until next add(), begin(), or deinit() call.
        pub fn take(self: *TextStack) ?(if (alignment) |a| []align(a.toByteUnits()) T else []T) {
            if (self.headers.items.len == 0) return null;

            const header = self.headers.pop().?;
            const res = self.values.items[header.this_item_start..];
            self.values.items = self.values.items[0..if (alignment) |_| header.last_item_end else header.this_item_start];
            return @alignCast(res);
        }
    };
}

const TextStack = SliceStackAligned(u8, bi.Alignment);

test TextStack {
    var mystack: TextStack = .init(std.testing.allocator);
    defer mystack.deinit();

    try mystack.add("one");
    try mystack.add("2");
    try mystack.add("threeee!");
    try std.testing.expectEqualStrings("threeee!", mystack.take() orelse "null");
    try std.testing.expectEqualStrings("2", mystack.take() orelse "null");
    try mystack.add("five");
    try std.testing.expectEqualStrings("five", mystack.take() orelse "null");
    mystack.clear();
    try std.testing.expectEqualStrings("null", mystack.take() orelse "null");

    try mystack.add("0123456789ABCDEF");
    try mystack.add("0123456789ABCDEFG");
    try mystack.add("0123456789ABCDEFGH");
    try std.testing.expectEqualStrings("0123456789ABCDEFGH", mystack.take() orelse "null");
    try std.testing.expectEqualStrings("0123456789ABCDEFG", mystack.take() orelse "null");
    try std.testing.expectEqualStrings("0123456789ABCDEF", mystack.take() orelse "null");
    try std.testing.expectEqualStrings("null", mystack.take() orelse "null");

    {
        const al = try mystack.begin();
        errdefer mystack.cancel();
        try al.appendSlice("0123456789ABCDEF");
    }
    {
        const al = try mystack.begin();
        errdefer mystack.cancel();
        try al.appendSlice("0123456789ABCDEFG");
    }
    {
        const al = try mystack.begin();
        errdefer mystack.cancel();
        try al.appendSlice("0123456789ABCDEFGH");
    }
    try std.testing.expectEqualStrings("0123456789ABCDEFGH", mystack.take() orelse "null");
    try std.testing.expectEqualStrings("0123456789ABCDEFG", mystack.take() orelse "null");
    try std.testing.expectEqualStrings("0123456789ABCDEF", mystack.take() orelse "null");
    try std.testing.expectEqualStrings("null", mystack.take() orelse "null");
}

const PositionItem = struct {
    docbyte: u64,
    mode: enum { start, end },
    kind: enum { anchor, focus },

    extra: CursorPosition,

    fn compareFn(_: void, a: PositionItem, b: PositionItem) bool {
        return a.docbyte < b.docbyte;
    }
};
pub const CursorPosState = enum { none, start, focus, end };
pub const CursorPosRes = struct {
    left_cursor: CursorPosState,
    left_cursor_extra: ?CursorPosition,
    selected: bool,
};
pub const CursorPositions = struct {
    idx: usize,
    count: f32,
    positions: std.array_list.Managed(PositionItem),
    last_query: u64,
    last_query_result: ?CursorPosRes,

    pub fn init(gpa: std.mem.Allocator) CursorPositions {
        return .{ .idx = 0, .count = 0, .positions = .init(gpa), .last_query = 0, .last_query_result = null };
    }
    pub fn deinit(self: *CursorPositions) void {
        self.positions.deinit();
    }
    fn add(self: *CursorPositions, anchor: u64, focus: u64, extra: CursorPosition) void {
        const left = @min(anchor, focus);
        const right = @max(anchor, focus);
        self.positions.append(.{ .mode = .start, .docbyte = left, .kind = if (left == focus) .focus else .anchor, .extra = extra }) catch @panic("oom");
        self.positions.append(.{ .mode = .end, .docbyte = right, .kind = if (left == focus) .anchor else .focus, .extra = extra }) catch @panic("oom");
    }
    fn sort(self: *CursorPositions) void {
        std.mem.sort(PositionItem, self.positions.items, {}, PositionItem.compareFn);
    }

    pub fn reset(self: *CursorPositions) void {
        self.idx = 0;
        self.count = 0;
        self.last_query = 0;
        self.last_query_result = null;
    }
    pub fn advanceAndRead(self: *CursorPositions, docbyte: u64) CursorPosRes {
        if (docbyte == self.last_query and self.last_query_result != null) return self.last_query_result.?;
        if (docbyte < self.last_query) {
            // did not advance.
            self.reset();
        }
        return self.advanceAndReadAssertAdvanced(docbyte);
    }
    pub fn advanceAndReadAssertAdvanced(self: *CursorPositions, docbyte: u64) CursorPosRes {
        std.debug.assert(docbyte > self.last_query or self.last_query_result == null);
        var left_cursor: CursorPosState = .none;
        var left_cursor_extra: ?CursorPosition = null;
        while (true) : (self.idx += 1) {
            if (self.idx >= self.positions.items.len) break;
            const itm = self.positions.items[self.idx];
            if (itm.docbyte > docbyte) break;
            switch (itm.mode) {
                .start => self.count += 1,
                .end => self.count -= 1,
            }
            if (itm.docbyte == docbyte) {
                left_cursor = switch (left_cursor) {
                    .none => switch (itm.kind) {
                        .anchor => switch (itm.mode) {
                            .start => .start,
                            .end => .end,
                        },
                        .focus => .focus,
                    },
                    .start, .end, .focus => .focus,
                };
            }
            left_cursor_extra = itm.extra;
        }
        self.last_query = docbyte;
        self.last_query_result = .{
            .left_cursor = left_cursor,
            .left_cursor_extra = left_cursor_extra,
            .selected = self.count != 0,
        };
        return self.last_query_result.?;
    }
};

fn testEditorContent(expected: []const u8, editor: *Core) !void {
    const actual = &editor.document;
    const gpa = std.testing.allocator;
    var rendered = std.array_list.Managed(u8).init(gpa);
    defer rendered.deinit();
    try rendered.ensureUnusedCapacity(usi(actual.value.length() + 1));
    rendered.appendNTimesAssumeCapacity(undefined, usi(actual.value.length()));
    actual.value.readSlice(actual.value.positionFromDocbyte(0), rendered.items);
    rendered.appendAssumeCapacity('\x00');

    var positions = editor.getCursorPositions();
    defer positions.deinit();
    var rendered2 = std.array_list.Managed(u8).init(gpa);
    defer rendered2.deinit();
    for (rendered.items, 0..) |char, i| {
        const pos_info = positions.advanceAndRead(i);
        switch (pos_info.left_cursor) {
            .none => {},
            .start => try rendered2.append('['),
            .focus => try rendered2.append('|'),
            .end => try rendered2.append(']'),
        }
        try rendered2.append(char);
    }
    std.debug.assert(rendered2.pop() == '\x00');

    try std.testing.expectEqualStrings(expected, rendered2.items);
}

const EditorTester = struct {
    gpa: std.mem.Allocator,
    my_db: db_mod.BlockDB,
    src_block: *db_mod.BlockRef,
    src_component: db_mod.TypedComponentRef(bi.TextDocumentBlock.Child),
    language: highlighters_zig.HlZig,
    editor: Core,

    pub fn init(res: *EditorTester, gpa: std.mem.Allocator, initial_text: []const u8) void {
        res.* = .{
            .gpa = gpa,
            .my_db = undefined,
            .src_block = undefined,
            .src_component = undefined,
            .language = .init(gpa),
            .editor = undefined,
        };
        res.my_db = .init(gpa);
        res.src_block = res.my_db.createBlock(bi.TextDocumentBlock.deserialize(gpa, bi.TextDocumentBlock.default) catch unreachable);
        res.src_component = res.src_block.typedComponent(bi.TextDocumentBlock) orelse unreachable;
        res.editor.initFromDoc(gpa, res.src_component);
        res.editor.setSynHl(res.language.language());

        res.src_component.applySimpleOperation(.{ .position = res.src_component.value.positionFromDocbyte(0), .delete_len = 0, .insert_text = initial_text }, null);
    }
    pub fn deinit(self: *EditorTester) void {
        self.editor.deinit();
        self.src_block.unref();
        self.src_component.unref();
        self.my_db.deinit();
        self.language.deinit();
    }

    pub fn expectContent(self: *EditorTester, expected: []const u8) !void {
        try testEditorContent(expected, &self.editor);
    }
    pub fn executeCommand(self: *EditorTester, command: EditorCommand) void {
        self.editor.executeCommand(command);
    }
    pub fn pos(self: *EditorTester, docbyte: usize) Position {
        return self.editor.document.value.positionFromDocbyte(docbyte);
    }
};

/// Chars:
/// left_or_select : `<`
/// right_or_select : `>`
/// right_only : `]`
/// both : `|`
fn testFindStops(expected: []const u8, stop_type: CursorLeftRightStop) !void {
    return testFindStops_withOption(expected, stop_type, .{ .count_soft_tab_as_grapheme_cluster = 0 });
}
fn testFindStops_withOption(expected: []const u8, stop_type: CursorLeftRightStop, cfg: StopCfg) !void {
    var test_src = std.array_list.Managed(u8).init(std.testing.allocator);
    defer test_src.deinit();
    for (expected) |char| {
        switch (char) {
            '<', '>', ']', '|' => {},
            else => try test_src.append(char),
        }
    }
    var test_src_doc_itm = seg_dep.SliceDocument{ .slice = test_src.items };
    const test_src_doc = test_src_doc_itm.doc();

    var test_res = std.array_list.Managed(u8).init(std.testing.allocator);
    defer test_res.deinit();
    for (0..test_src.items.len + 1) |i| {
        const hs_res = blk: {
            if (i == 0 or i == test_src.items.len) break :blk .both;
            break :blk hasStop(test_src_doc, i, stop_type, cfg);
        };
        if (hs_res) |hr| try test_res.append(switch (hr) {
            .left_or_select => '<',
            .right_or_select => '>',
            .right_only => ']',
            .both => '|',
        });
        if (i < test_src.items.len) try test_res.append(test_src.items[i]);
    }
    try std.testing.expectEqualStrings(expected, test_res.items);
}
test hasStop {
    inline for (std.meta.fields(CursorLeftRightStop)) |field| {
        const v = @field(CursorLeftRightStop, field.name);
        switch (v) {
            .byte => {
                try testFindStops("|h|e|l|l|o|", v);
                try testFindStops("|u|\xE2|\x80|\xA6|!|", v);
            },
            .codepoint => {
                try testFindStops("|u|\xE2\x80\xA6|!|", v);
                try testFindStops("|H|e|\u{301}|l|l|o|", v);
            },
            .unicode_grapheme_cluster => {
                try testFindStops("|म|नी|ष|", v);
                try testFindStops("|H|e\u{301}|l|l|o|", v);
                try testFindStops("|🇷🇸|🇮🇴|🇷🇸|🇮🇴|🇷🇸|🇮🇴|🇷🇸|🇮🇴|", v);
                try testFindStops("|\u{301}|", v);
                try testFindStops("|h|i|👨‍👩‍👧‍👧|b|y|e|", v);
                try testFindStops_withOption(
                    \\|m|a|i|n|
                    \\|    |i|f| | | | | | |(| | | | | | |c|o|n|d| | | | | | |)|{|
                    \\|    |    |e|p|i|c|!|;|
                    \\|    |e|n|d|
                    \\|e|n|d|
                , v, .{ .count_soft_tab_as_grapheme_cluster = 4 });
                try testFindStops_withOption("|    |    |", v, .{ .count_soft_tab_as_grapheme_cluster = 4 });
            },
            .word => {
                try testFindStops("|hello> <world|", v);
                try testFindStops("|    <\\\\>    <}>\n    <\\\\>    <@|vertex> <fn> <vert|(|in|:> <VertexIn|)|", v);
                try testFindStops("| <myfn|(|crazy|)> |", v);
                try testFindStops("|He|\u{301}|llo|", v); // TODO: don't put word stops in the middle of a grapheme cluster
            },
            .unicode_word => {
                // TODO. also unicode word segmentation is system language dependant for some reason.
                // so either make it use english or ask for the system language and use that.
                // try testFindStops("|这|只是|一些|随机|的|文本|", v);
            },
            .line => {
                try testFindStops("|line one]\n<line two]\n<line three|", v);
            },
            .visual_line => {
                // todo
            },
        }
    }
}

test Core {
    var tester: EditorTester = undefined;
    tester.init(std.testing.allocator, "hello!");
    defer tester.deinit();

    try tester.expectContent("hello!");
    tester.executeCommand(.{ .set_cursor_pos = .{ .position = tester.pos(0) } });
    try tester.expectContent("|hello!");
    tester.executeCommand(.{ .insert_text = .{ .text = "abcd!" } });
    try tester.expectContent("abcd!|hello!");
    tester.executeCommand(.{ .set_cursor_pos = .{ .position = tester.pos(0) } });
    try tester.expectContent("|abcd!hello!");
    tester.executeCommand(.{ .delete = .{ .direction = .right, .stop = .byte } });
    try tester.expectContent("|bcd!hello!");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .byte } });
    try tester.expectContent("|bcd!hello!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .right, .stop = .byte, .mode = .select } });
    try tester.expectContent("[b|cd!hello!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .right, .stop = .byte, .mode = .select } });
    try tester.expectContent("[bc|d!hello!");
    tester.executeCommand(.{ .delete = .{ .direction = .right, .stop = .byte } });
    try tester.expectContent("|d!hello!");
    tester.executeCommand(.{ .insert_text = .{ .text = "……" } });
    try std.testing.expectEqual(@as(usize, 1), tester.editor.cursor_positions.items.len);
    try tester.expectContent("……|d!hello!");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .codepoint } });
    try tester.expectContent("…|d!hello!");
    tester.executeCommand(.{ .delete = .{ .direction = .right, .stop = .line } });
    try tester.expectContent("…|");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .line } });
    try tester.expectContent("|");
    tester.executeCommand(.{ .insert_text = .{ .text = "    hi();" } });
    try tester.expectContent("    hi();|");
    tester.executeCommand(.newline);
    try tester.expectContent("    hi();\n    |");
    tester.executeCommand(.{ .insert_text = .{ .text = "goodbye();" } });
    try tester.expectContent("    hi();\n    goodbye();|");
    tester.executeCommand(.{ .indent_selection = .{ .direction = .left } });
    try tester.expectContent("    hi();\ngoodbye();|");
    tester.executeCommand(.{ .indent_selection = .{ .direction = .right } });
    try tester.expectContent("    hi();\n    goodbye();|");
    tester.executeCommand(.{ .indent_selection = .{ .direction = .right } });
    try tester.expectContent("    hi();\n        goodbye();|");
    tester.executeCommand(.newline);
    try tester.expectContent("    hi();\n        goodbye();\n        |");
    tester.executeCommand(.{ .indent_selection = .{ .direction = .left } });
    tester.executeCommand(.{ .indent_selection = .{ .direction = .left } });
    try tester.expectContent("    hi();\n        goodbye();\n|");
    tester.executeCommand(.{ .indent_selection = .{ .direction = .right } });
    try tester.expectContent("    hi();\n        goodbye();\n    |");
    tester.executeCommand(.select_all);
    try tester.expectContent("[    hi();\n        goodbye();\n    |");
    tester.executeCommand(.{ .indent_selection = .{ .direction = .left } });
    try tester.expectContent("[hi();\n    goodbye();\n|");
    tester.executeCommand(.{ .indent_selection = .{ .direction = .right } });
    try tester.expectContent("    [hi();\n        goodbye();\n|"); // not sure if this is what we want
    tester.executeCommand(.{ .indent_selection = .{ .direction = .left } });
    try tester.expectContent("[hi();\n    goodbye();\n|");
    tester.executeCommand(.{ .delete = .{ .direction = .right, .stop = .byte } });
    try tester.expectContent("|");
    tester.executeCommand(.{ .insert_text = .{ .text = "hello\nto the world!" } });
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .left, .stop = .byte, .mode = .move } });
    try tester.expectContent(
        \\hello
        \\to the world|!
    );
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .up, .metric = .byte, .mode = .move, .stop = .byte } });
    try tester.expectContent(
        \\hello|
        \\to the world!
    );
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .down, .metric = .byte, .mode = .move, .stop = .byte } });
    try tester.expectContent(
        \\hello
        \\to the world|!
    );
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .up, .metric = .byte, .mode = .move, .stop = .byte } });
    try tester.expectContent(
        \\hello|
        \\to the world!
    );
    tester.executeCommand(.{ .insert_text = .{ .text = "!" } });
    try tester.expectContent(
        \\hello!|
        \\to the world!
    );
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .down, .metric = .byte, .mode = .move, .stop = .byte } });
    try tester.expectContent(
        \\hello!
        \\to the| world!
    );

    tester.executeCommand(.select_all);
    tester.executeCommand(.{ .insert_text = .{ .text = "hello" } });
    try tester.expectContent("hello|");

    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .left, .mode = .move, .stop = .byte } });
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .left, .mode = .move, .stop = .byte } });
    try tester.expectContent("hel|lo");
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .down, .metric = .byte, .mode = .select, .stop = .byte } });
    try tester.expectContent("hel[lo|");

    tester.executeCommand(.select_all);
    tester.executeCommand(.{ .insert_text = .{ .text = "hela\n\ninput\n\n\nlo!" } });
    try tester.expectContent("hela\n\ninput\n\n\nlo!|");
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .up, .metric = .byte, .mode = .move, .stop = .byte } });
    try tester.expectContent("hela\n\ninput\n\n|\nlo!");
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .up, .metric = .byte, .mode = .move, .stop = .byte } });
    try tester.expectContent("hela\n\ninput\n|\n\nlo!");
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .up, .metric = .byte, .mode = .move, .stop = .byte } });
    try tester.expectContent("hela\n\ninp|ut\n\n\nlo!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .right, .mode = .move, .stop = .byte } });
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .right, .mode = .move, .stop = .byte } });
    try tester.expectContent("hela\n\ninput|\n\n\nlo!");
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .up, .metric = .byte, .mode = .move, .stop = .byte } });
    try tester.expectContent("hela\n|\ninput\n\n\nlo!");
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .up, .metric = .byte, .mode = .move, .stop = .byte } });
    try tester.expectContent("hela|\n\ninput\n\n\nlo!");

    tester.executeCommand(.select_all);
    tester.executeCommand(.{ .insert_text = .{ .text = "here are a few words to traverse!" } });
    try tester.expectContent("here are a few words to traverse!|");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .left, .mode = .move, .stop = .word } });
    try tester.expectContent("here are a few words to traverse|!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .left, .mode = .move, .stop = .word } });
    try tester.expectContent("here are a few words to |traverse!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .left, .mode = .move, .stop = .word } });
    try tester.expectContent("here are a few words |to traverse!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .left, .mode = .move, .stop = .word } });
    try tester.expectContent("here are a few |words to traverse!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .left, .mode = .move, .stop = .word } });
    try tester.expectContent("here are a |few words to traverse!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .left, .mode = .move, .stop = .word } });
    try tester.expectContent("here are |a few words to traverse!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .left, .mode = .move, .stop = .word } });
    try tester.expectContent("here |are a few words to traverse!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .left, .mode = .move, .stop = .word } });
    try tester.expectContent("|here are a few words to traverse!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .left, .mode = .move, .stop = .word } });
    try tester.expectContent("|here are a few words to traverse!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .right, .mode = .move, .stop = .word } });
    try tester.expectContent("here| are a few words to traverse!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .right, .mode = .move, .stop = .word } });
    try tester.expectContent("here are| a few words to traverse!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .right, .mode = .move, .stop = .word } });
    try tester.expectContent("here are a| few words to traverse!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .right, .mode = .move, .stop = .word } });
    try tester.expectContent("here are a few| words to traverse!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .right, .mode = .move, .stop = .word } });
    try tester.expectContent("here are a few words| to traverse!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .right, .mode = .move, .stop = .word } });
    try tester.expectContent("here are a few words to| traverse!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .right, .mode = .move, .stop = .word } });
    try tester.expectContent("here are a few words to traverse|!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .right, .mode = .move, .stop = .word } });
    try tester.expectContent("here are a few words to traverse!|");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .right, .mode = .move, .stop = .word } });
    try tester.expectContent("here are a few words to traverse!|");

    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .up, .metric = .byte, .mode = .move, .stop = .byte } });
    try tester.expectContent("|here are a few words to traverse!");
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .down, .metric = .byte, .mode = .move, .stop = .byte } });
    try tester.expectContent("here are a few words to traverse!|");

    tester.executeCommand(.{ .click = .{ .pos = tester.pos(13) } });
    try tester.expectContent("here are a fe|w words to traverse!");
    tester.executeCommand(.{ .click = .{ .pos = tester.pos(17), .extend = true } });
    try tester.expectContent("here are a fe[w wo|rds to traverse!");
    tester.executeCommand(.{ .click = .{ .pos = tester.pos(6) } });
    try tester.expectContent("here a|re a few words to traverse!");
    tester.executeCommand(.{ .click = .{ .pos = tester.pos(6), .mode = .fromSelect(.word) } });
    try tester.expectContent("here [are| a few words to traverse!");
    tester.executeCommand(.{ .drag = .{ .pos = tester.pos(13) } });
    try tester.expectContent("here [are a few| words to traverse!");
    tester.executeCommand(.{ .drag = .{ .pos = tester.pos(1) } });
    try tester.expectContent("|here are] a few words to traverse!");

    tester.executeCommand(.select_all);
    tester.executeCommand(.{ .insert_text = .{ .text = (
        \\    \\    }
        \\    \\    @vertex fn vert(in: VertexIn)
    ) } });
    tester.executeCommand(.{ .set_cursor_pos = .{ .position = tester.pos(11) } });
    try tester.expectContent(
        \\    \\    }|
        \\    \\    @vertex fn vert(in: VertexIn)
    );
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .right, .stop = .word, .mode = .move } });
    try tester.expectContent(
        \\    \\    }
        \\    \\|    @vertex fn vert(in: VertexIn)
    );

    //
    // Grapheme cluster movement
    //
    tester.executeCommand(.select_all);
    tester.executeCommand(.{ .insert_text = .{ .text = "He\u{301}! …मनीष!👨‍👩‍👧‍👧/🇷🇸🇮🇴/!\r\n!\n." } });
    try tester.expectContent("He\u{301}! …मनीष!👨‍👩‍👧‍👧/🇷🇸🇮🇴/!\r\n!\n.|");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("He\u{301}! …मनीष!👨‍👩‍👧‍👧/🇷🇸🇮🇴/!\r\n!\n|");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("He\u{301}! …मनीष!👨‍👩‍👧‍👧/🇷🇸🇮🇴/!\r\n!|");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("He\u{301}! …मनीष!👨‍👩‍👧‍👧/🇷🇸🇮🇴/!\r\n|");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("He\u{301}! …मनीष!👨‍👩‍👧‍👧/🇷🇸🇮🇴/!|");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("He\u{301}! …मनीष!👨‍👩‍👧‍👧/🇷🇸🇮🇴/|");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("He\u{301}! …मनीष!👨‍👩‍👧‍👧/🇷🇸🇮🇴|");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("He\u{301}! …मनीष!👨‍👩‍👧‍👧/🇷🇸|");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("He\u{301}! …मनीष!👨‍👩‍👧‍👧/|");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("He\u{301}! …मनीष!👨‍👩‍👧‍👧|");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("He\u{301}! …मनीष!|");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("He\u{301}! …मनीष|");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("He\u{301}! …मनी|");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("He\u{301}! …म|"); // TODO: not sure if this is expected behaviour. firefox deletes these one codepoint at a time
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("He\u{301}! …|");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("He\u{301}! |");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("He\u{301}!|");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("He\u{301}|");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("H|");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("|");

    //
    // Grapheme cluster click
    //
    tester.executeCommand(.{ .insert_text = .{ .text = "e\u{301}" } });
    try tester.expectContent("e\u{301}|");
    tester.editor.executeCommand(.{ .click = .{ .pos = tester.pos(1) } });
    try tester.expectContent("|e\u{301}");
    tester.executeCommand(.{ .drag = .{ .pos = tester.pos(2) } });
    try tester.expectContent("|e\u{301}");
    tester.executeCommand(.{ .drag = .{ .pos = tester.pos(3) } });
    try tester.expectContent("[e\u{301}|");
    tester.executeCommand(.{ .drag = .{ .pos = tester.pos(2) } });
    try tester.expectContent("|e\u{301}");
    tester.executeCommand(.{ .drag = .{ .pos = tester.pos(1) } });
    try tester.expectContent("|e\u{301}");
    tester.executeCommand(.{ .drag = .{ .pos = tester.pos(0) } });
    try tester.expectContent("|e\u{301}");

    //
    // Vertical movement
    //
    tester.executeCommand(.select_all);
    tester.executeCommand(.{ .insert_text = .{ .text = "line 1\nline 2\nline 3\nline 4" } });
    try tester.expectContent("line 1\nline 2\nline 3\nline 4|");
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .up, .metric = .byte, .mode = .duplicate, .stop = .byte } });
    try tester.expectContent("line 1\nline 2\nline 3|\nline 4|");
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .up, .metric = .byte, .mode = .duplicate, .stop = .byte } });
    try tester.expectContent("line 1\nline 2|\nline 3|\nline 4|");
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .up, .metric = .byte, .mode = .duplicate, .stop = .byte } });
    try tester.expectContent("line 1|\nline 2|\nline 3|\nline 4|");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .byte } });
    try tester.expectContent("line |\nline |\nline |\nline |");
    tester.executeCommand(.{ .insert_text = .{ .text = "5" } });
    try tester.expectContent("line 5|\nline 5|\nline 5|\nline 5|");

    //
    // Duplicate line
    //
    tester.executeCommand(.select_all);
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .right, .stop = .word, .mode = .move } });
    try tester.expectContent("line 5\nline 5\nline 5\nline 5|");
    tester.executeCommand(.{ .duplicate_line = .{ .direction = .up } });
    try tester.expectContent("line 5\nline 5\nline 5\nline 5|\nline 5");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .byte } });
    tester.executeCommand(.{ .insert_text = .{ .text = "9" } });
    try tester.expectContent("line 5\nline 5\nline 5\nline 9|\nline 5");
    tester.executeCommand(.{ .duplicate_line = .{ .direction = .down } });
    try tester.expectContent("line 5\nline 5\nline 5\nline 9\nline 9|\nline 5");

    //
    // Tree sitter node functions
    //
    tester.executeCommand(.select_all);
    tester.executeCommand(.{ .insert_text = .{ .text = "pub fn demo() !u8 {\n    return 5;\n}\n" } });
    tester.editor.executeCommand(.{ .click = .{ .pos = tester.pos(29), .select_ts_node = true } });
    try tester.expectContent("pub fn demo() !u8 {\n    [return| 5;\n}\n");
    tester.executeCommand(.{ .drag = .{ .pos = tester.pos(29) } });
    try tester.expectContent("pub fn demo() !u8 {\n    [return| 5;\n}\n");
    tester.executeCommand(.{ .drag = .{ .pos = tester.pos(27) } });
    try tester.expectContent("pub fn demo() !u8 {\n    |return] 5;\n}\n");
    tester.executeCommand(.{ .drag = .{ .pos = tester.pos(23) } });
    try tester.expectContent("pub fn demo() !u8 |{\n    return 5;\n}]\n");
    tester.executeCommand(.{ .drag = .{ .pos = tester.pos(8) } });
    try tester.expectContent("pub |fn demo() !u8 {\n    return 5;\n}]\n");
    tester.executeCommand(.{ .click = .{ .pos = tester.pos(29) } });
    try tester.expectContent("pub fn demo() !u8 {\n    retur|n 5;\n}\n");
    tester.executeCommand(.{ .ts_select_node = .{ .direction = .parent } });
    try tester.expectContent("pub fn demo() !u8 {\n    [return| 5;\n}\n");
    tester.executeCommand(.{ .ts_select_node = .{ .direction = .parent } });
    try tester.expectContent("pub fn demo() !u8 {\n    [return 5|;\n}\n");
    tester.executeCommand(.{ .ts_select_node = .{ .direction = .parent } });
    try tester.expectContent("pub fn demo() !u8 {\n    [return 5;|\n}\n");
    tester.executeCommand(.{ .ts_select_node = .{ .direction = .parent } });
    try tester.expectContent("pub fn demo() !u8 [{\n    return 5;\n}|\n");
    tester.executeCommand(.{ .ts_select_node = .{ .direction = .parent } });
    try tester.expectContent("pub [fn demo() !u8 {\n    return 5;\n}|\n");
    tester.executeCommand(.{ .ts_select_node = .{ .direction = .parent } });
    try tester.expectContent("[pub fn demo() !u8 {\n    return 5;\n}\n|");
    tester.executeCommand(.{ .ts_select_node = .{ .direction = .parent } });
    try tester.expectContent("[pub fn demo() !u8 {\n    return 5;\n}\n|");
    tester.executeCommand(.{ .ts_select_node = .{ .direction = .child } });
    try tester.expectContent("pub [fn demo() !u8 {\n    return 5;\n}|\n");
    tester.executeCommand(.{ .ts_select_node = .{ .direction = .child } });
    try tester.expectContent("pub fn demo() !u8 [{\n    return 5;\n}|\n");
    tester.executeCommand(.{ .ts_select_node = .{ .direction = .child } });
    try tester.expectContent("pub fn demo() !u8 {\n    [return 5;|\n}\n");
    tester.executeCommand(.{ .ts_select_node = .{ .direction = .child } });
    try tester.expectContent("pub fn demo() !u8 {\n    [return 5|;\n}\n");
    tester.executeCommand(.{ .ts_select_node = .{ .direction = .child } });
    try tester.expectContent("pub fn demo() !u8 {\n    [return| 5;\n}\n");
    tester.executeCommand(.{ .ts_select_node = .{ .direction = .child } });
    try tester.expectContent("pub fn demo() !u8 {\n    retur|n 5;\n}\n");
    tester.executeCommand(.{ .ts_select_node = .{ .direction = .child } });
    try tester.expectContent("pub fn demo() !u8 {\n    retur|n 5;\n}\n");
    tester.executeCommand(.{ .ts_select_node = .{ .direction = .child } });

    //
    // Insert line
    //
    tester.executeCommand(.{ .insert_line = .{ .direction = .down } });
    try tester.expectContent("pub fn demo() !u8 {\n    return 5;\n    |\n}\n");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .line } });
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("pub fn demo() !u8 {\n    return 5;|\n}\n");
    tester.executeCommand(.{ .insert_line = .{ .direction = .up } });
    try tester.expectContent("pub fn demo() !u8 {\n    |\n    return 5;\n}\n");

    //
    // Copy/Paste
    //
    var copy_arena_backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer copy_arena_backing.deinit();
    const copy_arena = copy_arena_backing.allocator();
    var copied: []const u8 = undefined;

    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .down, .mode = .duplicate, .metric = .byte, .stop = .byte } });
    try tester.expectContent("pub fn demo() !u8 {\n    |\n    |return 5;\n}\n");
    copied = tester.editor.copyAllocUtf8(copy_arena, .cut);
    try tester.expectContent("pub fn demo() !u8 {\n|}\n");
    tester.executeCommand(.{ .paste = .{ .text = copied } });
    try tester.expectContent("pub fn demo() !u8 {\n    \n    return 5;\n|}\n");

    tester.editor.executeCommand(.{ .click = .{ .pos = tester.pos(4) } });
    try tester.expectContent("pub |fn demo() !u8 {\n    \n    return 5;\n}\n");
    copied = tester.editor.copyAllocUtf8(copy_arena, .cut);
    try tester.expectContent("|    \n    return 5;\n}\n");
    tester.editor.executeCommand(.{ .click = .{ .pos = tester.pos(10) } });
    try tester.expectContent("    \n    r|eturn 5;\n}\n");
    tester.executeCommand(.{ .paste = .{ .text = copied } });
    try tester.expectContent("    \npub fn demo() !u8 {\n    r|eturn 5;\n}\n");
    tester.editor.executeCommand(.{ .click = .{ .pos = tester.pos(6) } });
    try tester.expectContent("    \np|ub fn demo() !u8 {\n    return 5;\n}\n");
    tester.editor.executeCommand(.{ .click = .{ .pos = tester.pos(6), .mode = .fromSelect(.word) } });
    try tester.expectContent("    \n[pub| fn demo() !u8 {\n    return 5;\n}\n");
    copied = tester.editor.copyAllocUtf8(copy_arena, .cut);
    try tester.expectContent("    \n| fn demo() !u8 {\n    return 5;\n}\n");
    tester.editor.executeCommand(.{ .click = .{ .pos = tester.pos(14) } });
    try tester.expectContent("    \n fn demo(|) !u8 {\n    return 5;\n}\n");
    tester.executeCommand(.{ .paste = .{ .text = copied } });
    try tester.expectContent("    \n fn demo(pub|) !u8 {\n    return 5;\n}\n");
    tester.executeCommand(.{ .paste = .{ .text = ", const" } });
    try tester.expectContent("    \n fn demo(pub, const|) !u8 {\n    return 5;\n}\n");

    copied = tester.editor.copyAllocUtf8(copy_arena, .cut);
    try tester.expectContent("    \n|    return 5;\n}\n");
    tester.executeCommand(.{ .paste = .{ .text = "abc" } });
    try tester.expectContent("    \nabc|    return 5;\n}\n");
    tester.executeCommand(.{ .paste = .{ .text = copied } });
    try tester.expectContent("    \nabc fn demo(pub, const) !u8 {\n|    return 5;\n}\n");

    //
    // ctrl + enter
    //
    tester.editor.executeCommand(.{ .move_cursor_left_right = .{ .direction = .left, .stop = .byte, .mode = .select } });
    try tester.expectContent("    \nabc fn demo(pub, const) !u8 {|\n]    return 5;\n}\n");
    tester.editor.executeCommand(.{ .insert_line = .{ .direction = .down } });
    try tester.expectContent("    \nabc fn demo(pub, const) !u8 {\n|\n    return 5;\n}\n");

    //
    // undo + redo
    //
    tester.executeCommand(.select_all);
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .byte } });
    try tester.expectContent("|");
    tester.editor.executeCommand(.{ .insert_line = .{ .direction = .down } });
    try tester.expectContent("\n|");
    tester.editor.executeCommand(.{ .insert_line = .{ .direction = .down } });
    try tester.expectContent("\n\n|");
    tester.editor.executeCommand(.{ .insert_line = .{ .direction = .down } });
    try tester.expectContent("\n\n\n|");
    tester.editor.executeCommand(.undo);
    try tester.expectContent("\n\n|");
    tester.editor.executeCommand(.undo);
    try tester.expectContent("\n|");
    tester.editor.executeCommand(.undo);
    try tester.expectContent("|");
    tester.editor.executeCommand(.redo);
    try tester.expectContent("\n|");
    tester.editor.executeCommand(.redo);
    try tester.expectContent("\n\n|");
    tester.editor.executeCommand(.redo);
    try tester.expectContent("\n\n\n|");
    tester.editor.executeCommand(.redo);
    try tester.expectContent("\n\n\n|");
    tester.editor.executeCommand(.undo);
    try tester.expectContent("\n\n|");

    tester.executeCommand(.select_all);
    try tester.expectContent("[\n\n|");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .byte } });
    try tester.expectContent("|");
    tester.editor.executeCommand(.undo);
    try tester.expectContent("[\n\n|");
    tester.editor.executeCommand(.redo);
    try tester.expectContent("|");

    for ("const std = @import(\"std\");") |char| {
        tester.executeCommand(.{ .insert_text = .{ .text = &.{char} } });
    }
    try tester.expectContent("const std = @import(\"std\");|");
    tester.editor.executeCommand(.undo);
    try tester.expectContent("const std = @import(|");
    tester.editor.executeCommand(.undo);
    try tester.expectContent("const std = @import|");
    tester.editor.executeCommand(.undo);
    try tester.expectContent("const std =|");
    tester.editor.executeCommand(.undo);
    try tester.expectContent("const std|");
    tester.editor.executeCommand(.undo);
    try tester.expectContent("const|");
    tester.editor.executeCommand(.undo);
    try tester.expectContent("|");
    for (0..6) |_| tester.executeCommand(.redo);
    try tester.expectContent("const std = @import(\"std\");|");
    for (0..tester.editor.document.value.length()) |_| tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .byte } });
    try tester.expectContent("|");
    tester.executeCommand(.undo);
    try tester.expectContent("const std = @import(\"std\");|");
    tester.executeCommand(.redo);
    try tester.expectContent("|");

    for ("abcd") |char| {
        tester.executeCommand(.{ .insert_text = .{ .text = &.{char} } });
    }
    try tester.expectContent("abcd|");
    tester.executeCommand(.undo);
    tester.executeCommand(.redo);
    for ("efgh") |char| {
        tester.executeCommand(.{ .insert_text = .{ .text = &.{char} } });
    }
    tester.executeCommand(.undo);
    try tester.expectContent("abcd|");
    tester.executeCommand(.undo);
    try tester.expectContent("|");

    //
    // replace_whole_file diff
    //
    tester.editor.executeCommand(.{ .replace_whole_file = .{ .new_text = "pub fn main() !void { return 5; }" } });
    try tester.expectContent("pub fn main() !void { return 5; }|");
    tester.editor.executeCommand(.{ .click = .{ .pos = tester.pos(29) } });
    try tester.expectContent("pub fn main() !void { return |5; }");
    tester.editor.executeCommand(.{ .replace_whole_file = .{ .new_text = "pub fn main() !void {\n    return 5;\n}" } });
    try tester.expectContent("pub fn main() !void {\n    return |5;\n}");
    tester.editor.executeCommand(.undo);
    try tester.expectContent("pub fn main() !void { return |5; }");

    // undo everything, see if it works
    while (tester.editor.undo.values.items.len > 0) {
        tester.editor.executeCommand(.undo);
    }
    try tester.expectContent("|hello!");
}

fn usi(a: u64) usize {
    return @intCast(a);
}
