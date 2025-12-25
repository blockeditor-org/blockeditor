const std = @import("std");

const Error = std.Io.Writer.Error;
const StructField = struct {
    name: []const u8,
    offset: usize,
    details: *const TypeDetails,
    default: ?*const anyopaque,
};
const TypeDetails = struct {
    name: []const u8,
    value: union(enum) {
        custom: struct {
            dump: *const fn (printer: *Printer, arg: DetailedAny) Error!void,
        },
        allocator,
        one_pointer: struct {
            child: *const TypeDetails,
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
        },
        slice: struct {
            ptr_offset: usize,
            len_offset: usize,
            stride: usize,
            child: *const TypeDetails,
        },
        todo: struct {
            msg: []const u8,
        },
        unprintable,
    },
};
fn printPackedStruct(comptime Ty: type) *const fn (printer: *Printer, arg: DetailedAny) Error!void {
    return &struct {
        fn doPrint(printer: *Printer, arg: DetailedAny) Error!void {
            const cast = arg.cast(Ty);
            try printer.setColor(.bright_black);
            try printer.print("{s}:", .{@typeName(Ty)});
            try printer.setColor(.reset);
            inline for (@typeInfo(Ty).@"struct".fields) |field| {
                try printer.newline();
                try printer.print("{f}", .{std.zig.fmtId(field.name)});
                try printer.setColor(.bright_black);
                try printer.print(": ", .{});
                try printer.setColor(.reset);
                try printer.dump(.fromAuto(&@field(cast, field.name)));
            }
            if (@typeInfo(Ty).@"struct".fields.len == 0) {
                try printer.newline();
                try printer.print("no fields", .{});
            }
        }
    }.doPrint;
}
fn printInt(comptime Ty: type) *const fn (printer: *Printer, arg: DetailedAny) Error!void {
    return &struct {
        fn doPrint(printer: *Printer, arg: DetailedAny) Error!void {
            const cast = arg.cast(Ty);
            try printer.setColor(.magenta);
            try printer.print("{d}", .{cast.*});
            try printer.setColor(.reset);
        }
    }.doPrint;
}
fn printMultiArrayList(comptime Ty: type, comptime Child: type) *const fn (printer: *Printer, arg: DetailedAny) Error!void {
    std.debug.assert(Ty == std.MultiArrayList(Child));
    return &struct {
        fn doPrint(printer: *Printer, arg: DetailedAny) Error!void {
            const cast = arg.cast(std.MultiArrayList(Child));
            try printer.setColor(.magenta);
            try printer.setColor(.bright_black);
            try printer.print("std.MultiArrayList({s}):", .{@typeName(Child)});
            try printer.setColor(.reset);
            for (0..cast.len) |idx| {
                try printer.newline();
                try printer.setColor(.magenta);
                try printer.print("{d}", .{idx});
                try printer.setColor(.bright_black);
                try printer.print(": ", .{});
                try printer.setColor(.reset);
                try printer.dump(.fromAuto(&cast.get(idx)));
            }
            if (@typeInfo(Ty).@"struct".fields.len == 0) {
                try printer.newline();
                try printer.print("no fields", .{});
            }
        }
    }.doPrint;
}
fn typeDetails(comptime Ty: type) *const TypeDetails {
    return &comptime .{
        .name = @typeName(Ty),
        .value = blk: {
            // special handling
            switch (Ty) {
                std.mem.Allocator => {
                    break :blk .allocator;
                },
                else => {},
            }
            if (@typeInfo(Ty) == .@"struct" and @hasField(Ty, "bytes") and @hasField(Ty, "len") and @hasField(Ty, "capacity") and @hasDecl(Ty, "get")) {
                // maybe std.MultiArrayList?
                const get = Ty.get;
                const getTi = @typeInfo(@TypeOf(get));
                if (getTi == .@"fn" and getTi.@"fn".return_type != null) {
                    const Child = getTi.@"fn".return_type.?;
                    if (Ty == std.MultiArrayList(Child)) {
                        // is MultiArrayList
                        // this one can probably be done with offsets but it's a bit complicated & strongly tied to the stdlib
                        break :blk .{ .custom = .{ .dump = printMultiArrayList(Ty, Child) } };
                    } else {
                        @compileLog("incorrectly detected as MultiArraylist:\ntype " ++ @typeName(Ty) ++ "\nimprove heuristic or remove this compileLog statement.");
                    }
                }
            }
            // TODO: MultiArrayList, AutoArrayHashMap

            // default handling
            const ti = @typeInfo(Ty);
            switch (ti) {
                .@"opaque", .@"fn" => break :blk .unprintable,
                .pointer => |p| {
                    switch (p.size) {
                        .one => {
                            break :blk .{ .one_pointer = .{
                                .child = typeDetails(p.child),
                            } };
                        },
                        .many => break :blk .{ .one_pointer = .{ .child = &.{ .name = @typeName(Ty), .value = .unprintable } } },
                        .slice => {
                            // var offsetof: Ty = undefined;
                            // const optr: *const u8 = @as(*const u8, @ptrCast(&offsetof.ptr));
                            // const olen: *const u8 = @as(*const u8, @ptrCast(&offsetof.len));
                            // const oval: *const u8 = @as(*const u8, @ptrCast(&offsetof));
                            // optr - oval, olen - oval

                            // TODO: hack! the memory layout of slices is not well-defined
                            break :blk .{ .slice = .{
                                .child = typeDetails(p.child),
                                .stride = @sizeOf(p.child),
                                .ptr_offset = 0,
                                .len_offset = @sizeOf(usize),
                            } };
                        },
                        .c => {
                            break :blk .{ .todo = .{ .msg = @tagName(p.size) } };
                        },
                    }
                },
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
                            .default = field.default_value_ptr,
                        };
                    }
                    const fields_copy = fields;
                    break :blk .{ .struc = .{ .fields = &fields_copy } };
                },
                .int => |int_data| {
                    if (std.math.divExact(u16, int_data.bits, 8)) |_| {
                        // TODO: don't need the fn ptr for this one
                    } else |_| {
                        // else
                    }
                    break :blk .{ .custom = .{ .dump = printInt(Ty) } };
                },
                .array => |arr| {
                    break :blk .{ .array = .{
                        .len = arr.len,
                        .stride = @sizeOf(arr.child),
                        .child = typeDetails(arr.child),
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
    var printer: Printer = .{
        .cfg = cfg,
        .out = out,
        .indent_count = 0,
    };
    try printer.dump(.fromAuto(&object));
}

const DetailedAny = struct {
    obj: [*]const u8,
    details: *const TypeDetails,
    fn from(obj: [*]const u8, details: *const TypeDetails) DetailedAny {
        return .{ .obj = obj, .details = details };
    }
    fn fromAuto(obj: anytype) DetailedAny {
        const details = typeDetails(@typeInfo(@TypeOf(obj)).pointer.child);
        return .from(@ptrCast(obj), details);
    }
    fn offset(any: DetailedAny, n: usize, details: *const TypeDetails) DetailedAny {
        return .{ .obj = any.obj[n..], .details = details };
    }
    fn cast(any: DetailedAny, comptime T: type) *align(1) const T {
        return any.castOffset(T, 0);
    }
    fn castOffset(any: DetailedAny, comptime T: type, n: usize) *align(1) const T {
        return @ptrCast(any.obj[n..]);
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
    pub fn writeAll(printer: *Printer, msg: []const u8) Error!void {
        try printer.out.writeAll(msg);
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
                try custom.*.dump(printer, any);
            },
            .allocator => {
                const value = any.cast(std.mem.Allocator);

                const arena_vtable = comptime blk: {
                    var arena_vtable_container = std.heap.ArenaAllocator.init(undefined);
                    break :blk arena_vtable_container.allocator().vtable;
                };

                if (value.vtable == std.heap.smp_allocator.vtable) {
                    try printer.print("std", .{});
                    try printer.setColor(.bright_black);
                    try printer.print(".", .{});
                    try printer.setColor(.reset);
                    try printer.print("heap", .{});
                    try printer.setColor(.bright_black);
                    try printer.print(".", .{});
                    try printer.setColor(.reset);
                    try printer.print("smp_allocator", .{});
                } else if (@import("builtin").link_libc and value.vtable == std.heap.c_allocator.vtable) {
                    try printer.print("std", .{});
                    try printer.setColor(.bright_black);
                    try printer.print(".", .{});
                    try printer.setColor(.reset);
                    try printer.print("heap", .{});
                    try printer.setColor(.bright_black);
                    try printer.print(".", .{});
                    try printer.setColor(.reset);
                    try printer.print("c_allocator", .{});
                } else if (@import("builtin").is_test and value.vtable == std.testing.allocator.vtable) {
                    try printer.print("std", .{});
                    try printer.setColor(.bright_black);
                    try printer.print(".", .{});
                    try printer.setColor(.reset);
                    try printer.print("testing", .{});
                    try printer.setColor(.bright_black);
                    try printer.print(".", .{});
                    try printer.setColor(.reset);
                    try printer.print("allocator", .{});
                } else if (value.vtable == arena_vtable) {
                    const arena: *const std.heap.ArenaAllocator = @alignCast(@ptrCast(value.ptr));
                    try printer.print("std", .{});
                    try printer.setColor(.bright_black);
                    try printer.print(".", .{});
                    try printer.setColor(.reset);
                    try printer.print("heap", .{});
                    try printer.setColor(.bright_black);
                    try printer.print(".", .{});
                    try printer.setColor(.reset);
                    try printer.print("ArenaAllocator", .{});
                    try printer.setColor(.bright_black);
                    try printer.print(": ", .{});
                    try printer.setColor(.reset);
                    try printer.dump(.fromAuto(&arena.child_allocator));
                } else {
                    try printer.print("unknown allocator", .{});
                    // we could print it using the default printer for std.mem.Allocator if we want
                    // that way we get
                    // ptr: 0x16D35A4F0: TODO: anyopaque
                    // vtable: 0x16D35A4F8: mem.Allocator.VTable:
                    //     alloc: 0x102BD82A8: TODO: fn (*anyopaque, usize, mem.Alignment, usize) ?[*]u8
                    //     resize: 0x102BD82B0: TODO: fn (*anyopaque, []u8, mem.Alignment, usize, usize) bool
                    //     remap: 0x102BD82B8: TODO: fn (*anyopaque, []u8, mem.Alignment, usize, usize) ?[*]u8
                    //     free: 0x102BD82C0: TODO: fn (*anyopaque, []u8, mem.Alignment, usize) void
                    // just call dump again but for the type details, pass one generated with special handling disabled
                }
            },
            .one_pointer => |*pointer| {
                try printer.setColor(.blue);
                try printer.print("0x", .{});
                try printer.setColor(.magenta);
                try printer.print("{X}", .{@intFromPtr(any.obj)});
                try printer.setColor(.bright_black);
                try printer.print(": ", .{});
                try printer.setColor(.reset);
                const value = any.cast([*]const u8);
                try printer.dump(.from(value.*, pointer.child));
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
            .slice => |*slice| {
                try printer.setColor(.bright_black);
                try printer.print("{s}:", .{any.details.name});
                try printer.setColor(.reset);
                printer.indent();
                defer printer.dedent();
                const ptr = any.castOffset([*]const u8, slice.ptr_offset).*;
                const len = any.castOffset(usize, slice.len_offset).*;
                const sub: DetailedAny = .from(ptr, slice.child);
                if (len > 50) {
                    try printer.newline();
                    try printer.print("...{d} children", .{len});
                    return;
                }
                for (0..len) |idx| {
                    try printer.newline();
                    try printer.setColor(.magenta);
                    try printer.print("{d}", .{idx});
                    try printer.setColor(.bright_black);
                    try printer.print(": ", .{});
                    try printer.setColor(.reset);
                    try printer.dump(sub.offset(idx * slice.stride, slice.child));
                }
                if (len == 0) {
                    try printer.newline();
                    try printer.print("no children", .{});
                }
            },
            .vector => |*vector| {
                if (vector.offsets.len > 0) {
                    try printer.setColor(.bright_black);
                    try printer.writeAll(".{ ");
                    for (0.., vector.offsets) |idx, offset| {
                        if (idx != 0) {
                            try printer.setColor(.bright_black);
                            try printer.writeAll(", ");
                        }
                        try printer.setColor(.reset);
                        try printer.dump(any.offset(offset, vector.child));
                    }
                    try printer.setColor(.bright_black);
                    try printer.writeAll(" }");
                    try printer.setColor(.reset);
                } else {
                    try printer.setColor(.bright_black);
                    try printer.writeAll(".{}");
                    try printer.setColor(.reset);
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
            .unprintable => {
                try printer.print("{s}", .{any.details.name});
            },
        }
    }
};
