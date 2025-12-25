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
            dump: *const fn (printer: *Printer, arg: *const anyopaque) Error!void,
        },
        struc: struct {
            fields: []const StructField,
        },
        vector: struct {
            child: *const TypeDetails,
            offsets: []const usize,
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
fn printPackedStruct(comptime Ty: type) *const fn (printer: *Printer, arg: *const anyopaque) Error!void {
    const PackedStructPrinter = struct {
        fn doPrint(printer: *Printer, arg: *const anyopaque) Error!void {
            const cast: *align(1) const Ty = @ptrCast(arg);
            try printer.setColor(.bright_black);
            try printer.print("{s}:", .{@typeName(Ty)});
            try printer.setColor(.reset);
            inline for (@typeInfo(Ty).@"struct".fields) |field| {
                try printer.newline();
                try printer.print("{f}", .{std.zig.fmtId(field.name)});
                try printer.setColor(.bright_black);
                try printer.print(": ", .{});
                try printer.setColor(.reset);
                try printer.dump(.from(&@field(cast, field.name), typeDetails(field.type)));
            }
            if (@typeInfo(Ty).@"struct".fields.len == 0) {
                try printer.newline();
                try printer.print("no fields", .{});
            }
        }
    };
    return &PackedStructPrinter.doPrint;
}
fn printInt(comptime Ty: type) *const fn (printer: *Printer, arg: *const anyopaque) Error!void {
    const IntPrinter = struct {
        fn doPrint(printer: *Printer, arg: *const anyopaque) Error!void {
            const cast: *const Ty = @alignCast(@ptrCast(arg));
            try printer.setColor(.magenta);
            try printer.print("{d}", .{cast.*});
            try printer.setColor(.reset);
        }
    };
    return &IntPrinter.doPrint;
}
fn typeDetails(comptime Ty: type) *const TypeDetails {
    return &comptime .{
        .name = @typeName(Ty),
        .value = blk: {
            const ti = @typeInfo(Ty);
            switch (ti) {
                .vector => |v| {
                    var offsets: [v.len]usize = @splat(undefined);
                    var offsetof: @Vector(v.len, v.child) = undefined;
                    for (0.., &offsets) |i, *out_offset| {
                        out_offset.* = @as(*const u8, @ptrCast(&offsetof[i])) - @as(*const u8, @ptrCast(&offsetof));
                    }
                    const offsets_copy = offsets;
                    break :blk .{ .vector = .{ .child = typeDetails(v.child), .offsets = &offsets_copy } };
                },
                .@"struct" => |s| {
                    // if hasDecl custom print : custom print
                    // if is arraylist : custom print
                    // ... etc
                    if (s.backing_integer != null) break :blk .{ .custom = .{ .dump = printPackedStruct(Ty) } };
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
                .int => {
                    // power of two ints don't need this
                    break :blk .{ .custom = .{ .dump = printInt(Ty) } };
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
        .indent_count = 0,
    };
    try printer.dump(.from(&object, details));
}

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
    indent_count: usize,

    // for cyclic
    // cache: std.AutoArrayHashMap(struct{ ptr: [*]const u8, details: *const TypeDetails }, usize),

    fn setColor(printer: *Printer, color: std.Io.tty.Color) Error!void {
        printer.cfg.tty.setColor(printer.out, color) catch return error.WriteFailed;
    }

    pub fn print(printer: *Printer, comptime fmt: []const u8, args: anytype) Error!void {
        try printer.out.print(fmt, args);
    }
    pub fn newline(printer: *Printer) Error!void {
        try printer.out.writeByte('\n');
        try printer.out.splatByteAll(' ', printer.indent_count * 1);
    }
    pub fn indent(printer: *Printer) void {
        printer.indent_count += 1;
    }
    pub fn dedent(printer: *Printer) void {
        printer.indent_count -= 1;
    }

    pub fn dump(printer: *Printer, any: DetailedAny) Error!void {
        switch (any.details.value) {
            .custom => |*custom| {
                try custom.*.dump(printer, any.obj);
            },
            .array => |*array| {
                try printer.setColor(.bright_black);
                try printer.print("{s}:", .{any.details.name});
                try printer.setColor(.reset);
                printer.indent();
                defer printer.dedent();
                for (0..array.len) |idx| {
                    try printer.newline();
                    try printer.setColor(.magenta);
                    try printer.print("{d}", .{idx});
                    try printer.setColor(.bright_black);
                    try printer.print(": ", .{});
                    try printer.setColor(.reset);
                    try printer.dump(any.offset(idx * array.stride, array.child));
                }
                if (array.len == 0) {
                    try printer.newline();
                    try printer.print("no children", .{});
                }
            },
            .vector => |*vector| {
                try printer.setColor(.bright_black);
                try printer.print("{s}:", .{any.details.name});
                try printer.setColor(.reset);
                printer.indent();
                defer printer.dedent();
                for (0.., vector.offsets) |idx, offset| {
                    try printer.newline();
                    try printer.setColor(.magenta);
                    try printer.print("{d}", .{idx});
                    try printer.setColor(.bright_black);
                    try printer.print(": ", .{});
                    try printer.setColor(.reset);
                    try printer.dump(any.offset(offset, vector.child));
                }
                if (vector.offsets.len == 0) {
                    try printer.newline();
                    try printer.print("no children", .{});
                }
            },
            .struc => |*struc| {
                try printer.setColor(.bright_black);
                try printer.print("{s}:", .{any.details.name});
                try printer.setColor(.reset);
                printer.indent();
                defer printer.dedent();
                for (struc.fields) |field| {
                    try printer.newline();
                    try printer.print("{f}", .{std.zig.fmtId(field.name)});
                    try printer.setColor(.bright_black);
                    try printer.print(": ", .{});
                    try printer.setColor(.reset);
                    try printer.dump(any.offset(field.offset, field.details));
                }
                if (struc.fields.len == 0) {
                    try printer.newline();
                    try printer.print("no fields", .{});
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
