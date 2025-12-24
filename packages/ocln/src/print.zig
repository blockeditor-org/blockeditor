const std = @import("std");

const Error = std.Io.Writer.Error;
const StructField = struct {
    name: []const u8,
    offset: usize,
    details: *const TypeDetails,
};
const TypeDetails = struct {
    name: []const u8,
    value: union(enum) {
        custom: struct {
            cb: *const fn (printer: *Printer, arg: *const anyopaque, indent: Indent) Error!void,
        },
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
fn printPackedStruct(comptime Ty: type) *const fn (printer: *Printer, arg: *const anyopaque, indent: Indent) Error!void {
    const PackedStructPrinter = struct {
        fn doPrint(printer: *Printer, arg: *const anyopaque, indent: Indent) Error!void {
            const cast: *const Ty = @alignCast(@ptrCast(arg));
            try printer.setColor(.bright_black);
            try printer.print("{s}:", .{@typeName(Ty)});
            try printer.setColor(.reset);
            inline for (@typeInfo(Ty).@"struct".fields) |field| {
                try printer.print("\n{f}{f}", .{ indent.incr(), std.zig.fmtId(field.name) });
                try printer.setColor(.bright_black);
                try printer.print(": ", .{});
                try printer.setColor(.reset);
                try printer.dump(.from(&@field(cast, field.name), typeDetails(field.type)), indent.incr());
            }
            if (@typeInfo(Ty).@"struct".fields.len == 0) {
                try printer.print("\nno fields", .{});
            }
        }
    };
    return &PackedStructPrinter.doPrint;
}
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
                    if (s.backing_integer != null) break :blk .{ .custom = .{ .cb = printPackedStruct(Ty) } };
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
    tty: std.Io.tty.Config,
};
pub fn print(out: *std.Io.Writer, object: anytype, cfg: *const PrintCfg) Error!void {
    const details = typeDetails(@TypeOf(object));
    var printer: Printer = .{
        .cfg = cfg,
        .out = out,
    };
    try printer.dump(.from(&object, details), .{ .value = 0 });
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

const DetailedAny = struct {
    obj: [*]const u8,
    details: *const TypeDetails,
    fn from(obj: *const anyopaque, details: *const TypeDetails) DetailedAny {
        return .{ .obj = @ptrCast(obj), .details = details };
    }
    fn offset(any: DetailedAny, n: usize, details: *const TypeDetails) DetailedAny {
        return .{ .obj = any.obj[n..], .details = details };
    }
};
const Printer = struct {
    cfg: *const PrintCfg,
    out: *std.Io.Writer,

    // for cyclic
    // cache: std.AutoArrayHashMap(struct{ ptr: [*]const u8, details: *const TypeDetails }, usize),

    fn setColor(printer: *Printer, color: std.Io.tty.Color) Error!void {
        printer.cfg.tty.setColor(printer.out, color) catch return error.WriteFailed;
    }

    pub fn print(printer: *Printer, comptime fmt: []const u8, args: anytype) Error!void {
        try printer.out.print(fmt, args);
    }

    pub fn dump(printer: *Printer, any: DetailedAny, indent: Indent) Error!void {
        switch (any.details.value) {
            .custom => |*custom| {
                try custom.*.cb(printer, any.obj, indent);
            },
            .array => |*array| {
                try printer.setColor(.bright_black);
                try printer.print("{s}:", .{any.details.name});
                try printer.setColor(.reset);
                for (0..array.len) |idx| {
                    try printer.print("\n{f}", .{indent.incr()});
                    try printer.setColor(.magenta);
                    try printer.print("{d}", .{idx});
                    try printer.setColor(.bright_black);
                    try printer.print(": ", .{});
                    try printer.setColor(.reset);
                    try printer.dump(any.offset(idx * array.stride, array.child), indent.incr());
                }
            },
            .struc => |*struc| {
                try printer.setColor(.bright_black);
                try printer.print("{s}:", .{any.details.name});
                try printer.setColor(.reset);
                for (struc.fields) |field| {
                    try printer.print("\n{f}{f}", .{ indent.incr(), std.zig.fmtId(field.name) });
                    try printer.setColor(.bright_black);
                    try printer.print(": ", .{});
                    try printer.setColor(.reset);
                    try printer.dump(any.offset(field.offset, field.details), indent.incr());
                }
                if (struc.fields.len == 0) {
                    try printer.print("\nno fields", .{});
                }
            },
            .todo => |t| {
                try printer.setColor(.red);
                try printer.print("TODO", .{});
                try printer.setColor(.bright_black);
                try printer.print(": ", .{});
                try printer.setColor(.reset);
                try printer.print("{s}", .{t.msg});
            },
        }
    }
};
