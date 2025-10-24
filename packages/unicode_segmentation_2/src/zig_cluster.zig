const std = @import("std");
const Graphemes = @import("Graphemes");

const UnicodeCategory = enum {
    extend,
    len_1,
    len_2,
    len_3,
    len_4,
    invalid,
};
fn unicodeCategory(byte: u8) UnicodeCategory {
    return switch (byte) {
        0b0000_0000...0b0111_1111 => .len_1,
        0b1100_0000...0b1101_1111 => .len_2,
        0b1110_0000...0b1110_1111 => .len_3,
        0b1111_0000...0b1111_0111 => .len_4,
        0b1000_0000...0b1011_1111 => .extend,
        else => .invalid,
    };
}

// this is all wrong! both of these are assuming the index is centered on a codepoint,
// but what if it's not!
const RightCodepointIterator = struct {
    doc: GenericDocument,
    index: u64,
    right_buf: []const u8,
    fn init(doc: GenericDocument, index: u64) RightCodepointIterator {
        return .{
            .doc = doc,
            .index = index,
            .right_buf = if (index == doc.len) undefined else doc.read(doc, index, .right),
        };
    }
    fn nextByte(self: *RightCodepointIterator) ?u8 {
        if (self.index == self.doc.len) return null;
        std.debug.assert(self.right_buf.len != 0);
        const byte = self.right_buf[0];
        self.right_buf = self.right_buf[1..];
        self.index += 1;
        if (self.right_buf.len == 0) self.right_buf = self.doc.read(self.doc, self.index, .right);
        return byte;
    }
    fn fail(self: *RightCodepointIterator, backtrack: RightCodepointIterator) u21 {
        self.* = backtrack;
        return 0xFFFD;
    }
    fn next(self: *RightCodepointIterator) ?u21 {
        // slightly less nonsense function
        const b1 = self.nextByte() orelse return null;
        const backtrack = self.*;
        switch (unicodeCategory(b1)) {
            .len_1 => return b1,
            .len_2 => {
                const b2 = self.nextByte() orelse return self.fail(backtrack);
                return std.unicode.utf8Decode2(.{ b1, b2 }) catch return self.fail(backtrack);
            },
            .len_3 => {
                const b2 = self.nextByte() orelse return self.fail(backtrack);
                const b3 = self.nextByte() orelse return self.fail(backtrack);
                return std.unicode.utf8Decode3(.{ b1, b2, b3 }) catch return self.fail(backtrack);
            },
            .len_4 => {
                const b2 = self.nextByte() orelse return self.fail(backtrack);
                const b3 = self.nextByte() orelse return self.fail(backtrack);
                const b4 = self.nextByte() orelse return self.fail(backtrack);
                return std.unicode.utf8Decode4(.{ b1, b2, b3, b4 }) catch return self.fail(backtrack);
            },
            else => return self.fail(backtrack),
        }
    }
};
const LeftCodepointIterator = struct {
    doc: GenericDocument,
    index: u64,
    left_buf: []const u8,
    fn init(doc: GenericDocument, index: u64) LeftCodepointIterator {
        return .{
            .doc = doc,
            .index = index,
            .left_buf = if (index == 0) undefined else doc.read(doc, index, .left),
        };
    }
    fn nextByte(self: *LeftCodepointIterator) ?u8 {
        if (self.index == 0) return null;
        std.debug.assert(self.left_buf.len != 0);
        const byte = self.left_buf[self.left_buf.len - 1];
        self.left_buf = self.left_buf[0 .. self.left_buf.len - 1];
        self.index -= 1;
        if (self.left_buf.len == 0) self.left_buf = self.doc.read(self.doc, self.index, .left);
        return byte;
    }
    fn fail(self: *LeftCodepointIterator, backtrack: LeftCodepointIterator) u21 {
        self.* = backtrack;
        return 0xFFFD;
    }
    fn next(self: *LeftCodepointIterator) ?u21 {
        // nonsense function
        const b4 = self.nextByte() orelse return null;
        const backtrack = self.*;
        switch (unicodeCategory(b4)) {
            .len_1 => return b4,
            .extend => {},
            else => return self.fail(backtrack),
        }
        const b3 = self.nextByte() orelse return self.fail(backtrack);
        switch (unicodeCategory(b3)) {
            .len_2 => return std.unicode.utf8Decode2(.{ b3, b4 }) catch return self.fail(backtrack),
            .extend => {},
            else => return self.fail(backtrack),
        }
        const b2 = self.nextByte() orelse return self.fail(backtrack);
        switch (unicodeCategory(b2)) {
            .len_3 => return std.unicode.utf8Decode3(.{ b2, b3, b4 }) catch return self.fail(backtrack),
            .extend => {},
            else => return self.fail(backtrack),
        }
        const b1 = self.nextByte() orelse return self.fail(backtrack);
        switch (unicodeCategory(b1)) {
            .len_4 => return std.unicode.utf8Decode4(.{ b1, b2, b3, b4 }) catch return self.fail(backtrack),
            else => return self.fail(backtrack),
        }
    }
};
pub const GDirection = enum { left, right };
pub const GenericDocument = struct {
    data: *anyopaque,
    len: u64,

    /// returned pointer has to stay valid even across multiple calls to read()
    read: *const fn (self: GenericDocument, offset: u64, direction: GDirection) []const u8,

    pub fn from(comptime T: type, val: *const T, len: u64) GenericDocument {
        return .{ .data = @ptrCast(@constCast(val)), .len = len, .read = &T.read };
    }
    pub fn cast(self: GenericDocument, comptime T: type) *T {
        return @ptrCast(@alignCast(self.data));
    }
};
pub const SliceDocument = struct {
    slice: []const u8,
    pub fn read(self_g: GenericDocument, offset: u64, direction: GDirection) []const u8 {
        const self = self_g.cast(SliceDocument);
        return switch (direction) {
            .left => self.slice[0..@intCast(offset)],
            .right => self.slice[@intCast(offset)..],
        };
    }

    pub fn doc(self: *const SliceDocument) GenericDocument {
        return .from(SliceDocument, self, self.slice.len);
    }
};

const Rule = enum {
    GB1,
    GB2,
    GB3,
    GB4_5,
    GB6,
    GB7,
    GB8,
    GB9,
    GB9a,
    GB9b,
    GB9c,
    GB11,
    GB12_13,
    GB999,
    pub fn shouldBreak(self: Rule) bool {
        return switch (self) {
            .GB1, .GB2 => true,
            .GB3 => false,
            .GB4_5 => true,
            .GB6, .GB7, .GB8 => false,
            .GB9, .GB9a, .GB9b, .GB9c => false,
            .GB11, .GB12_13 => false,
            .GB999 => true,
        };
    }
};

// [...] [left] [right] | <- iter pointer
// https://unicode.org/reports/tr29/#GB1
// TODO: we can test that it returns the right rule code if we want
pub fn hasBoundary(doc: GenericDocument, start_idx: u64, data: *const Graphemes) Rule {
    const extended = true;

    var iter_main: LeftCodepointIterator = .init(doc, start_idx);
    var iter_right: RightCodepointIterator = .init(doc, start_idx);

    // GB1
    const left = iter_main.next() orelse return .GB1;

    // GB2
    const right = iter_right.next() orelse return .GB2;

    const left_gbp = data.gbp(left);
    const left_indic_prop = data.indic(left);

    const right_gbp = data.gbp(right);
    const right_indic_prop = data.indic(right);
    const right_is_emoji = data.isEmoji(right);

    // GB3
    if (left == '\r' and right == '\n') {
        return .GB3;
    }

    // GB4, GB5
    if (left_gbp == .Control or right_gbp == .Control or left == '\r' or left == '\n' or right == '\r' or right == '\n') {
        return .GB4_5;
    }

    // GB6
    if (left_gbp == .L and (right_gbp == .L or right_gbp == .V or right_gbp == .LV or right_gbp == .LVT)) {
        return .GB6;
    }

    // GB7
    if ((left_gbp == .LV or left_gbp == .V) and (right_gbp == .V or right_gbp == .T)) {
        return .GB7;
    }

    // GB8
    if ((left_gbp == .LVT or left_gbp == .T) and right_gbp == .T) {
        return .GB8;
    }

    // GB9
    if (right_gbp == .Extend or right_gbp == .ZWJ) {
        return .GB9;
    }

    if (extended) {
        // GB9a
        if (right_gbp == .SpacingMark) return .GB9a;

        // GB9b
        if (left_gbp == .Prepend) return .GB9b;
    }

    if (extended) extended: {
        // GB9c
        //  \p{InCB=Consonant} [ \p{InCB=Extend} \p{InCB=Linker} ]* \p{InCB=Linker} [ \p{InCB=Extend} \p{InCB=Linker} ]*
        // for ltr: if(isConsonant) { indic_match = 1 } else if(indic_match != 0 and isExtend) {} else if(indic_match != 0 and isLinker) {indic_match = 2} else {indic_match = 0}
        if ((left_indic_prop == .Linker or left_indic_prop == .Extend) and right_indic_prop == .Consonant) {
            var iter_dup = iter_main;
            var has_linker = left_indic_prop == .Linker;
            while (true) {
                const cp = iter_dup.next() orelse break :extended;
                switch (data.indic(cp)) {
                    .Linker => has_linker = true,
                    .Extend => {},
                    .Consonant => {
                        if (has_linker) return .GB9c;
                        break :extended;
                    },
                    else => break :extended,
                }
            }
        }
    }

    // GB11
    // for ltr: if(isEmoji) {emoji_match = true;} else if(emojiMatch and isExtend) {} else {emoji_match = false}
    if (left_gbp == .ZWJ and right_is_emoji) {
        var iter_dup = iter_main;
        while (true) {
            const codepoint = iter_dup.next() orelse break;
            const gbp = data.gbp(codepoint);
            if (gbp == .Extend) continue;
            const is_emoji = data.isEmoji(codepoint);
            if (is_emoji) return .GB11;
            break;
        }
    }

    // GB12, GB13
    // for ltr: if(isRegionalIndicator) {ri_state = !ri_state} else {ri_state = false}
    if (left_gbp == .Regional_Indicator and right_gbp == .Regional_Indicator) {
        var iter_dup = iter_main;
        var count: usize = 0;
        while (true) {
            const codepoint = iter_dup.next() orelse break;
            const gbp = data.gbp(codepoint);
            if (gbp != .Regional_Indicator) break;
            count += 1;
        }
        if (count % 2 == 0) return .GB12_13;
    }

    // GB999
    return .GB999;
}

// word break is easy
// first we need per-language Word_Break property values (zg doesn't provide yet but should be easy to add?)
// then it's the same as codepoint with a bunch of stuff

const LtrClusteringState = struct {
    state: enum(u2) {
        none, // consonant => indic_1, emoji => emoji, else => none
        emoji, // consonant => indic_1, extend => emoji, emoji => emoji, else => none
        indic_1, // consonant => indic_1, extend => indic_1, linker => indic_2, emoji => emoji, else => none
        indic_2, // consonant => indic_1, extend, linker => indic_2, emoji => emoji, else => none
    },
    ri_state: bool, // regional_indicator => !rl_state, else => false

    // so 3 bits. that's pretty good. could even be in one enum(u3) with a little care around regional indicators
    // unfortunately, this doesn't really let us backtrack from a point to test gb9c, gb11, gb12, gb13.
};

test hasBoundary {
    const allocator = std.testing.allocator;
    const gd = loadGraphemeDataSingleton();

    var out_codepoints = std.array_list.Managed(u8).init(allocator);
    defer out_codepoints.deinit();
    var out_breaks = std.array_list.Managed(bool).init(allocator);
    defer out_breaks.deinit();
    var out_break_pos = std.array_list.Managed(usize).init(allocator);
    defer out_break_pos.deinit();
    var out_break_idx = std.array_list.Managed(u64).init(allocator);
    defer out_break_idx.deinit();
    var line_iter = std.mem.splitScalar(u8, @embedFile("grapheme_break_test"), '\n');
    var line_no: usize = 0;
    while (line_iter.next()) |line_full| {
        line_no += 1;
        const line_hash = std.mem.indexOfScalar(u8, line_full, '#') orelse line_full.len;
        const line = std.mem.trimRight(u8, line_full[0..line_hash], " \t\r");
        var grapheme_break_tkz = GraphemeBreakTestTkz{
            .src = line,
            .idx = 0,
        };
        out_codepoints.clearRetainingCapacity();
        out_breaks.clearRetainingCapacity();
        out_break_pos.clearRetainingCapacity();
        out_break_idx.clearRetainingCapacity();
        try out_break_idx.append(0);
        grapheme_break_tkz.read(&out_codepoints, &out_breaks, &out_break_pos, &out_break_idx);
        if (out_codepoints.items.len == 0 and out_breaks.items.len == 0) continue;

        const doc = SliceDocument{ .slice = out_codepoints.items };
        for (out_breaks.items, out_break_pos.items, out_break_idx.items) |should_break, out_break_pos_val, i| {
            const actual = hasBoundary(doc.doc(), i, gd);
            if (actual.shouldBreak() != should_break) {
                std.log.err("grapheme_break_test:{d}:{d}: got {s}({s}), expected {s}:\n{f}\n{f}^", .{ line_no, out_break_pos_val, @tagName(actual), if (actual.shouldBreak()) "B" else "n", if (should_break) "B" else "n", ReplaceUnicode{ .slice = line_full }, Indenter{ .value = out_break_pos_val } });
            }
        }
    }
}
const ReplaceUnicode = struct {
    slice: []const u8,
    pub fn format(value: ReplaceUnicode, writer: *std.Io.Writer) !void {
        for (value.slice) |sli| {
            try writer.writeByte(switch (sli) {
                '\t' => '.',
                195 => ' ',
                183 => 'B',
                0x97 => 'n',
                else => sli,
            });
        }
    }
};
const Indenter = struct {
    value: usize,
    pub fn format(value: Indenter, writer: *std.Io.Writer) !void {
        try writer.splatByteAll(' ', value.value);
    }
};

const GraphemeBreakTestTkz = struct {
    src: []const u8,
    idx: usize,
    fn peekByte(self: *GraphemeBreakTestTkz) ?u8 {
        if (self.idx >= self.src.len) return null;
        return self.src[self.idx];
    }
    fn nextByte(self: *GraphemeBreakTestTkz) ?u8 {
        if (self.idx >= self.src.len) return null;
        const byte = self.src[self.idx];
        self.idx += 1;
        return byte;
    }
    fn read(self: *GraphemeBreakTestTkz, out_codepoints: *std.array_list.Managed(u8), out_breaks: *std.array_list.Managed(bool), out_break_pos: *std.array_list.Managed(usize), out_break_idx: *std.array_list.Managed(u64)) void {
        defer std.debug.assert(self.idx == self.src.len);
        while (true) {
            const start = self.idx;
            const byte = self.nextByte() orelse return;
            if (byte == 195) {
                const next = self.nextByte() orelse @panic("bad data");
                if (next == 183) {
                    out_breaks.append(true) catch @panic("oom");
                    out_break_pos.append(self.idx -| 1) catch @panic("oom");
                    continue;
                } else if (next == 0x97) {
                    out_breaks.append(false) catch @panic("oom");
                    out_break_pos.append(self.idx -| 1) catch @panic("oom");
                    continue;
                } else std.debug.panic("bad byte in if: {x}", .{next});
            }
            if (byte == ' ' or byte == '\r' or byte == '\t') continue;
            if (std.fmt.charToDigit(byte, 16)) |_| {
                while (self.peekByte()) |num| {
                    if (std.fmt.charToDigit(num, 16)) |_| {
                        _ = self.nextByte();
                    } else |_| {
                        break;
                    }
                }
                const slice = self.src[start..self.idx];
                const codepoint = std.fmt.parseInt(u21, slice, 16) catch @panic("bad data");
                out_codepoints.ensureUnusedCapacity(4) catch @panic("oom");
                out_codepoints.items.len += std.unicode.utf8Encode(codepoint, out_codepoints.unusedCapacitySlice()) catch @panic("bad data");
                out_break_idx.append(out_codepoints.items.len) catch @panic("oom");
                continue;
            } else |_| {}
            std.debug.panic("bad byte: {x}", .{byte});
        }
    }
};

// TODO: get tests from https://www.unicode.org/Public/UCD/latest/ucd/auxiliary/GraphemeBreakTest.txt
// zig fetch should support downloading that file i think. make sure to get a non-latest url though

/// initializes a GraphemeData. if called multiple times, only initializes once. never freed. thread-safe.
pub fn loadGraphemeDataSingleton() *const Graphemes {
    const Data = struct {
        var grapheme_data: std.atomic.Value(?*const Graphemes) = .init(null);
        var grapheme_data_value: Graphemes = undefined;
        var grapheme_data_mutex: std.Thread.Mutex = .{};
    };
    // I don't understand atomic orderings but the rest of this is in a mutex so it's probably to use unordered right?
    if (Data.grapheme_data.load(.unordered)) |value| {
        return value;
    } else {
        @branchHint(.cold);
        // mutex, so we'll never accidentally double-initialize GraphemeData
        Data.grapheme_data_mutex.lock();
        defer Data.grapheme_data_mutex.unlock();
        if (Data.grapheme_data.load(.unordered)) |value| {
            // other thread already got to it
            return value;
        }
        if (@import("builtin").target.os.tag == .windows and windows_output_hack) {
            _ = std.os.windows.kernel32.SetConsoleOutputCP(65001);
        }
        // initialize, under mutex
        Data.grapheme_data_value = Graphemes.init(std.heap.page_allocator) catch @panic("oom");
        Data.grapheme_data.store(&Data.grapheme_data_value, .unordered);
        return &Data.grapheme_data_value;
    }
}

// TODO: zig needs to fix its std.log.info() impl
const windows_output_hack = true;
