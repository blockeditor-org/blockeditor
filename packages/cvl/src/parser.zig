// parses to rpn
const std = @import("std");

pub const SrcLoc = packed struct(u64) {
    tag: enum(u1) { builtin, user },
    value: packed union {
        builtin: u63,
        user: packed struct(u63) {
            file_id: u31,
            offset: u32,
        },
    },

    pub fn fromFileOffset(file: u31, offset: u32) SrcLoc {
        return .{ .tag = .user, .value = .{ .user = .{ .file_id = file, .offset = offset } } };
    }
    pub fn fromSrc(comptime src: std.builtin.SourceLocation) SrcLoc {
        return .{ .tag = .builtin, .value = .{ .builtin = @intCast(@intFromPtr(&src)) } };
    }
};

pub const AstTree = struct {
    tags: []const AstNode.Tag,
    values: []const AstNode.Value,
    string_buf: []const u8,
    owner: Parser,
    pub fn deinit(self: *AstTree) void {
        self.owner.deinit();
    }

    pub fn tag(t: *const AstTree, node: AstExpr) AstNode.Tag {
        return t.tags[node.idx];
    }
    pub fn isAtom(t: *const AstTree, node: AstExpr) bool {
        return t.tag(node).isAtom();
    }
    pub fn atomValue(t: *const AstTree, atom_kind: AstNode.Tag, node: AstExpr) u32 {
        std.debug.assert(atom_kind.isAtom());
        std.debug.assert(t.tag(node) == atom_kind);
        return t.values[node.idx].atom_value;
    }
    pub fn exprLen(t: *const AstTree, node: AstExpr) u32 {
        std.debug.assert(!t.isAtom(node));
        return t.values[node.idx].expr_len;
    }
    pub fn src(t: *const AstTree, node: AstExpr) SrcLoc {
        if (t.isAtom(node)) {
            std.log.err("expected non-atom, got '{s}'", .{@tagName(t.tag(node))});
            unreachable;
        }
        var srcloc = t.firstChild(node);
        if (srcloc != null) while (t.next(srcloc.?)) |s| {
            srcloc = s;
        };
        if (srcloc == null or t.tag(srcloc.?) != .srcloc) return .fromFileOffset(0, 0);
        return .fromFileOffset(0, t.atomValue(.srcloc, srcloc.?));
    }

    pub fn firstChild(t: *const AstTree, node: AstExpr) ?AstExpr {
        std.debug.assert(!t.isAtom(node));
        const expr_len = t.exprLen(node);
        if (expr_len == 0) return null;
        return .{ .idx = node.idx + 1, .parent_end = node.idx + 1 + expr_len };
    }
    pub fn next(t: *const AstTree, node: AstExpr) ?AstExpr {
        const idx = switch (t.isAtom(node)) {
            true => node.idx + 1,
            false => node.idx + 1 + t.exprLen(node),
        };
        if (idx >= node.parent_end) {
            std.debug.assert(idx == node.parent_end);
            return null;
        }
        return .{ .idx = idx, .parent_end = node.parent_end };
    }
    pub fn children(t: *const AstTree, node: AstExpr, comptime n: usize) if (n == 1) AstExpr else [n]AstExpr {
        var res: [n]AstExpr = undefined;
        var itm = t.firstChild(node);
        for (&res) |*i| {
            i.* = itm.?;
            itm = t.next(itm.?);
        }
        std.debug.assert(t.tag(itm.?) == .srcloc);
        std.debug.assert(t.next(itm.?) == null);
        if (n == 1) return res[0];
        return res;
    }
    pub fn root(t: *const AstTree) AstExpr {
        return .{ .idx = 0, .parent_end = @intCast(t.tags.len) };
    }
    pub fn readStr(t: *const AstTree, offset: AstExpr, len: AstExpr) []const u8 {
        const offset_u32 = t.atomValue(.string_offset, offset);
        const len_u32 = t.atomValue(.string_len, len);
        return t.string_buf[offset_u32..][0..len_u32];
    }
};
pub const AstExpr = packed struct(u64) {
    idx: u32,
    parent_end: u32,
};

fn flipResult(tags: []AstNode.Tag, values: []AstNode.Value, src_index: usize, shift_right: usize) usize {
    const my_tag = tags[src_index];
    const my_value = values[src_index];
    const ch_len: usize = if (my_tag.isAtom()) 0 else my_value.expr_len;
    if (ch_len != 0) {
        var i = src_index - 1;
        while (true) {
            i -= flipResult(tags, values, i, shift_right + 1);
            if (i <= src_index - ch_len) break;
            i -= 1;
        }
    }
    tags[src_index + shift_right - ch_len] = my_tag;
    values[src_index + shift_right - ch_len] = my_value;
    return ch_len;
}

fn dumpAstNodes(tags: []const AstNode.Tag, values: []const AstNode.Value, w: std.Io.AnyWriter) !void {
    for (tags, values) |tag, value| {
        try w.print("[{s} {x}]", .{ @tagName(tag), if (tag.isAtom()) value.atom_value else value.expr_len });
    }
}
fn orderU32(context: u32, item: u32) std.math.Order {
    return std.math.order(context, item);
}

const Printer = struct {
    tree: *const AstTree,
    w: *std.Io.Writer,
    is_err: bool = false,
    indent: usize = 0,

    fn fmt(p: *Printer, comptime f: []const u8, a: anytype) void {
        p.w.print(f, a) catch {
            p.is_err = true;
        };
    }
    fn newline(p: *Printer) void {
        p.w.splatByteAll(' ', 4 * p.indent) catch {
            p.is_err = true;
        };
    }

    fn printExpr(p: *Printer, fc: AstExpr) void {
        switch (p.tree.tag(fc)) {
            else => |k| {
                p.fmt("<todo: {s}>", .{@tagName(k)});
            },
        }
    }

    fn printMapContents(p: *Printer, parent: AstExpr) void {
        var fch = p.tree.firstChild(parent).?;
        while (p.tree.tag(fch) != .srcloc) : (fch = p.tree.next(fch).?) {
            p.printExpr(fch);
            p.fmt(";", .{});
            p.newline();
        }
    }
    // validate this by reprinting and asserting the dest ast is === to the src ast excluding srclocs
    // for(src_ast_k, src_ast_v, dest_ast_k, dest_ast_v) |sa, sb, da, db| { std.debug.assert(sa == da); if(sa != .srcloc) std.debug.assert(sb == db); }
    fn printAst(p: *Printer, root: AstExpr) void {
        if (p.tree.tag(root) != .map) {
            p.is_err = true;
            return;
        }
        p.printMapContents(root);
    }
};

fn dumpAst(tree: *const AstTree, root: AstExpr, w: std.Io.AnyWriter, positions: []const u32, skip_outer: bool) !void {
    // custom value handling
    switch (tree.tag(root)) {
        .srcloc => {
            const idx = std.sort.binarySearch(u32, positions, tree.atomValue(.srcloc, root), orderU32) orelse {
                // not found
                try w.print("@<{d}>", .{tree.atomValue(.srcloc, root)});
                return;
            };
            try w.print("@{d}", .{idx});
            return;
        },
        .slot => {
            try w.print("slot", .{});
            return;
        },
        else => {},
    }
    if (!skip_outer) try w.print("[{s}", .{@tagName(tree.tag(root))});
    switch (tree.isAtom(root)) {
        true => {
            try w.print(" 0x{X}", .{tree.atomValue(tree.tag(root), root)});
        },
        false => {
            var fch = tree.firstChild(root);
            var is_first = true;
            while (fch) |ch| {
                if (!is_first or !skip_outer) try w.print(" ", .{});
                is_first = false;
                // string printing
                switch (tree.tag(ch)) {
                    .string_offset => {
                        // print string
                        const str_offset = tree.atomValue(.string_offset, ch);
                        fch = tree.next(ch);
                        std.debug.assert(fch != null);
                        std.debug.assert(tree.tag(fch.?) == .string_len);
                        const str_len = tree.atomValue(.string_len, fch.?);
                        try w.print("\"{f}\"", .{std.zig.fmtString(tree.string_buf[str_offset..][0..str_len])});
                    },
                    else => {
                        // default handling
                        try dumpAst(tree, ch, w, positions, false);
                    },
                }
                fch = tree.next(fch.?);
            }
        },
    }
    if (!skip_outer) try w.print("]", .{});
}

const AstNode = struct {
    const Tag = enum(u8) {
        // expr
        map, // [a, b, c]
        bind, // #a b : [decl a b]
        code, // {a; b; c} : [code [a] [b] [c]] ||| {a; b;} : [code [a] [b] [void]]
        builtin_std, // [builtin_std]
        map_entry, // "a": "b" : [map_entry [string "a"] [string "b"]]
        code_eql,
        string, // [string [string_offset string_len]]
        call, // a b : [call [a] [b]]
        err, // only intended for errors which should prevent any further compilation steps within the node. other errors should go in a list (TODO)
        err_skip, // ignore the contents of this
        ref,
        access, // a.b.c => [access [access a @0 b] @1 c]
        key,
        defer_expr,
        builtin,
        fn_def,
        init_void,
        marker,
        number,
        slot,
        with_slot,
        infix, // infix[string ...expr]
        prefix, // prefix[string, expr]

        // atom
        string_offset,
        string_len,
        srcloc,

        fn isAtom(tag: Tag) bool {
            return switch (tag) {
                .string_offset => true,
                .string_len => true,
                .srcloc => true,
                else => false,
            };
        }
    };
    const Value = union {
        atom_value: u32,
        expr_len: u32,
    };
    tag: Tag,
    value: Value,
};
const Token = enum {
    identifier,
    number, // not "123.456" or "-345", those are multiple tokens. we could support them maybe?
    symbols, // eg '=' or ':='
    sep, // ',' or ';'
    // '(', '[', '{', '}', ']', ')', '\'', ':', '.'
    map_begin,
    map_end,
    code_begin,
    code_end,
    unused_begin,
    unused_end,
    single_quote,
    double_quote,
    colon,
    dot,
    whitespace_inline,
    whitespace_newline,
    eof,
    bracket,
    equals,
    colon_equals,
    colon_colon,
    equals_gt,
    inline_comment,
    hashtag,
    kw_defer,
    kw_builtin,
    string_identifier_start,
    pipe, // '|'

    // string only
    string,
    string_backslash,

    // for tokenizer only
    _maybe_keyword,

    pub const izer = Tokenizer;
    pub fn name(t: Token) []const u8 {
        return @tagName(t);
    }
};
const reserved_symbols_map = std.StaticStringMap(Token).initComptime(.{
    .{ "=", .equals },
    .{ ":=", .colon_equals },
    .{ ":", .colon },
    .{ "::", .colon_colon },
    // .{ "//", .inline_comment }, // can't do it this way
    .{ "#", ._maybe_keyword },
    .{ "=>", .equals_gt },
});
const keywords_map = std.StaticStringMap(Token).initComptime(.{
    .{ "defer", .kw_defer },
    .{ "builtin", .kw_builtin },
});
const Tokenizer = struct {
    // TODO: consider enforcing correct indentation of code
    token: Token,
    token_start_srcloc: u32,
    token_end_srcloc: u32,

    source: []const u8,

    has_error: ?struct { pos: u32, byte: u8, msg: Emsg },
    in_string: bool,
    indent_level: u32,
    expected_indent_level: u32,
    this_line_opens: u32,
    this_line_opens_went_negative: bool,
    const Emsg = enum {
        invalid_byte,
        invalid_identifier,
        newline_not_allowed_in_string,
        char_not_allowed_in_indent,
        indent_must_be_in_fours,
        indent_wrong,
    };

    fn init(src: []const u8, state: State) Tokenizer {
        std.debug.assert(src.len < std.math.maxInt(u32));
        var res: Tokenizer = .{
            .source = src,
            .token = .eof,
            .token_start_srcloc = 0,
            .token_end_srcloc = 0,
            .has_error = null,
            .in_string = false,
            .indent_level = 0,
            .expected_indent_level = 0,
            .this_line_opens = 0,
            .this_line_opens_went_negative = false,
        };
        res.next(state);
        return res;
    }

    inline fn _setSingleByteToken(self: *Tokenizer, token: Token) void {
        self.token_end_srcloc += 1;
        self.token = token;
    }
    pub const State = enum { root, inside_string };
    fn next(self: *Tokenizer, state: State) void {
        defer {
            // std.log.err("tkz: {s} \"{f}\"", .{ @tagName(self.token), std.zig.fmtString(self.slice()) });
        }
        if (state == .inside_string) std.debug.assert(self.in_string);
        while (true) {
            self.token_start_srcloc = self.token_end_srcloc;
            var rem = self.source[self.token_end_srcloc..];
            if (rem.len == 0) {
                self.token = .eof;
                return;
            }
            switch (state) {
                .root => switch (rem[0]) {
                    ' ', '\t', '\r', '\n' => {
                        self.token = .whitespace_inline;
                        self.token_end_srcloc += for (rem, 0..) |byte, i| switch (byte) {
                            ' ', '\t', '\r' => {},
                            '\n' => {
                                if (self.in_string) {
                                    if (self.has_error == null) self.has_error = .{ .pos = @intCast(self.token_start_srcloc + i), .byte = '\n', .msg = .newline_not_allowed_in_string };
                                }
                                if (self.token == .whitespace_inline) {
                                    if (self.this_line_opens_went_negative) {
                                        if (self.expected_indent_level == 0) {
                                            self.has_error = .{ .pos = @intCast(self.token_start_srcloc + i), .byte = '\n', .msg = .indent_wrong };
                                        }
                                        self.expected_indent_level -|= 1;
                                    }
                                    if (self.indent_level != self.expected_indent_level) {
                                        std.log.err("expected indent level: {d}, got: {d}, at: {d}", .{ self.indent_level, self.expected_indent_level, self.token_start_srcloc + i });
                                        self.has_error = .{ .pos = @intCast(self.token_start_srcloc + i), .byte = '\n', .msg = .indent_wrong };
                                    }
                                    if (self.this_line_opens > 0) self.expected_indent_level += 1;
                                    self.this_line_opens = 0;
                                    self.this_line_opens_went_negative = false;
                                }
                                self.token = .whitespace_newline;
                            },
                            else => break @intCast(i),
                        } else @intCast(rem.len);
                        if (self.token == .whitespace_newline) {
                            var spc_count: u32 = 0;
                            var i = self.token_end_srcloc;
                            while (i > self.token_start_srcloc) {
                                i -= 1;
                                const byte = self.source[i];
                                switch (byte) {
                                    ' ' => spc_count += 1,
                                    '\n' => break,
                                    else => {
                                        if (self.has_error == null) self.has_error = .{ .pos = i, .byte = byte, .msg = .char_not_allowed_in_indent };
                                    },
                                }
                            } else unreachable; // it's a whitespace_newline therefore it must contain '\n'
                            if (spc_count % 4 != 0) {
                                self.has_error = .{ .pos = i, .byte = '\n', .msg = .indent_must_be_in_fours };
                                self.indent_level = 0; // only one error can be produced by the tokenizer, so it's fine that this will cause future errors
                            } else {
                                self.indent_level = @divExact(spc_count, 4);
                            }
                        }
                    },
                    'a'...'z', 'A'...'Z', '0'...'9', '_' => |c| {
                        self.token_end_srcloc += for (rem[1..], 1..) |byte, i| switch (byte) {
                            'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
                            else => break @intCast(i),
                        } else @intCast(rem.len);
                        if (std.ascii.isDigit(c)) {
                            self.token = .number;
                        } else {
                            self.token = .identifier;
                        }
                    },
                    ',', ';' => self._setSingleByteToken(.sep),
                    '"' => self._setSingleByteToken(.double_quote),
                    '\'' => self._setSingleByteToken(.single_quote),
                    '.' => self._setSingleByteToken(.dot),
                    '|' => self._setSingleByteToken(.pipe),
                    '{' => {
                        self.this_line_opens += 1;
                        self._setSingleByteToken(.code_begin);
                    },
                    '(' => {
                        self.this_line_opens += 1;
                        self._setSingleByteToken(.map_begin);
                    },
                    '[' => {
                        self.this_line_opens += 1;
                        self._setSingleByteToken(.unused_begin);
                    },
                    ']' => {
                        if (self.this_line_opens == 0) self.this_line_opens_went_negative = true;
                        self.this_line_opens -|= 1;
                        self._setSingleByteToken(.unused_end);
                    },
                    ')' => {
                        if (self.this_line_opens == 0) self.this_line_opens_went_negative = true;
                        self.this_line_opens -|= 1;
                        self._setSingleByteToken(.map_end);
                    },
                    '}' => {
                        if (self.this_line_opens == 0) self.this_line_opens_went_negative = true;
                        self.this_line_opens -|= 1;
                        self._setSingleByteToken(.code_end);
                    },
                    '~', '`', '!', '@', '#', '$', '%', '^', '&', '*', '-', '=', '+', '\\', '<', '>', '/', '?', ':' => {
                        self.token_end_srcloc += for (rem[1..], 1..) |byte, i| switch (byte) {
                            '~', '`', '!', '@', '#', '$', '%', '^', '&', '*', '-', '=', '+', '\\', '<', '>', '/', '?', ':' => {},
                            else => break @intCast(i),
                        } else @intCast(rem.len);
                        const tok_slice = self.slice();
                        self.token = reserved_symbols_map.get(tok_slice) orelse .symbols;
                        if (std.mem.startsWith(u8, tok_slice, "//")) {
                            // TODO: a comment at the start of a line should have to be on the same indent level as the line below it
                            self.token = .inline_comment;
                            const rem2 = self.source[self.token_end_srcloc..];
                            self.token_end_srcloc += for (rem2, 0..) |byte, i| switch (byte) {
                                '\n' => break @intCast(i), // the next token will be whitespace_newline
                                '\r' => {},
                                else => {
                                    if (byte < ' ' or byte == 0x7F) {
                                        if (self.has_error == null) self.has_error = .{ .byte = byte, .pos = @intCast(self.token_end_srcloc + i), .msg = .invalid_byte };
                                    }
                                },
                            } else @intCast(rem2.len);
                        } else if (self.token == ._maybe_keyword) {
                            const rem2 = self.source[self.token_end_srcloc..];
                            if (rem2.len > 0 and rem2[0] == '"') {
                                // string identifier
                                self.token = .string_identifier_start;
                                self.token_end_srcloc += 1;
                            } else {
                                self.token_end_srcloc += for (rem2[0..], 0..) |byte, i| switch (byte) {
                                    'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
                                    else => break @intCast(i),
                                } else @intCast(rem.len);
                                if (keywords_map.get(self.slice()[1..])) |kw| {
                                    self.token = kw;
                                } else {
                                    if (self.slice().len > 1) self.has_error = .{ .pos = self.token_start_srcloc, .byte = '\x00', .msg = .invalid_identifier };
                                    self.token_end_srcloc = self.token_start_srcloc + 1;
                                    self.token = .symbols;
                                }
                            }
                        }
                    },
                    else => |b| {
                        @branchHint(.cold);
                        // mark an error and ignore the byte
                        if (self.has_error == null) self.has_error = .{ .pos = self.token_start_srcloc, .byte = b, .msg = .invalid_byte };
                        self.token_start_srcloc += 1;
                        self.token_end_srcloc = self.token_start_srcloc;
                        continue;
                    },
                },
                .inside_string => switch (rem[0]) {
                    '"' => self._setSingleByteToken(.double_quote),
                    '\\' => self._setSingleByteToken(.string_backslash),
                    '\n' => {
                        @branchHint(.cold);
                        self.next(.root);
                        std.debug.assert(self.token == .whitespace_newline);
                        std.debug.assert(self.has_error != null);
                        self.token = .double_quote; // so the string doesn't end up spanning multiple lines
                    },
                    else => |b| {
                        if (b < ' ' or b == 0x7F) {
                            @branchHint(.cold);
                            // mark an error and ignore the byte
                            if (self.has_error == null) self.has_error = .{ .pos = self.token_start_srcloc, .byte = b, .msg = .invalid_byte };
                            self.token_start_srcloc += 1;
                            self.token_end_srcloc = self.token_start_srcloc;
                            continue;
                        }
                        // ok
                        self.token_end_srcloc += for (rem[1..], 1..) |byte, i| switch (byte) {
                            '"', '\\', 0...' ' - 1, 0x7F => break @intCast(i),
                            else => {},
                        } else @intCast(rem.len);
                        self.token = .string;
                    },
                },
            }
            break;
        }
    }
    fn slice(self: *Tokenizer) []const u8 {
        return self.source[self.token_start_srcloc..self.token_end_srcloc];
    }
};
const Parser = struct {
    gpa: std.mem.Allocator,

    tokenizer: Tokenizer,
    out_nodes: std.MultiArrayList(AstNode) = .empty,
    seen_strings: std.ArrayHashMapUnmanaged(StringMapKey, void, StringContext, true) = .empty,
    strings: std.ArrayListUnmanaged(u8) = .empty,
    has_errors: bool = false,
    has_fatal_error: ?enum { oom, src_too_long } = null,
    string_active: bool = false,

    pub fn init(src: []const u8, gpa: std.mem.Allocator) Parser {
        if (src.len > std.math.maxInt(u32) - 1000) {
            return .{ .gpa = gpa, .tokenizer = .init("", .root), .has_errors = true, .has_fatal_error = .oom };
        }
        return .{
            .gpa = gpa,
            .tokenizer = .init(src, .root),
        };
    }
    pub fn deinit(self: *Parser) void {
        self.out_nodes.deinit(self.gpa);
        self.strings.deinit(self.gpa);
        self.seen_strings.deinit(self.gpa);
    }

    fn postAtom(p: *Parser, atom: AstNode.Tag, value: u32) void {
        std.debug.assert(atom.isAtom());
        p.out_nodes.append(p.gpa, .{
            .tag = atom,
            .value = .{ .atom_value = value },
        }) catch p.oom();
    }
    fn wrapExpr(p: *Parser, expr: AstNode.Tag, start_node: usize, src: u32) void {
        std.debug.assert(!expr.isAtom());
        p.postAtom(.srcloc, src); // we could maybe maintain a second array just for srclocs that's only on exprs. and have [start, middle, end] for every.
        p.out_nodes.append(p.gpa, .{
            .tag = expr,
            .value = .{ .expr_len = @intCast(p.here().node - start_node) },
        }) catch p.oom();
    }
    fn wrapErr(p: *Parser, node: usize, srcloc: u32, comptime msg: []const u8, args: anytype) void {
        @branchHint(.cold);
        var str = p.stringBegin();
        str.print(msg, args);
        return p._wrapErrFormatted(node, srcloc, &str);
    }
    fn _wrapErrFormatted(p: *Parser, node: usize, srcloc: u32, str: *StringBuilder) void {
        const smk = str.end();
        if (!p.has_errors) {
            // std.log.err("Parser error: {d}:{s}", .{ srcloc, p.strings.items[smk.offset..][0..smk.len] });
        }
        p.has_errors = true;
        p.wrapExpr(.err_skip, node, srcloc); // wrap the previous junk in an error node so it can be easily skipped over
        p.postString(smk);
        p.wrapExpr(.err, node, srcloc);
    }
    fn oom(p: *Parser) void {
        p.has_errors = true;
        if (p.has_fatal_error == null) p.has_fatal_error = .oom;
    }

    const Here = struct { src: u32, node: usize };
    fn here(p: *Parser) Here {
        return .{ .src = p.tokenizer.token_start_srcloc, .node = p.out_nodes.len };
    }
    /// 0 is returned for eof, or if a null byte is encountered in the file
    fn asHex(c: u8) ?u4 {
        return switch (c) {
            '0'...'9' => @intCast(c - '0'),
            'a'...'f' => @intCast(c - 'a' + 10),
            'A'...'F' => @intCast(c - 'A' + 10),
            else => null,
        };
    }

    fn parseStrInner(p: *Parser, start_src: u32) void {
        const start = p.here();
        p.postString(p.parseStrInner_returnLastSegment(true));
        p.wrapExpr(.string, start.node, start_src);
    }
    fn parseStrInner_returnLastSegment(p: *Parser, allow_code_escape: bool) StringMapKey {
        var str = p.stringBegin();
        while (true) switch (p.tokenizer.token) {
            .string => {
                const txt = p.tokenizer.slice();
                p.assertEatToken(.string, .inside_string);
                str.appendSlice(txt);
            },
            // maybe instead of string_backslash we could have:
            // - escape_hex: '\xNN'
            // - escape_unicode: '\u{NNNN}'
            // - escape_backslash: '\\'
            // - escape_double_quote: '\"'
            // - escape_n: '\n',
            // - escape_r: '\r',
            // - escape_invalid: '\' : tokenizer marks an error and we just treat it as a strseg
            .string_backslash => {
                // string escape. tokenizer doesn't support this so here's a mess:
                p.tokenizer.token_start_srcloc = p.tokenizer.token_end_srcloc;
                const rem = p.tokenizer.source[p.tokenizer.token_start_srcloc..];
                if (rem.len > 0 and rem[0] == '{' and allow_code_escape) {
                    const start = p.here();
                    p.tokenizer.next(.root);
                    p.assertEatToken(.code_begin, .root);
                    p.postString(str.end());
                    p.parseCodeContents(start.src);
                    if (p.tokenizer.token != .code_end) {
                        p.wrapErr(start.node, start.src, "Expected {s}, found {s}", .{ Token.map_end.name(), p.tokenizer.token.name() });
                    }
                    p.tokenizer.next(.inside_string);
                    str = p.stringBegin();
                } else {
                    p.tokenizer.next(.inside_string);
                    switch (p.tokenizer.token) {
                        .string => {
                            @panic("TODO impl string x, u, r, n escapes");
                            // and indicate '(' is not allowed here if needed
                        },
                        .string_backslash => {
                            p.tokenizer.next(.inside_string);
                            str.append('\\');
                        },
                        .double_quote => {
                            p.tokenizer.next(.inside_string);
                            str.append('"');
                        },
                        .eof => {
                            // oop
                            break; // error handled outside of parseStrInner
                        },
                        else => unreachable,
                    }
                }
            },
            .double_quote, .eof => break,
            else => |a| std.debug.panic("unreachable: {s}", .{@tagName(a)}),
        };
        return str.end();
    }
    fn stringBegin(p: *Parser) StringBuilder {
        std.debug.assert(!p.string_active);
        p.string_active = true;
        return .{
            .p = p,
            .start = @intCast(p.strings.items.len),
        };
    }
    const StringBuilder = struct {
        p: *Parser,
        start: u32,

        // the first appendSlice could save txt to prevent an unnecessary copy
        // then if there's another one or a print(), commit it
        fn appendSlice(str: *StringBuilder, txt: []const u8) void {
            std.debug.assert(str.p.string_active);
            str.p.strings.appendSlice(str.p.gpa, txt) catch str.p.oom();
        }
        fn append(str: *StringBuilder, byte: u8) void {
            std.debug.assert(str.p.string_active);
            str.p.strings.append(str.p.gpa, byte) catch str.p.oom();
        }
        fn print(str: *StringBuilder, comptime fmt: []const u8, args: anytype) void {
            std.debug.assert(str.p.string_active);
            str.p.strings.writer(str.p.gpa).print(fmt, args) catch str.p.oom();
        }
        fn discard(str: *StringBuilder) void {
            std.debug.assert(str.p.string_active);
            str.p.strings.items.len = str.start;
            str.p.string_active = false;
            str.* = undefined;
        }
        fn end(str: *StringBuilder) StringMapKey {
            std.debug.assert(str.p.string_active);
            const res: StringMapKey = .{
                .offset = str.start,
                .len = @intCast(str.p.strings.items.len - str.start),
            };
            const gpres = str.p.seen_strings.getOrPutContext(str.p.gpa, res, .{ .strings_buf = str.p.strings.items }) catch {
                str.p.oom();
                str.discard();
                return .{ .offset = 0, .len = 0 };
            };
            if (gpres.found_existing) {
                // already exists. discard the new value
                str.p.strings.items.len = str.start;
            }
            str.p.string_active = false;
            str.* = undefined;
            return gpres.key_ptr.*;
        }
    };
    fn postString(p: *Parser, str_data: StringMapKey) void {
        p.postAtom(.string_offset, str_data.offset);
        p.postAtom(.string_len, str_data.len);
    }
    fn tryParseIdent(p: *Parser) ?StringMapKey {
        const tok_txt = p.tokenizer.slice();
        if (!p.tryEatToken(.identifier, .root)) {
            p.tokenizer.in_string = true;
            defer p.tokenizer.in_string = false;
            if (p.tryEatToken(.string_identifier_start, .inside_string)) {
                const last_seg = p.parseStrInner_returnLastSegment(false);
                if (!p.tryEatToken(.double_quote, .root)) {
                    // we're not really supposed to post an error in a random place like this
                    // this should be added to the error list instead
                    p.wrapErr(p.here().node, p.here().src, "Expected \" to end string identifier, found {s}", .{p.tokenizer.token.name()});
                }
                return last_seg;
            }
            return null;
        }
        var str = p.stringBegin();
        str.appendSlice(tok_txt);
        return str.end();
    }
    const ExprFinal = enum { map, other };
    fn tryParseExprFinal(p: *Parser) ?ExprFinal {
        const start = p.here();
        switch (p.tokenizer.token) {
            .double_quote => {
                p.tokenizer.in_string = true;
                defer p.tokenizer.in_string = false;
                p.assertEatToken(.double_quote, .inside_string);
                p.parseStrInner(start.src);
                if (!p.tryEatToken(.double_quote, .root)) {
                    p.wrapErr(start.node, p.here().src, "Expected \" to end string, found {s}", .{p.tokenizer.token.name()});
                }
                return .other;
            },
            .code_begin => {
                const indent = p.tokenizer.indent_level;
                p.assertEatToken(.code_begin, .root);
                p.parseCodeContents(start.src);
                if (p.tokenizer.indent_level != indent) {
                    p.wrapErr(start.node, p.here().src, "Expected close paren for code to be at the same indent level as its open bracket", .{});
                }
                if (!p.tryEatToken(.code_end, .root)) {
                    p.wrapErr(start.node, p.here().src, "Expected '{s}' to end map", .{Token.map_end.name()});
                }
                return .other;
            },
            .map_begin => {
                const indent = p.tokenizer.indent_level;
                p.assertEatToken(.map_begin, .root);
                p.parseMapContents(start.src);
                if (p.tokenizer.indent_level != indent) {
                    p.wrapErr(start.node, p.here().src, "Expected close bracket for map to be at the same indent level as its open bracket", .{});
                }
                if (!p.tryEatToken(.map_end, .root)) {
                    p.wrapErr(start.node, p.here().src, "Expected '{s}' to end map", .{Token.map_end.name()});
                }
                return .map;
            },
            .kw_builtin => {
                p.assertEatToken(.kw_builtin, .root);
                p.wrapExpr(.builtin, start.node, start.src);
                return .other;
            },
            .colon => {
                p.assertEatToken(.colon, .root);
                if (p.tryEatWhitespace()) p.wrapErr(start.node, p.here().src, "Expected no whitespace for marker", .{});
                const ident_src = p.here().src;
                if (p.tryParseIdent()) |iv| {
                    p.postString(iv);
                    p.wrapExpr(.ref, start.node, ident_src);
                    _ = p.tryEatWhitespace();
                    if (!p.tryParseExpr()) p.wrapErr(start.node, p.here().src, "Expected expression after marker", .{});
                    p.wrapExpr(.marker, start.node, start.src);
                } else {
                    p.wrapErr(start.node, p.here().src, "Expected ident for marker", .{});
                }
                return .other;
            },
            .number => {
                var str = p.stringBegin();
                str.appendSlice(p.tokenizer.slice());
                p.postString(str.end());
                p.assertEatToken(.number, .root);
                p.wrapExpr(.number, start.node, start.src);
                return .other;
            },
            else => {
                if (p.tryParseIdent()) |ident| {
                    p.postString(ident);
                    p.wrapExpr(.ref, start.node, start.src);
                    return .other;
                }
                return null; // no expr
            },
        }
    }
    fn tryParseExprWithSuffixes(p: *Parser) bool {
        var symbols = std.array_list.Managed(struct { start_node: usize, src: u32 }).init(p.gpa);
        defer symbols.deinit();
        if (p.tokenizer.token == .symbols) {
            const h = p.here();
            const sym = p.tokenizer.slice();
            p.tokenizer.next(.root);
            _ = p.tryEatWhitespace();

            const key = k: {
                var str = p.stringBegin();
                str.appendSlice(sym);
                break :k str.end();
            };
            p.postString(key);
            symbols.append(.{ .start_node = h.node, .src = h.src }) catch p.oom();
        }
        defer for (symbols.items) |symbol| {
            p.wrapExpr(.prefix, symbol.start_node, symbol.src);
        };

        const start = p.here();
        const parsed_expr_kind = p.tryParseExprFinal() orelse return false;
        if (parsed_expr_kind == .map) {
            const call_src = p.here().src;
            _ = p.tryEatWhitespace(); // (maybe error if no whitespace?)
            if (p.tryParseExpr()) {
                p.wrapExpr(.fn_def, start.node, call_src);
                return true;
            }
        }
        _ = p.wrapParseSuffixes(start);
        return true;
    }
    fn wrapParseSuffixes(p: *Parser, start: Here) void {
        while (true) {
            _ = p.tryEatWhitespace();
            switch (p.tokenizer.token) {
                .code_begin, .map_begin, .double_quote, .pipe => {
                    const call_src = p.here().src;
                    std.debug.assert(p.tryParseExprFinal() != null);
                    p.wrapExpr(.call, start.node, call_src);
                },
                .dot => {
                    const srcloc = p.here().src;
                    p.assertEatToken(.dot, .root);
                    _ = p.tryEatWhitespace();
                    const afterdot = p.here();
                    if (p.tryParseExprFinal() == null) {
                        p.wrapErr(p.here().node, p.here().src, "Expected expr after '.'", .{});
                    }
                    p.ensureExprValidAccessor(afterdot);
                    p.wrapExpr(.access, start.node, srcloc);
                    continue;
                },
                else => break,
            }
        }
    }
    fn ensureExprValidAccessor(p: *Parser, start: Here) void {
        var err = AstNode.Tag.err;
        const last_posted_expr = if (p.out_nodes.len > 0) &p.out_nodes.items(.tag)[p.out_nodes.len - 1] else &err;
        switch (last_posted_expr.*) {
            .ref => {
                // change to 'key'
                last_posted_expr.* = .key;
            },
            else => |t| {
                p.wrapErr(start.node, start.src, "Invalid expr type for access: {s}", .{@tagName(t)});
            },
        }
    }
    fn ensureExprValidColoncallTarget(p: *Parser, start: Here) void {
        var err = AstNode.Tag.err;
        const last_posted_expr = if (p.out_nodes.len > 0) &p.out_nodes.items(.tag)[p.out_nodes.len - 1] else &err;
        switch (last_posted_expr.*) {
            .map, .code => |t| {
                // a: (b)[c] is ok but `a: (b)` is not; must do `a(b)`
                p.wrapErr(start.node, start.src, "Cannot colon call with {s}, must {s} call instead.", .{ @tagName(t), @tagName(t) });
            },
            else => {
                // ok
            },
        }
    }
    fn tryParseExprWithDot(p: *Parser, mode: enum { allow_colon_call, deny_colon_call }) bool {
        const start = p.here();

        var needs_with_slot_wrap: bool = false;
        if (!p.tryParseExprWithSuffixes()) {
            if (p.tokenizer.token == .dot) {
                p.wrapExpr(.slot, start.node, start.src);
                p.wrapParseSuffixes(start);
                needs_with_slot_wrap = true;
            } else {
                return false;
            }
        }
        defer if (needs_with_slot_wrap) {
            p.wrapExpr(.with_slot, start.node, start.src);
        };

        _ = p.tryEatWhitespace();
        const call_src = p.here().src;
        if (!p.tryEatToken(.colon, .root)) return true;
        if (mode == .deny_colon_call) p.wrapErr(start.node, p.here().src, "Colon call not allowed here", .{});
        _ = p.tryEatWhitespace(); // (maybe error if no whitespace?)
        const before_exprparse = p.here();
        if (!p.tryParseExpr()) {
            p.wrapErr(start.node, p.here().src, "Expected expr after ':', found {s}", .{p.tokenizer.token.name()});
            return true;
        }
        p.ensureExprValidColoncallTarget(before_exprparse);
        // if we support map call & code call, consider disallowing those with a colon
        // ie `a: [b]` disallowed, requires `a[b]`. same `a: (b)` disallowed.
        p.wrapExpr(.call, start.node, call_src);
        return true;
    }
    fn tryParseExprWithInfix(p: *Parser) bool {
        // a + b: c <- not allowed
        const begin = p.here();
        if (!p.tryParseExprWithDot(.allow_colon_call)) return false;
        _ = p.tryEatWhitespace();
        if (p.tokenizer.token != .symbols) return true;
        const sym_here = p.here();
        const sym = p.tokenizer.slice();
        p.tokenizer.next(.root);
        const key = k: {
            var str = p.stringBegin();
            str.appendSlice(sym);
            break :k str.end();
        };
        p.postString(key);
        while (true) {
            _ = p.tryEatWhitespace();
            if (!p.tryParseExprWithDot(.deny_colon_call)) {
                // end. use last symbols as a suffix
                p.wrapErr(begin.node, begin.src, "expected expression", .{});
                break;
            }
            _ = p.tryEatWhitespace();
            if (p.tokenizer.token != .symbols) break;

            if (!std.mem.eql(u8, sym, p.tokenizer.slice())) {
                p.wrapErr(begin.node, begin.src, "mixed infix exprs not allowed. first operator: \"{f}\" ({d}), this operator: \"{f}\"", .{ std.zig.fmtString(sym), sym_here.src, std.zig.fmtString(p.tokenizer.slice()) });
            }
            p.tokenizer.next(.root);
        }
        p.wrapExpr(.infix, begin.node, sym_here.src);
        return true;
    }
    fn tryParseExpr(p: *Parser) bool {
        return p.tryParseExprWithInfix();
    }
    fn tryParseCodeOrMapExpr(p: *Parser, mode: enum { code, map }) bool {
        const begin = p.here();

        switch (p.tokenizer.token) {
            .kw_defer => {
                p.assertEatToken(.kw_defer, .root);
                _ = p.tryEatWhitespace();
                if (!p.tryParseExpr()) {
                    p.wrapErr(begin.node, begin.src, "expected expression after 'defer'", .{});
                }
                p.wrapExpr(.defer_expr, begin.node, begin.src);
                if (mode != .code) {
                    p.wrapErr(begin.node, begin.src, "defer is not allowed here", .{});
                }

                return true;
            },
            else => {},
        }

        if (!p.tryParseExpr()) return false;
        _ = p.tryEatWhitespace();
        const eql_loc = p.here();
        switch (p.tokenizer.token) {
            .equals, .colon_equals, .colon_colon => |t| {
                p.assertEatToken(t, .root);
                _ = p.tryEatWhitespace();
                if (!p.tryParseExpr()) {
                    p.wrapErr(p.here().node, p.here().src, "Expected expr here", .{});
                }
                p.wrapExpr(switch (t) {
                    .colon_equals, .colon_colon => .bind,
                    .equals => switch (mode) {
                        .code => .code_eql,
                        .map => .map_entry,
                    },
                    else => unreachable,
                }, begin.node, eql_loc.src);
                return true;
            },
            else => return true,
        }
    }
    fn tryParseCodeExpr(p: *Parser) bool {
        return p.tryParseCodeOrMapExpr(.code);
    }
    fn tryParseMapExpr(p: *Parser) bool {
        return p.tryParseCodeOrMapExpr(.map);
    }
    fn assertEatToken(p: *Parser, token: Token, next: Tokenizer.State) void {
        std.debug.assert(p.tokenizer.token == token);
        p.tokenizer.next(next);
    }
    fn tryEatToken(p: *Parser, token: Token, next: Tokenizer.State) bool {
        if (p.tokenizer.token == token) {
            p.assertEatToken(token, next);
            return true;
        }
        return false;
    }
    fn tryEatWhitespace(p: *Parser) bool {
        var success = false;
        while (p.tokenizer.token == .whitespace_inline or p.tokenizer.token == .whitespace_newline or p.tokenizer.token == .inline_comment) {
            success = true;
            p.tokenizer.next(.root);
        }
        return success;
    }
    fn parseMapContents(p: *Parser, start_src: u32) void {
        const start = p.here();

        _ = p.tryEatWhitespace();
        while (p.tryParseMapExpr()) {
            _ = p.tryEatWhitespace();
            if (!p.tryEatToken(.sep, .root)) break;
            _ = p.tryEatWhitespace();
        }

        p.wrapExpr(.map, start.node, start_src);
    }
    fn parseCodeContents(p: *Parser, start_src: u32) void {
        const start = p.here();

        _ = p.tryEatWhitespace();
        const needs_injected_void = while (p.tryParseCodeExpr()) {
            _ = p.tryEatWhitespace();
            if (!p.tryEatToken(.sep, .root)) break false;
            _ = p.tryEatWhitespace();
        } else true;

        if (needs_injected_void) p.wrapExpr(.init_void, p.here().node, p.here().src);
        p.wrapExpr(.code, start.node, start_src);
    }
    fn parseFile(p: *Parser) void {
        const start = p.here();
        p.parseMapContents(start.src);
    }
};

pub fn parse(gpa: std.mem.Allocator, src: []const u8) AstTree {
    var p = Parser.init(src, gpa);
    const start = p.here();
    p.parseFile();
    if (p.tokenizer.token_start_srcloc < p.tokenizer.source.len) {
        p.wrapErr(start.node, p.tokenizer.token_start_srcloc, "Unexpected token: {s}", .{p.tokenizer.token.name()});
    }
    if (p.tokenizer.has_error) |tkz_err| switch (tkz_err.msg) {
        .newline_not_allowed_in_string => p.wrapErr(start.node, tkz_err.pos, "Newline not allowed inside string", .{}),
        .invalid_identifier => p.wrapErr(start.node, tkz_err.pos, "Invalid identifier", .{}),
        .invalid_byte => if (tkz_err.byte >= ' ' and tkz_err.byte < 0x7F) {
            p.wrapErr(start.node, tkz_err.pos, "Invalid character: \"{f}\"", .{std.zig.fmtString(&.{tkz_err.byte})});
        } else if (tkz_err.byte >= 0x80) {
            p.wrapErr(start.node, tkz_err.pos, "Unicode characters are not allowed outside of strings", .{});
        } else {
            p.wrapErr(start.node, tkz_err.pos, "Invalid byte in file: 0x{X:0>2}", .{tkz_err.byte});
        },
        .char_not_allowed_in_indent => p.wrapErr(start.node, tkz_err.pos, "Character \"{f}\" not allowed in indent", .{std.zig.fmtString(&.{tkz_err.byte})}),
        .indent_must_be_in_fours => p.wrapErr(start.node, tkz_err.pos, "Indentation must be in fours", .{}),
        .indent_wrong => p.wrapErr(start.node, tkz_err.pos, "Wrong level of indentation", .{}),
    };
    // now serialize and test snapshot
    const tree: AstTree = .{ .tags = p.out_nodes.items(.tag), .values = p.out_nodes.items(.value), .string_buf = p.strings.items, .owner = p };
    if (p.out_nodes.len > 0 and p.has_fatal_error == null) {
        std.debug.assert(flipResult(@constCast(tree.tags), @constCast(tree.values), p.out_nodes.len - 1, 0) == p.out_nodes.len - 1);
    }
    return tree;
}

pub fn testParser(out: *std.array_list.Managed(u8), opt: struct { no_lines: bool = false }, src_in: []const u8) ![]const u8 {
    const gpa = out.allocator;
    var src = std.array_list.Managed(u8).init(gpa);
    defer src.deinit();
    var positions = std.array_list.Managed(u32).init(gpa);
    defer positions.deinit();
    if (!opt.no_lines) {
        var src_rem = src_in;
        while (src_rem.len > 0) {
            const next = std.mem.indexOfScalar(u8, src_rem, '|') orelse src_rem.len;
            try src.appendSlice(src_rem[0..next]);
            src_rem = src_rem[next..];
            if (src_rem.len > 0) {
                std.debug.assert(src_rem[0] == '|');
                try positions.append(@intCast(src.items.len));
                src_rem = src_rem[1..];
            }
        }
    } else {
        try src.appendSlice(src_in);
    }

    const sample_src = src.items;

    var tree = parse(gpa, sample_src);
    defer tree.deinit();

    var fmt_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer fmt_buf.deinit(gpa);

    if (tree.owner.has_fatal_error) |fe| {
        if (fe == .oom) return error.OutOfMemory;
        try fmt_buf.appendSlice(gpa, @tagName(fe));
    } else if (tree.tags.len > 0) {
        const node: AstExpr = tree.root();
        const skip_outer = tree.tag(node) == .map;
        try dumpAst(&tree, node, fmt_buf.writer(gpa).any(), positions.items, skip_outer);
    }

    out.clearRetainingCapacity();
    try out.appendSlice(fmt_buf.items);
    return out.items;
}
fn testPrinter(out: *std.array_list.Managed(u8), _: struct {}, src_in: []const u8) ![]const u8 {
    const gpa = out.allocator;

    var tree = parse(gpa, src_in);
    defer tree.deinit();

    var fmt_buf: std.Io.Writer.Allocating = .init(gpa);
    defer fmt_buf.deinit();

    if (tree.owner.has_fatal_error) |fe| {
        if (fe == .oom) return error.OutOfMemory;
        try fmt_buf.writer.writeAll(@tagName(fe));
    } else if (tree.tags.len > 0) {
        const node: AstExpr = tree.root();
        var printer: Printer = .{
            .tree = &tree,
            .w = &fmt_buf.writer,
        };
        printer.printAst(node);
        if (printer.is_err) return error.OutOfMemory;
    }

    out.clearRetainingCapacity();
    try out.appendSlice(fmt_buf.written());
    return out.items;
}

const snap = @import("anywhere").util.testing.snap;
fn doTestParser(gpa: std.mem.Allocator) !void {
    var out = std.array_list.Managed(u8).init(gpa);
    defer out.deinit();
    try snap(@src(),
        \\[string "Hello, world!" @0] @0
    , try testParser(&out, .{}, "|\"Hello, world!\""));
    try snap(@src(),
        \\[err [err_skip [string "Hello, world!" @0] @1] "Expected \" to end string, found eof" @1] @0
    , try testParser(&out, .{}, "|\"Hello, world!|"));
    try snap(@src(),
        \\[err [err_skip [map [string "Hello, world!" @0] @0] @1] "Invalid byte in file: 0x1B" @1]
    , try testParser(&out, .{}, "|\"Hello, world!|\x1b\""));
    try snap(@src(),
        \\[ref "abc" @0] @0
    , try testParser(&out, .{}, "|abc"));
    try snap(@src(),
        \\[err [err_skip [map [ref "abc" @0] @0] @1] "Unexpected token: unused_end" @1]
    , try testParser(&out, .{}, "|abc|]"));
    try snap(@src(),
        \\[ref "abc" @1] [ref "def" @2] [ref "ghi" @3] @0
    , try testParser(&out, .{}, "|  |abc, |def   ;|ghi "));
    try snap(@src(),
        \\[call [access [access [ref "std" @1] [key "math" @3] @2] [key "pow" @5] @4] [string "abc" @7] @6] @0
    , try testParser(&out, .{}, "|  |std|.|math|.|pow|: |\"abc\" "));
    try snap(@src(),
        \\[map_entry [with_slot [access slot [key "key" @2] @1] @1] [ref "value" @4] @3] @0
    , try testParser(&out, .{}, "|  |.|key |= |value "));
    // TODO: string escapes
    // try snap(@src(), "@0 [string \"\\x1b[3m\\xe1\\x88\\xb4\\\"\" @0]", try testParser(&out, .{}, "|\"\\x1b[3m\\u{1234}\\\"\""));
    try snap(@src(),
        \\[string "hello " [code [ref "user" @2] @1] "" @0] @0
    , try testParser(&out, .{},
        \\|"hello \|{|user}"
    ));
    try snap(@src(),
        \\[err [err_skip [map [string "hello " [code [ref "user" @3] @1] "" @0] @0] @2] "Newline not allowed inside string" @2]
    , try testParser(&out, .{},
        \\|"hello \|{|
        \\    |user
        \\}"
    ));
    try snap(@src(),
        \\[bind [ref "builtin" @0] [ref "__builtin__" @2] @1] @0
    , try testParser(&out, .{}, "|builtin |:= |__builtin__"));
    try snap(@src(),
        \\[call [code [with_slot [call [access slot [key "implicit" @2] @1] [with_slot [access slot [key "arg1" @5] @4] @4] @3] @1] @0] [with_slot [access slot [key "arg2" @8] @7] @7] @6] @0
    , try testParser(&out, .{}, "|{|.|implicit|: |.|arg1}|: |.|arg2"));
    try snap(@src(),
        \\[code [defer_expr [ref "error" @2] @1] @0] @0
    , try testParser(&out, .{}, "|{|#defer |error}"));
    try snap(@src(),
        \\[access [ref "my identifier" @0] [key "my field" @2] @1] @0
    , try testParser(&out, .{}, "|#\"my identifier\"|.|#\"my field\""));
    try snap(@src(),
        \\[fn_def [map [call [ref "arg" @1] [ref "ArgType" @3] @2] @0] [ref "body" @4] @<14>] @0
    , try testParser(&out, .{}, "|(|arg|: |ArgType) |body"));
    try snap(@src(),
        \\[marker [ref "return" @1] [code [call [ref "return" @3] [number "5" @5] @4] @2] @0] @0
    , try testParser(&out, .{}, "|:|return |{|return|: |5}"));
    try snap(@src(),
        \\[call [prefix "*" [ref "a" @1] @0] [ref "b" @4] @2] @0
    , try testParser(&out, .{}, "|*|a|:| |b"));
    // try snap(@src(),
    //     \\
    // , try testParser(&out, .{}, @embedFile("sample2.cvl")));

    // extending a = b syntax
    // a = b defines a map_entry
    // in a struct definition we want to be able to define:
    // - fields, with a type and default value. field name is a 'key' (or a symbol for private fields)
    // - public decls, accessible with T.decl. field name is a 'key' or a symbol
    // - name bindings, accessible inside the struct with the name. field name is a 'var'
    // in a code, we want to be able to define:
    // - name binding decls, accessible within the code with the name.
    // - name binding non-decls

    // std.struct [  ]

    try snap(@src(),
        \\<todo: map_entry>;
    , try testPrinter(&out, .{},
        \\one = two;
    ));
}
test Parser {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, doTestParser, .{});
}
// fn fuzzParser(input: []const u8) anyerror!void {
//     try testParser(std.testing.allocator, .{}, input);
// }
// test "parser fuzz" {
//     try std.testing.fuzz(fuzzParser, .{});
// }

const StringMapKey = struct {
    offset: u32,
    len: u32,
};
pub const StringContext = struct {
    strings_buf: []const u8,

    pub fn hash(self: @This(), s: StringMapKey) u32 {
        return @as(u32, @truncate(std.hash.Wyhash.hash(0, self.strings_buf[s.offset..][0..s.len])));
    }
    pub fn eql(self: @This(), fetch_key: StringMapKey, item_key: StringMapKey, _: usize) bool {
        return std.mem.eql(u8, self.strings_buf[item_key.offset..][0..item_key.len], self.strings_buf[fetch_key.offset..][0..fetch_key.len]);
    }
};

// struct syntax:
//   fields:
//   - (destructuring only): required binding name
//   - optional name (none = tuple)
//   - required type (optional when destructuring)
//   - optional default value
//   publics: type vs value
//   - all decls define getters
//   - there are no setters because setting requires a pointer. so a setter is just a
//     getter that returns a mutable pointer
//   - a public value is a comptime field in zig. same thing
//   decls:
//   - it would be nice to be able to define a decl and a public at the same time
//
// so destructuring is:
//    bind ?.name :: ?type := ?value
// regular is
//    ?.name :: type = ?value
// accessor is
//    %comptime ?.name = value
// decl is
//    bind := value
// binding type accessor is
//    bind ?.name := value
// binding value accessor is
//    bind ?.name := value
//
// maybe we seperate static and value things?
// ??????????

test {
    _ = @import("compiler.zig");
}
