const std = @import("std");

const StructField = struct {
    name: []const u8,
    offset: usize,
    details: *const TypeDetails,
};
const TypeDetails = struct {
    name: []const u8,
    value: union(enum) {
        struc: struct {
            fields: []const StructField,
        },
        array: struct {
            len: usize,
            stride: usize,
            child: *const TypeDetails,
            sentinel: ?*const anyopaque,
        },
        todo: struct {
            msg: []const u8,
        },
    },
};
fn typeDetails(comptime Ty: type) *const TypeDetails {
    return &comptime .{
        .name = @typeName(Ty),
        .value = blk: {
            const ti = @typeInfo(Ty);
            switch (ti) {
                .@"struct" => |s| {
                    // if hasDecl custom print : custom print
                    // if is arraylist : custom print
                    // ... etc
                    if (s.backing_integer != null) break :blk .{ .todo = .{ .msg = "packed struct" } };
                    var fields: [s.fields.len]StructField = @splat(undefined);
                    for (s.fields, &fields) |field, *out_field| {
                        out_field.* = .{
                            .name = field.name,
                            .offset = @offsetOf(Ty, field.name),
                            .details = typeDetails(field.type),
                        };
                    }
                    const fields_copy = fields;
                    break :blk .{ .struc = .{ .fields = &fields_copy } };
                },
                .array => |arr| {
                    break :blk .{ .array = .{
                        .len = arr.len,
                        .stride = @sizeOf(arr.child),
                        .child = typeDetails(arr.child),
                        .sentinel = arr.sentinel_ptr,
                    } };
                },
                else => break :blk .{ .todo = .{ .msg = @typeName(Ty) } },
            }
        },
    };
}
const PrintCfg = struct {
    cfg: std.Io.tty.Config,
};
const PrintState = struct {
    // for cyclic
    // cache: std.AutoArrayHashMap(struct{ ptr: [*]const u8, details: *const TypeDetails }, usize),
};
pub fn print(out: *std.Io.Writer, object: anytype, cfg: *const PrintCfg) !void {
    const details = typeDetails(@TypeOf(object));
    var state: PrintState = .{};
    try printDetails(out, &state, @ptrCast(&object), details, cfg, .{ .value = 0 });
}
pub fn printDetails(out: *std.Io.Writer, state: *PrintState, obj: [*]const u8, details: *const TypeDetails, cfg: *const PrintCfg, indent: Indent) !void {
    switch (details.value) {
        .array => |*array| {
            try cfg.cfg.setColor(out, .bright_black);
            try out.print("{s}:", .{details.name});
            try cfg.cfg.setColor(out, .reset);
            for (0..array.len) |idx| {
                try out.print("\n{f}", .{indent.incr()});
                try cfg.cfg.setColor(out, .magenta);
                try out.print("{d}", .{idx});
                try cfg.cfg.setColor(out, .bright_black);
                try out.print(": ", .{});
                try cfg.cfg.setColor(out, .reset);
                try printDetails(out, state, obj[idx * array.stride ..], array.child, cfg, indent.incr());
            }
        },
        .struc => |*struc| {
            try cfg.cfg.setColor(out, .bright_black);
            try out.print("{s}:", .{details.name});
            try cfg.cfg.setColor(out, .reset);
            for (struc.fields) |field| {
                try out.print("\n{f}{f}", .{ indent.incr(), std.zig.fmtId(field.name) });
                try cfg.cfg.setColor(out, .bright_black);
                try out.print(": ", .{});
                try cfg.cfg.setColor(out, .reset);
                try printDetails(out, state, obj[field.offset..], field.details, cfg, indent.incr());
            }
            if (struc.fields.len == 0) {
                try out.print("\nno fields", .{});
            }
        },
        .todo => |t| {
            try cfg.cfg.setColor(out, .red);
            try out.print("TODO", .{});
            try cfg.cfg.setColor(out, .bright_black);
            try out.print(": ", .{});
            try cfg.cfg.setColor(out, .reset);
            try out.print("{s}", .{t.msg});
        },
    }
}
const Indent = struct {
    value: usize,
    pub fn incr(self: Indent) Indent {
        return .{ .value = self.value + 1 };
    }
    pub fn format(self: Indent, w: *std.Io.Writer) !void {
        try w.splatByteAll(' ', self.value);
    }
};
