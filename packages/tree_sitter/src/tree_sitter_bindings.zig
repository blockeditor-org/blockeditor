const std = @import("std");
pub const tree_sitter = @import("tree_sitter_translatec");

pub const Point = tree_sitter.TSPoint;
pub const Input = struct {
    input: tree_sitter.TSInput,

    pub fn from(encoding: enum { utf8 }, payload: anytype, comptime read_fn: fn (data: @TypeOf(payload), byte_offset: u32, point: Point) []const u8) Input {
        return .{ .input = .{
            .encoding = switch (encoding) {
                .utf8 => tree_sitter.TSInputEncodingUTF8,
            },
            .payload = @ptrCast(@constCast(payload)),
            .read = &struct {
                fn read(data: ?*anyopaque, byte_offset: u32, point: Point, bytes_read: [*c]u32) callconv(.c) [*c]const u8 {
                    const res = read_fn(@ptrCast(@alignCast(data)), byte_offset, point);
                    bytes_read.* = @intCast(res.len);
                    return res.ptr;
                }
            }.read,
        } };
    }
};

pub const Parser = struct {
    parser: *tree_sitter.TSParser,

    pub inline fn init() Parser {
        return .{ .parser = tree_sitter.ts_parser_new().? };
    }
    pub inline fn deinit(self: Parser) void {
        tree_sitter.ts_parser_delete(self.parser);
    }

    pub inline fn setLanguage(self: Parser, lang: *Language) !void {
        if (!tree_sitter.ts_parser_set_language(self.parser, @ptrCast(lang))) return error.VersionMismatch;
    }

    pub inline fn parse(self: Parser, old_tree: ?Tree, input: Input) Tree {
        return .{ .tree = tree_sitter.ts_parser_parse(self.parser, if (old_tree) |t| t.tree else null, input.input).? };
    }
};

pub const Tree = struct {
    tree: *tree_sitter.TSTree,
    pub inline fn deinit(self: Tree) void {
        tree_sitter.ts_tree_delete(self.tree);
    }

    pub inline fn edit(self: Tree, edit_val: InputEdit) void {
        tree_sitter.ts_tree_edit(self.tree, &edit_val);
    }
    pub inline fn rootNode(self: Tree) Node {
        return Node.from(tree_sitter.ts_tree_root_node(self.tree)).?;
    }
};
pub const InputEdit = tree_sitter.TSInputEdit;

pub const Language = opaque {
    pub inline fn language(self: *Language) *tree_sitter.TSLanguage {
        return @ptrCast(self);
    }
    pub inline fn symbolName(self: *Language, symbol: Symbol) [:0]const u8 {
        return std.mem.span(tree_sitter.ts_language_symbol_name(self.language(), symbol));
    }
    pub inline fn symbolCount(self: *Language) u32 {
        return tree_sitter.ts_language_symbol_count(self.language());
    }
    pub inline fn fieldIdForName(self: *Language, field_name: []const u8) FieldId {
        return tree_sitter.ts_language_field_id_for_name(self.language(), field_name.ptr, @intCast(field_name.len));
    }
};
pub const Symbol = tree_sitter.TSSymbol;
pub const FieldId = tree_sitter.TSFieldId;

pub const Node = struct {
    // WISHLIST: don't allow node to be null. impl `.from(v: tree_sitter.Node) -> ?Node`,
    // and rename `node: ` to `node_not_null: ` to catch all initializaitons.
    // remove `.isNull()`

    node_not_null: tree_sitter.TSNode,
    pub inline fn from(node: tree_sitter.TSNode) ?Node {
        if (tree_sitter.ts_node_is_null(node)) return null;
        return .{ .node_not_null = node };
    }
    pub inline fn startByte(self: Node) u32 {
        return tree_sitter.ts_node_start_byte(self.node_not_null);
    }
    pub inline fn endByte(self: Node) u32 {
        return tree_sitter.ts_node_end_byte(self.node_not_null);
    }
    pub inline fn docbyteInRange(self: Node, docbyte: u64) bool {
        return docbyte >= self.startByte() and docbyte < self.endByte();
    }
    pub inline fn eq(self: ?Node, other: ?Node) bool {
        if (self == null or other == null) return self == null and other == null;
        return tree_sitter.ts_node_eq(self.?.node_not_null, other.?.node_not_null);
    }

    pub inline fn symbol(self: Node) Symbol {
        return tree_sitter.ts_node_symbol(self.node_not_null);
    }
    pub inline fn descendantForByteRange(self: Node, left: u32, right: u32) ?Node {
        return .from(tree_sitter.ts_node_descendant_for_byte_range(self.node_not_null, left, right));
    }
    /// do not use! slow! also may be broken and in need of a tree sitter update
    pub inline fn slowParent(self: Node) ?Node {
        return .from(tree_sitter.ts_node_parent(self.node_not_null));
    }
    /// do not use! slow! internally calls parent()!
    pub inline fn slowChild(self: Node, child_index: u32) ?Node {
        return .from(tree_sitter.ts_node_child(self.node_not_null, child_index));
    }
    /// probably don't use this!
    pub inline fn slowChildByFieldId(self: Node, field_id: FieldId) ?Node {
        return .from(tree_sitter.ts_node_child_by_field_id(self.node_not_null, field_id));
    }
};
pub const TreeCursor = struct {
    stack: std.array_list.Managed(Node),
    cursor: tree_sitter.TSTreeCursor,
    last_access: u32,

    pub inline fn init(gpa: std.mem.Allocator, root_node: Node) TreeCursor {
        var res_stack = std.array_list.Managed(Node).init(gpa);
        res_stack.append(root_node) catch @panic("oom");
        return .{ .stack = res_stack, .cursor = tree_sitter.ts_tree_cursor_new(root_node.node_not_null), .last_access = 0 };
    }
    pub inline fn deinit(self: *TreeCursor) void {
        tree_sitter.ts_tree_cursor_delete(&self.cursor);
        self.stack.deinit();
    }
    pub inline fn gotoFirstChild(self: *TreeCursor) bool {
        if (tree_sitter.ts_tree_cursor_goto_first_child(&self.cursor)) {
            self.stack.append(self._currentNode_raw()) catch @panic("oom");
            return true;
        } else return false;
    }
    pub inline fn gotoParent(self: *TreeCursor) bool {
        if (tree_sitter.ts_tree_cursor_goto_parent(&self.cursor)) {
            _ = self.stack.pop();
            return true;
        } else return false;
    }
    pub inline fn gotoNextSibling(self: *TreeCursor) bool {
        if (tree_sitter.ts_tree_cursor_goto_next_sibling(&self.cursor)) {
            _ = self.stack.pop();
            self.stack.append(self._currentNode_raw()) catch @panic("oom");
            return true;
        } else return false;
    }

    pub inline fn _currentNode_raw(self: *TreeCursor) Node {
        return Node.from(tree_sitter.ts_tree_cursor_current_node(&self.cursor)).?;
    }
    pub inline fn currentNode(self: *TreeCursor) Node {
        std.debug.assert(self.stack.getLast().eq(self._currentNode_raw()));
        return self.stack.getLast();
    }

    pub fn goDeepLhs(self: *TreeCursor) void {
        while (self.gotoFirstChild()) {}
    }

    /// before using for the first time, must initialize TreeCursor on the root node and call .goDeepLhs();
    /// returns an index into TreeCursor's stack ArrayList
    pub fn advanceAndFindNodeForByte(cursor: *TreeCursor, byte: u32) usize {
        std.debug.assert(byte >= cursor.last_access);
        cursor.last_access = byte;

        // first, advance if necessary
        if (byte >= cursor.currentNode().endByte()) {
            // need to advance
            // 1. find the lowest node who's parent contains the current docbyte

            while (true) {
                if (cursor.stack.items.len < 2) return 0;
                const parent_node = cursor.stack.items[cursor.stack.items.len - 2];
                if (parent_node.docbyteInRange(byte)) {
                    // perfect node!
                    break;
                } else {
                    // not wide enough, go up one
                    std.debug.assert(cursor.gotoParent());
                    continue;
                }
            }

            // 2. advance next sibling until one covers our range
            while (byte >= cursor.currentNode().endByte()) {
                if (!cursor.gotoNextSibling()) {
                    // cursor has no next sibling. go parent
                    std.debug.assert(cursor.gotoParent());
                    return cursor.stack.items.len - 1; // no more siblings, but parent is known to cover our range
                }
            }

            // 3. goDeepLhs on final result, but skip by any nodes left of us
            while (cursor.gotoFirstChild()) {
                while (byte >= cursor.currentNode().endByte()) {
                    std.debug.assert(cursor.gotoNextSibling());
                }
            }

            std.debug.assert(byte < cursor.currentNode().endByte());
        }

        // then, find the node that contains the current docbyte
        var current_node_i = cursor.stack.items.len - 1;
        while (true) {
            const current_node = cursor.stack.items[current_node_i];
            if (current_node.docbyteInRange(byte)) {
                // perfect node!
                return current_node_i;
            } else {
                // not wide enough, go up one
                if (current_node_i == 0) return 0;
                current_node_i -= 1;
                continue;
            }
        }
    }
};
