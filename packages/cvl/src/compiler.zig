const std = @import("std");
const parser = @import("parser.zig");
const anywhere = @import("anywhere");
const SrcLoc = parser.SrcLoc;
const riscv = @import("riscv.zig");

fn autoVtable(comptime Vtable: type, comptime Src: type) *const Vtable {
    return comptime blk: {
        var res: Vtable = undefined;
        for (@typeInfo(Vtable).@"struct".fields) |field| {
            if (@hasDecl(Src, field.name)) {
                @field(res, field.name) = &@field(Src, field.name);
            } else if (field.default_value_ptr) |default_v| {
                @field(res, field.name) = @as(*const field.type, @ptrCast(@alignCast(default_v))).*;
            } else {
                @compileError("vtable for " ++ @typeName(Src) ++ " missing required field: " ++ field.name);
            }
        }
        const res_dupe = res;
        break :blk &res_dupe;
    };
}

const Backends = struct {
    const Zig = struct {
        const EmitBlock = @import("./zig.zig").EmitBlock;

        const Asm_CacheKey = struct {
            fn hash(_: anywhere.util.AnyPtr, _: *Env) u32 {
                return 0;
            }
            fn eql(_: anywhere.util.AnyPtr, _: anywhere.util.AnyPtr, _: *Env) bool {
                return true;
            }
            fn init(_: anywhere.util.AnyPtr, _: *Env) Error!Decl {
                return .from(
                    .fromSrc(@src()),
                    Asm,
                    &.{},
                    &{},
                );
            }
        };
        const Any = struct {
            pub const ty: Type = .from(@This(), &.{});
            fn name(_: anywhere.util.AnyPtr, env: *Env) Error![]const u8 {
                return try std.fmt.allocPrint(env.arena, "zig:any", .{});
            }
        };
        const Asm = struct {
            pub const ty: Type = .from(@This(), &.{});
            pub const ComptimeValue = void;

            fn name(_: anywhere.util.AnyPtr, env: *Env) Error![]const u8 {
                return try std.fmt.allocPrint(env.arena, "zig:#builtin.asm", .{});
            }

            fn call(_: anywhere.util.AnyPtr, scope: *Scope, slot: Type, method: Expr, arg: parser.AstExpr, srcloc: SrcLoc) Error!Expr {
                const block = scope.block.to(EmitBlock);

                const arg_val = try scope.handleExpr(Types.ComptimeByteSlice.ty, arg);
                const cbyteslice = try scope.env.expectComptime(arg_val, Types.ComptimeByteSlice);
                try block.out.appendNTimes(scope.env.gpa, ' ', block.indent_level * 4);
                try block.out.writer(scope.env.gpa).print("_ = ", .{});
                // fix indentation. this does two passes over cbyteslice but we only need to do one.
                var iter = std.mem.splitScalar(u8, cbyteslice.*, '\n');
                while (iter.next()) |line| {
                    if (line.ptr != cbyteslice.ptr) {
                        try block.out.appendNTimes(scope.env.gpa, ' ', block.indent_level * 4);
                    }
                    try block.out.appendSlice(scope.env.gpa, line);
                }
                try block.out.writer(scope.env.gpa).print(";", .{});

                _ = slot;
                _ = method;
                _ = srcloc;
                return .{
                    .ty = Any.ty,
                    .value = .{ .runtime = .from(EmitBlock.ZigVar, try anywhere.util.dupeOne(scope.env.arena, @as(EmitBlock.ZigVar, @enumFromInt(0)))) },
                    .srcloc = .fromSrc(@src()),
                };
            }
        };

        const vtable = autoVtable(Backend.Vtable, @This());

        pub fn name(_: anywhere.util.AnyPtr, env: *Env) Error![]const u8 {
            return try std.fmt.allocPrint(env.arena, "riscv32", .{});
        }

        pub fn get_asm_decl(_: anywhere.util.AnyPtr, scope: *Scope) Error!Decl.Index {
            return try scope.env.cachedDecl(Asm_CacheKey, .{});
        }
    };
    const Riscv32 = struct {
        const rvemu = @import("rvemu");
        const EmitBlock = @import("./riscv.zig").EmitBlock;

        const Asm_CacheKey = struct {
            fn hash(_: anywhere.util.AnyPtr, _: *Env) u32 {
                return 0;
            }
            fn eql(_: anywhere.util.AnyPtr, _: anywhere.util.AnyPtr, _: *Env) bool {
                return true;
            }
            fn init(_: anywhere.util.AnyPtr, _: *Env) Error!Decl {
                return .from(
                    .fromSrc(@src()),
                    Asm,
                    &.{},
                    &{},
                );
            }
        };
        const Asm = struct {
            pub const ty: Type = .from(@This(), &.{});
            pub const ComptimeValue = void;

            fn name(_: anywhere.util.AnyPtr, env: *Env) Error![]const u8 {
                return try std.fmt.allocPrint(env.arena, "rv:#builtin.asm", .{});
            }
            // for lsp, we need to provide a list of keys
            fn access(_: anywhere.util.AnyPtr, scope: *Scope, slot: Type, obj: Expr, prop: parser.AstExpr, srcloc: SrcLoc) Error!Expr {
                _ = slot;
                std.debug.assert(obj.value == .compiletime);
                const arg = try scope.handleExpr(Types.Key.ty, prop);
                const ctk = try scope.env.expectComptimeKey(arg);
                return scope.env.castExpr(obj, .from(Types.Bound, try anywhere.util.dupeOne(scope.env.arena, Types.Bound{ .child = obj.ty, .ctk = ctk })), srcloc);
            }
            fn bound_call(_: anywhere.util.AnyPtr, scope: *Scope, slot: Type, method: Expr, ctk: Types.Key.ComptimeValue, arg: parser.AstExpr, srcloc: SrcLoc) Error!Expr {
                return callAsmInstr(scope, slot, method, ctk, arg, srcloc);
            }
        };

        const vtable = autoVtable(Backend.Vtable, @This());
        const Instr_CacheKey = struct {
            fn hash(_: anywhere.util.AnyPtr, _: *Env) u32 {
                return 0;
            }
            fn eql(_: anywhere.util.AnyPtr, _: anywhere.util.AnyPtr, _: *Env) bool {
                return true;
            }
            fn init(_: anywhere.util.AnyPtr, env: *Env) Error!Decl {
                const fields = comptime std.meta.fields(rvemu.rvinstrs.InstrName);
                const enum_fields: [fields.len]rvemu.rvinstrs.InstrName = comptime blk: {
                    var res: [fields.len]rvemu.rvinstrs.InstrName = undefined;
                    for (fields, &res) |field, *r| {
                        r.* = @field(rvemu.rvinstrs.InstrName, field.name);
                    }
                    break :blk res;
                };
                const resfields = try env.arena.alloc(Types.Enum.Field, fields.len);
                for (enum_fields, resfields) |enf, *f| {
                    f.* = .{ .name = try env.comptimeKeyFromString(@tagName(enf)), .value = @intFromEnum(enf) };
                }

                return .from(
                    .fromSrc(@src()),
                    Types.Ty,
                    &.{},
                    try anywhere.util.dupeOne(env.arena, Types.Ty.ComptimeValue.from(
                        Types.Enum,
                        try anywhere.util.dupeOne(env.arena, Types.Enum{
                            .srcloc = .fromSrc(@src()),
                            .fields = resfields,
                        }),
                    )),
                );
            }
        };
        const Arg_CacheKey = struct {
            spec: rvemu.rvinstrs.InstrSpec,
            fn hash(a: anywhere.util.AnyPtr, _: *Env) u32 {
                const a_cast = a.to(Arg_CacheKey);
                return std.array_hash_map.hashString(a_cast.spec.name);
            }
            fn eql(a_raw: anywhere.util.AnyPtr, b_raw: anywhere.util.AnyPtr, _: *Env) bool {
                const a = a_raw.to(Arg_CacheKey);
                const b = b_raw.to(Arg_CacheKey);
                // name must be unique
                return a.spec.name.ptr == b.spec.name.ptr;
            }
            fn tyFromBank(bank: rvemu.rvinstrs.RegBank) Type {
                return switch (bank) {
                    .sint => Types.Int.fromIntTy(i32),
                    .uint => Types.Int.fromIntTy(u32),
                    else => @panic("TODO bank"),
                    // .float => Types.IEEE.ieee32,
                    // .double => Types.IEEE.ieee64,
                };
            }
            fn init(raw: anywhere.util.AnyPtr, env: *Env) Error!Decl {
                const self = raw.to(Arg_CacheKey);
                const fields: []Types.Struct.Field = switch (self.spec.format) {
                    .R => try env.arena.dupe(Types.Struct.Field, &.{
                        .{
                            .name = try env.comptimeKeyFromString("rs1"),
                            .ty = tyFromBank(self.spec.banks.?.rs1.?),
                            .default_value = null,
                        },
                        .{
                            .name = try env.comptimeKeyFromString("rs2"),
                            .ty = tyFromBank(self.spec.banks.?.rs2.?),
                            .default_value = null,
                        },
                    }),
                    else => return env.addErr(.fromSrc(@src()), "TODO asm instr fmt: {s}", .{@tagName(self.spec.format)}),
                };
                return .from(
                    .fromSrc(@src()),
                    Types.Ty,
                    &.{},
                    try anywhere.util.dupeOne(env.arena, Types.Ty.ComptimeValue.from(
                        Types.Struct,
                        try anywhere.util.dupeOne(env.arena, Types.Struct{
                            .srcloc = .fromSrc(@src()),
                            .fields = fields,
                        }),
                    )),
                );
            }
        };

        pub fn name(_: anywhere.util.AnyPtr, env: *Env) Error![]const u8 {
            return try std.fmt.allocPrint(env.arena, "riscv32", .{});
        }

        pub fn get_asm_decl(_: anywhere.util.AnyPtr, scope: *Scope) Error!Decl.Index {
            return try scope.env.cachedDecl(Asm_CacheKey, .{});
        }
        pub fn callAsmInstr(scope: *Scope, slot: Type, method: Expr, ctk: Types.Key.ComptimeValue, arg: parser.AstExpr, srcloc: SrcLoc) Error!Expr {
            _ = slot;
            _ = method;
            const ctk_val = (try ctk.getString(scope.env)) orelse return scope.env.addErr(srcloc, "Asm instr symbol not allowed", .{});
            const ctk_enum_val = std.meta.stringToEnum(rvemu.rvinstrs.InstrName, ctk_val) orelse return scope.env.addErr(srcloc, "Asm instr not found: {s}. TODO support fakeuser and regsets (x10(5) should request the %reg 5 is in to pin to x10)", .{ctk_val});

            const instr_spec = rvemu.rvinstrs.instrData(ctk_enum_val);
            const arg_ty_decl = try scope.env.cachedDecl(Arg_CacheKey, .{ .spec = instr_spec });
            const arg_ty = try scope.env.resolveDeclValue(arg_ty_decl);
            const arg_val = try scope.handleExpr(arg_ty.resolved_value_ptr.?.to(Type).*, arg);

            // TODO: x10_decl can be runtime
            // so convert it to runtime if it's comptime
            // something interesting here is that we will need to support mixed comptime & runtime
            // in a struct. because we have to access op as comptime. so we should mark it in the
            // type somehow?
            // slot.access(scope, slot, arg_val, prop: parser.AstExpr, srcloc); // huh
            if (true) return scope.env.addErr(srcloc, "TODO read runtime value from struct", .{});
            _ = arg_val;
            // const rs1_decl = Types.Struct.accessComptime(arg_val.ty, arg_ct.*, try scope.env.comptimeKeyFromString("rs1"));
            // const rs1_val = try scope.env.resolveDeclValue(rs1_decl);
            // if (!rs1_val.resolved_type.?.is(Types.Int)) return scope.env.addErr(srcloc, "Expected int, found <2>", .{});
            // const rs1 = rs1_val.resolved_value_ptr.?.to(Types.Int.ComptimeValue);

            // const block = scope.block.to(riscv.EmitBlock);
            // const li_reg: riscv.EmitBlock.RvVar = .fromIntReg(10);
            // const out_reg: riscv.EmitBlock.RvVar = .fromIntReg(11);
            // _ = rs1;
            // // TODO
            // // try block.appendLoadImmediate(scope.env, li_reg, std.math.cast(i32, x10.*) orelse return scope.env.addErr(srcloc, "<rv32> number out of range", .{})); // TODO: this should be done by converting x10 to runtime rather than here
            // try block.instructions.append(scope.env.gpa, .{
            //     .instr = .{ .op = ctk_enum_val, .rs1 = li_reg, .rs2 = .fromIntReg(12), .rd = out_reg },
            // });

            // return scope.env.declExpr(srcloc, try scope.env.cachedDecl(VoidDecl, .{}));
        }
    };
};
const Backend = struct {
    vtable: *const Backend.Vtable,
    data: anywhere.util.AnyPtr,
    const Vtable = struct {
        name: *const fn (_: anywhere.util.AnyPtr, env: *Env) Error![]const u8,

        /// backend-dependant behaviour
        get_asm_decl: ?*const fn (_: anywhere.util.AnyPtr, scope: *Scope) Error!Decl.Index = null,
    };

    fn name(self: Backend, env: *Env) Error![]const u8 {
        return self.vtable.name(self.data, env);
    }
};

const Types = struct {
    const Unknown = struct {
        pub const ty: Type = .from(@This(), &.{});
        fn name(_: anywhere.util.AnyPtr, env: *Env) Error![]const u8 {
            return try std.fmt.allocPrint(env.arena, "unknown", .{});
        }
    };
    const Infer = struct {
        extends: Type,
        fn name(self_any: anywhere.util.AnyPtr, env: *Env) Error![]const u8 {
            const self = self_any.toConst(Infer);
            return try std.fmt.allocPrint(env.arena, "infer({s})", .{try self.extends.name(env)});
        }
    };
    const Void = struct {
        pub const ComptimeValue = void;
        pub const ty: Type = .from(@This(), &.{});
        fn name(_: anywhere.util.AnyPtr, env: *Env) Error![]const u8 {
            return try std.fmt.allocPrint(env.arena, "void", .{});
        }
    };
    const Ty = struct {
        pub const ComptimeValue = Type;
        pub const ty: Type = .from(@This(), &.{});

        fn name(_: anywhere.util.AnyPtr, env: *Env) Error![]const u8 {
            return try std.fmt.allocPrint(env.arena, "type", .{});
        }
        fn access(_: anywhere.util.AnyPtr, scope: *Scope, slot: Type, obj: Expr, prop: parser.AstExpr, srcloc: SrcLoc) Error!Expr {
            std.debug.assert(obj.value == .compiletime);
            const resolved_value = try scope.env.resolveDeclValue(obj.value.compiletime);
            std.debug.assert(obj.ty.vtable == resolved_value.resolved_type.?.vtable and obj.ty.data.val == resolved_value.resolved_type.?.data.val);

            const target_ty = resolved_value.resolved_value_ptr.?.toConst(ComptimeValue).*;

            if (target_ty.vtable.access_type == null) return scope.env.addErr(srcloc, "Type {s} does not support 'access_type'", .{try target_ty.name(scope.env)});
            return target_ty.vtable.access_type.?(target_ty.data, scope, slot, target_ty, prop, srcloc);
        }
    };
    const Builtin = struct {
        pub const ty: Type = .from(@This(), &.{});
        pub const ComptimeValue = void;

        fn name(_: anywhere.util.AnyPtr, env: *Env) Error![]const u8 {
            return try std.fmt.allocPrint(env.arena, "#builtin", .{});
        }
        // for lsp, we need to provide a list of keys
        fn access(_: anywhere.util.AnyPtr, scope: *Scope, slot: Type, obj: Expr, prop: parser.AstExpr, srcloc: SrcLoc) Error!Expr {
            _ = slot;
            std.debug.assert(obj.value == .compiletime);
            const arg = try scope.handleExpr(Types.Key.ty, prop);
            const ctk = try scope.env.expectComptimeKey(arg);
            if (ctk == try scope.env.comptimeKeyFromString("asm")) {
                if (scope.env.backend.vtable.get_asm_decl == null) return scope.env.addErr(srcloc, "Backend {s} does not support #builtin.asm", .{try scope.env.backend.name(scope.env)});
                return scope.env.declExpr(srcloc, try scope.env.backend.vtable.get_asm_decl.?(scope.env.backend.data, scope));
            }
            return scope.env.addErr(srcloc, "TODO access #bulitin", .{});
        }
    };
    const Key = struct {
        pub const ty: Type = .from(@This(), &.{});
        fn name(_: anywhere.util.AnyPtr, _: *Env) Error![]const u8 {
            return "key";
        }

        // for strings <= 7 bytes long, we can store them directly in the u64
        // longer than 7 maybe they can go in a comptime array unless they're runtime
        pub const ComptimeValue = enum(u64) {
            _,
            fn name(val: ComptimeValue, env: *Env) Error![]const u8 {
                const v = env.comptime_keys.items[@intFromEnum(val)];
                return switch (v) {
                    .string => |str| try std.fmt.allocPrint(env.arena, ".{s}", .{str}),
                    .symbol => @panic("todo print symbol"),
                };
            }
            fn getString(val: ComptimeValue, env: *Env) Error!?[]const u8 {
                const v = env.comptime_keys.items[@intFromEnum(val)];
                return switch (v) {
                    .string => |str| return str,
                    .symbol => return null,
                };
            }
        };

        fn access_type(self_any: anywhere.util.AnyPtr, scope: *Scope, slot: Type, obj: Type, prop: parser.AstExpr, srcloc: SrcLoc) Error!Expr {
            _ = self_any;
            _ = slot;
            _ = srcloc;
            return scope.handleExpr(obj, prop);
        }
    };
    const ComptimeByteSlice = struct {
        pub const ty: Type = .from(@This(), &.{});
        fn name(_: anywhere.util.AnyPtr, _: *Env) Error![]const u8 {
            return "comptime_byte_slice";
        }
        pub const ComptimeValue = []const u8;

        fn from_string(self: anywhere.util.AnyPtr, scope: *Scope, slot: Type, str: []const u8, srcloc: SrcLoc) Error!Expr {
            _ = slot;
            return scope.env.declExpr(srcloc, try scope.env.addDecl(.from(
                srcloc,
                ComptimeByteSlice,
                self.to(ComptimeByteSlice),
                try anywhere.util.dupeOne(scope.env.arena, str),
            )));
        }
    };
    const Bound = struct {
        child: Type,
        ctk: Types.Key.ComptimeValue,

        fn name(self_any: anywhere.util.AnyPtr, env: *Env) Error![]const u8 {
            const self = self_any.toConst(Bound);
            return try std.fmt.allocPrint(env.arena, "bound({s}, {s})", .{ try self.child.name(env), env.comptime_keys.items[@intFromEnum(self.ctk)].string });
        }
        fn call(self_any: anywhere.util.AnyPtr, scope: *Scope, slot: Type, method: Expr, arg: parser.AstExpr, srcloc: SrcLoc) Error!Expr {
            const self = self_any.toConst(Bound);
            if (self.child.vtable.bound_call == null) @panic("bound call created but not exists");
            return self.child.vtable.bound_call.?(self.child.data, scope, slot, method, self.ctk, arg, srcloc);
        }
    };
    const Struct = struct {
        // to use at runtime, this has to get converted to a target-specific type
        const Field = struct {
            name: Types.Key.ComptimeValue,
            ty: Type,
            default_value: ?Decl.Index,
            // /// this indicates that initializing this struct should return a new struct type with
            // /// 'parent_struct' = to this struct, and the field missing from the fields array.
            // /// (field_name?: T)
            // comptime_optional: bool,
            // /// the slot type will be ty, but a new struct will be initialized with the type of the
            // /// field set to the value. (mabe using field_name: infer extends U)?
            // comptime_anytype: bool,
            // /// value is compiletime (comptime field_name: T)
            // compiletime: bool,
        };
        /// for types created containing the values of compiletime
        /// or comptime_optional fields
        parent_struct: ?Type = null,
        srcloc: SrcLoc,
        fields: []const Field,
        // we don't need to box values at comptime
        // we can make ComptimeValue be a byte slice
        // and do alignment and stuff
        const ComptimeValue = []const Decl.Index;

        // comptime:
        // - []const Decl.Index for now
        // - eventually we'll want to have some types of decls unboxed
        //   directly into their index maybe. eg true/false stored as
        //   Decl.Index.true/false
        // by value:
        // - each entry of the struct goes in its own variable
        // - mystruct: Struct = (.x = 1, .y = 2, .z = 3)
        // - equiv to mystruct_x = 1; mystruct_y = 2; mystruct_z = 3;
        // - (you can never get a pointer from a value, so this is fine)
        // by reference:
        // - layed out in memory automatically
        // - the backend defines the layout
        // - not stable! it can be whatever

        pub fn accessComptime(ty: Type, ct: ComptimeValue, a_name: Types.Key.ComptimeValue) Decl.Index {
            const self = ty.data.toConst(Struct);
            for (self.fields, ct) |field, val| {
                if (a_name == field.name) return val;
            }
            @panic("accessComptime on struct with incorrect key");
        }

        fn name(self_any: anywhere.util.AnyPtr, env: *Env) Error![]const u8 {
            const self = self_any.toConst(@This());
            return try std.fmt.allocPrint(env.arena, "struct({d}, {d})", .{ self.srcloc.file_id, self.srcloc.offset });
        }

        pub fn from_map(self_any: anywhere.util.AnyPtr, scope: *Scope, slot: Type, ents: []MapEnt, srcloc: SrcLoc) Error!Expr {
            _ = slot;
            const self = self_any.to(Struct);

            // first, try to initialize as comptime
            // if that doesn't work out, initialize as runtime
            const comptime_res = try scope.env.arena.alloc(Decl.Index, self.fields.len);
            for (comptime_res) |*itm| itm.* = .none;
            for (ents) |ent| {
                if (ent.key == null) {
                    return scope.env.addErr(ent.srcloc, "missing srcloc", .{});
                }
                const key = try scope.handleExpr(Types.Key.ty, ent.key.?);
                const ctk = try scope.env.expectComptimeKey(key);
                const field_i: usize = for (self.fields, 0..) |field, i| {
                    if (ctk == field.name) break i;
                } else {
                    // in this case it could be a comptime field
                    return scope.env.addErr(key.srcloc, "key {s} not found in {s}", .{ try ctk.name(scope.env), try name(self_any, scope.env) });
                };

                if (comptime_res[field_i] != .none) return scope.env.addErr(key.srcloc, "duplicate field", .{});

                const value = try scope.handleExpr(self.fields[field_i].ty, ent.value);
                if (value.value != .compiletime) return scope.env.addErr(value.srcloc, "TODO: runtime value in struct init", .{});
                comptime_res[field_i] = value.value.compiletime;
            }

            for (comptime_res, self.fields) |*itm, field| {
                if (itm.* == .none) {
                    if (field.default_value) |dfv| {
                        itm.* = dfv;
                    } else {
                        return scope.env.addErr(srcloc, "missing field", .{});
                    }
                }
            }

            // done!
            const res = try scope.env.addDecl(.from(
                srcloc,
                Struct,
                self,
                try anywhere.util.dupeOne(scope.env.arena, comptime_res),
            ));
            return scope.env.declExpr(srcloc, res);
        }
    };
    const Enum = struct {
        // to use at runtime, this has to get converted to a target-specific type
        const Field = struct {
            name: Types.Key.ComptimeValue,
            value: usize,
        };
        srcloc: SrcLoc,
        fields: []const Field,
        const ComptimeValue = usize;

        fn name(self_any: anywhere.util.AnyPtr, env: *Env) Error![]const u8 {
            const self = self_any.toConst(@This());
            return try std.fmt.allocPrint(env.arena, "enum({d}, {d})", .{ self.srcloc.file_id, self.srcloc.offset });
        }
        fn access_type(self_any: anywhere.util.AnyPtr, scope: *Scope, slot: Type, obj: Type, prop: parser.AstExpr, srcloc: SrcLoc) Error!Expr {
            const self = self_any.toConst(@This());
            _ = slot;
            _ = obj;

            const key = try scope.handleExpr(Types.Key.ty, prop);
            const ctk = try scope.env.expectComptimeKey(key);

            for (self.fields) |field| {
                if (field.name == ctk) return try scope.env.declExpr(srcloc, try scope.env.addDecl(.from(
                    srcloc, // :/
                    Enum,
                    self,
                    try anywhere.util.dupeOne(scope.env.arena, field.value),
                )));
            }
            return scope.env.addErr(srcloc, "Field {s} does not exist on type {s}", .{ try ctk.name(scope.env), try name(self_any, scope.env) });
        }
    };
    const Int = struct {
        min: i128,
        max: i128,
        pub const ComptimeValue = i128;
        // if we need referential equality between the same ints this is a bit more complicated
        pub fn fromIntTy(comptime int_ty: type) Type {
            return .from(@This(), &.{ .min = std.math.minInt(int_ty), .max = std.math.maxInt(int_ty) });
        }

        fn name(self_any: anywhere.util.AnyPtr, env: *Env) Error![]const u8 {
            const self = self_any.toConst(@This());

            if (self.min == self.max) return try std.fmt.allocPrint(env.arena, "int({d})", .{self.min});
            if (self.min == std.math.minInt(i32) and self.max == std.math.maxInt(i32)) return try std.fmt.allocPrint(env.arena, "i32", .{});
            return try std.fmt.allocPrint(env.arena, "int({d}, {d})", .{ self.min, self.max });
        }
        fn from_number(self_any: anywhere.util.AnyPtr, scope: *Scope, slot: Type, num: []const u8, srcloc: SrcLoc) Error!Expr {
            const self = self_any.toConst(@This());
            const parse_res = std.fmt.parseInt(ComptimeValue, num, 10) catch |e| switch (e) {
                error.Overflow => return scope.env.addErr(srcloc, "integer out of range", .{}),
                error.InvalidCharacter => return scope.env.addErr(srcloc, "invalid character in number", .{}),
            };
            if (parse_res < self.min or parse_res > self.max) return scope.env.addErr(srcloc, "integer out of range for type {s}", .{try slot.name(scope.env)});
            return try scope.env.declExpr(srcloc, try scope.env.addDecl(.from(
                srcloc,
                Int,
                self,
                try anywhere.util.dupeOne(scope.env.arena, parse_res),
            )));
        }
    };
};

const Type = struct {
    vtable: *const Vtable,
    data: anywhere.util.AnyPtr,
    const Vtable = struct {
        name: *const fn (self: anywhere.util.AnyPtr, env: *Env) Error![]const u8,
        access: ?*const fn (self: anywhere.util.AnyPtr, scope: *Scope, slot: Type, obj: Expr, prop: parser.AstExpr, srcloc: SrcLoc) Error!Expr = null,
        call: ?*const fn (self: anywhere.util.AnyPtr, scope: *Scope, slot: Type, method: Expr, arg: parser.AstExpr, srcloc: SrcLoc) Error!Expr = null,
        /// used by bound_fn. this will be from a symbol key.
        bound_call: ?*const fn (self: anywhere.util.AnyPtr, scope: *Scope, slot: Type, method: Expr, binding: Types.Key.ComptimeValue, arg: parser.AstExpr, srcloc: SrcLoc) Error!Expr = null,
        from_map: ?*const fn (self: anywhere.util.AnyPtr, scope: *Scope, slot: Type, ents: []MapEnt, srcloc: SrcLoc) Error!Expr = null,
        access_type: ?*const fn (self: anywhere.util.AnyPtr, scope: *Scope, slot: Type, obj: Type, prop: parser.AstExpr, srcloc: SrcLoc) Error!Expr = null,
        from_number: ?*const fn (self: anywhere.util.AnyPtr, scope: *Scope, slot: Type, num: []const u8, srcloc: SrcLoc) Error!Expr = null,
        from_string: ?*const fn (self: anywhere.util.AnyPtr, scope: *Scope, slot: Type, str: []const u8, srcloc: SrcLoc) Error!Expr = null,
    };
    pub fn name(self: Type, env: *Env) Error![]const u8 {
        return self.vtable.name(self.data, env);
    }
    pub fn access(self: Type, scope: *Scope, slot: Type, obj: Expr, prop: parser.AstExpr, srcloc: SrcLoc) Error!Expr {
        if (self.vtable.access == null) return scope.env.addErr(scope.tree.src(prop), "Type '{s}' does not support access", .{try self.name(scope.env)});
        return self.vtable.access.?(self.data, scope, slot, obj, prop, srcloc);
    }
    pub fn call(self: Type, scope: *Scope, slot: Type, method: Expr, arg: parser.AstExpr, srcloc: SrcLoc) Error!Expr {
        if (self.vtable.call == null) return scope.env.addErr(scope.tree.src(arg), "Type '{s}' does not support call", .{try self.name(scope.env)});
        return self.vtable.call.?(self.data, scope, slot, method, arg, srcloc);
    }
    pub fn from(comptime T: type, val: *const T) Type {
        return .{ .vtable = comptime autoVtable(Type.Vtable, T), .data = .from(T, val) };
    }
    pub fn is(self: Type, comptime T: type) bool {
        return self.vtable == comptime autoVtable(Type.Vtable, T);
    }
};
const BasicBlock = struct {
    arg_types: []Type,
};
const Decl = struct {
    const Index = enum(u64) {
        none = std.math.maxInt(u64),
        _,
    };

    dependencies: []Decl.Index,
    srcloc: SrcLoc,

    resolved_type: ?Type,
    resolved_value_ptr: ?anywhere.util.AnyPtr,

    analysis_state: union(enum) {
        decl_cache_uninitialized: DeclCacheEnt,
        analyzing,
        done,
    },

    fn from(srcloc: SrcLoc, comptime Ty: type, type_arg: *const Ty, value: *const Ty.ComptimeValue) Decl {
        return .{
            .dependencies = &.{},
            .srcloc = srcloc,
            .resolved_type = .from(Ty, type_arg),
            .resolved_value_ptr = .from(Ty.ComptimeValue, value),
            .analysis_state = .done,
        };
    }
};
const Expr = struct {
    ty: Type,
    value: Value,
    srcloc: SrcLoc,
    const Value = union(enum) {
        compiletime: Decl.Index,
        runtime: anywhere.util.AnyPtr,
    };
};

/// per-scope
const Scope = struct {
    env: *Env,
    tree: *const parser.AstTree,
    with_slot_ty: ?Type = null,
    block: anywhere.util.AnyPtr,

    fn handleExpr(scope: *Scope, slot: Type, expr: parser.AstExpr) Error!Expr {
        return handleExpr_inner2(scope, slot, expr);
    }
};
const DeclCacheEnt = struct {
    value: anywhere.util.AnyPtr,
    vtable: *const Vtable,
    const Vtable = struct {
        hash: *const fn (self: anywhere.util.AnyPtr, env: *Env) u32,
        eql: *const fn (lhs: anywhere.util.AnyPtr, rhs: anywhere.util.AnyPtr, env: *Env) bool,
        init: *const fn (self: anywhere.util.AnyPtr, env: *Env) Error!Decl,
    };
};
const DeclCacheCtx = struct {
    env: *Env,
    pub fn eql(ctx: DeclCacheCtx, a: DeclCacheEnt, b: DeclCacheEnt, _: usize) bool {
        if (a.vtable != b.vtable) return false;
        return a.vtable.eql(a.value, b.value, ctx.env);
    }
    pub fn hash(ctx: DeclCacheCtx, a: DeclCacheEnt) u32 {
        return @as(u32, @truncate(@intFromPtr(a.vtable))) ^ a.vtable.hash(a.value, ctx.env);
    }
};
/// per-target
const Env = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    has_error: bool = false,
    decls: std.ArrayListUnmanaged(Decl),
    comptime_keys: std.ArrayListUnmanaged(ComptimeKeyValue),
    string_to_comptime_key_map: std.ArrayHashMapUnmanaged(Types.Key.ComptimeValue, void, void, true),
    backend: Backend,
    decl_cache: std.ArrayHashMapUnmanaged(DeclCacheEnt, Decl.Index, DeclCacheCtx, true),

    const ComptimeKeyValue = union(enum) {
        string: []const u8,
        symbol: []const u8,
    };
    const CtkCtx = struct {
        env: *Env,
        pub fn hash(self: CtkCtx, key: []const u8) u32 {
            _ = self;
            return std.array_hash_map.hashString(key);
        }
        pub fn eql(self: CtkCtx, a: []const u8, b: Types.Key.ComptimeValue, _: usize) bool {
            const val = self.env.comptime_keys.items[@intCast(@intFromEnum(b))];
            if (val != .string) return false;
            return std.mem.eql(u8, a, val.string);
        }
    };
    fn comptimeKeyFromString(env: *Env, str: []const u8) Error!Types.Key.ComptimeValue {
        try env.comptime_keys.ensureUnusedCapacity(env.gpa, 1);
        const gpres = try env.string_to_comptime_key_map.getOrPutAdapted(env.gpa, str, CtkCtx{ .env = env });
        if (!gpres.found_existing) {
            gpres.key_ptr.* = @enumFromInt(env.comptime_keys.items.len);
            env.comptime_keys.appendAssumeCapacity(.{ .string = env.arena.dupe(u8, str) catch @panic("oom") });
            gpres.value_ptr.* = {};
        }
        return gpres.key_ptr.*;
    }

    pub fn addErr(self: *Env, srcloc: SrcLoc, comptime msg: []const u8, fmt: anytype) Error {
        self.has_error = true;
        _ = srcloc;
        std.log.err("[compiler] " ++ msg, fmt);
        return error.ContainsError;
    }

    pub fn makeInfer(self: *Env, child: Type) Error!Type {
        return .from(Types.Infer, try anywhere.util.dupeOne(self.arena, Types.Infer{ .extends = child }));
    }
    pub fn readInfer(self: *Env, infer_idx: Type) ?Type {
        _ = self;
        _ = infer_idx;
        @panic("TODO");
    }
    pub fn addDecl(self: *Env, decl: Decl) Error!Decl.Index {
        const res = self.decls.items.len;
        try self.decls.append(self.gpa, decl);
        return @enumFromInt(res);
    }
    pub fn declExpr(self: *Env, srcloc: SrcLoc, decl: Decl.Index) Error!Expr {
        const resolved = try self.resolveDeclType(decl);
        return .{
            .ty = resolved.resolved_type.?,
            .value = .{ .compiletime = decl },
            .srcloc = srcloc,
        };
    }
    pub fn resolveDeclType(self: *Env, decl: Decl.Index) Error!Decl {
        const res = self.decls.items[@intFromEnum(decl)];
        if (res.resolved_type == null) switch (res.analysis_state) {
            .decl_cache_uninitialized => |ent| {
                self.decls.items[@intFromEnum(decl)].analysis_state = .analyzing;
                self.decls.items[@intFromEnum(decl)] = try ent.vtable.init(ent.value, self);
                return self.decls.items[@intFromEnum(decl)];
            },
            .analyzing => return self.addErr(res.srcloc, "cyclic dependency", .{}),
            .done => unreachable,
        };
        return res;
    }
    pub fn resolveDeclValue(self: *Env, decl: Decl.Index) Error!Decl {
        const res = try self.resolveDeclType(decl);
        if (res.resolved_value_ptr == null) @panic("TODO resolve value_ptr for decl");
        return res;
    }
    pub fn castExpr(self: *Env, src: Expr, res_ty: Type, res_srcloc: SrcLoc) Expr {
        _ = self;
        return .{ .ty = res_ty, .value = src.value, .srcloc = res_srcloc };
    }
    fn expectComptime(self: *Env, expr: Expr, comptime Expected: type) Error!*Expected.ComptimeValue {
        switch (expr.value) {
            .runtime => return self.addErr(expr.srcloc, "Expected a comptime value, got a runtime value", .{}),
            .compiletime => |ct| {
                if (!expr.ty.is(Expected)) return self.addErr(expr.srcloc, "Expected {s}, got {s}", .{ @typeName(Expected), try expr.ty.name(self) });
                const val = try self.resolveDeclValue(ct);
                std.debug.assert(val.resolved_type != null);
                std.debug.assert(val.resolved_type.?.is(Expected));
                std.debug.assert(val.resolved_value_ptr != null);
                return val.resolved_value_ptr.?.to(Expected.ComptimeValue);
            },
        }
    }
    fn expectComptimeKey(self: *Env, expr: Expr) Error!Types.Key.ComptimeValue {
        return (try self.expectComptime(expr, Types.Key)).*;
    }
    pub fn cachedDecl(self: *Env, comptime EntTy: type, ent_value: EntTy) Error!Decl.Index {
        const gpres = try self.decl_cache.getOrPutContext(self.gpa, .{ .value = .from(EntTy, &ent_value), .vtable = comptime autoVtable(DeclCacheEnt.Vtable, EntTy) }, .{ .env = self });
        if (!gpres.found_existing) {
            errdefer self.decl_cache.swapRemoveAt(self.decl_cache.keys().len - 1);
            const val_dupe = try anywhere.util.dupeOne(self.arena, ent_value);
            gpres.key_ptr.value = .from(EntTy, val_dupe);
            gpres.value_ptr.* = try self.addDecl(.{
                .analysis_state = .{ .decl_cache_uninitialized = gpres.key_ptr.* },
                .dependencies = &.{},
                .srcloc = .fromSrc(@src()), // will get replaced on analyze
                .resolved_type = null,
                .resolved_value_ptr = null,
            });
            // ^ TODO: we do not have to initialize immediately
            // instead we can store a decl holding the key_ptr, and on
            // type_analyze, we can call init()
        }
        return gpres.value_ptr.*;
    }
};
// per-compiler invocation
const Global = struct {};
const Error = error{
    OutOfMemory,
    ContainsError,
};
const BuiltinDecl = struct {
    fn hash(_: anywhere.util.AnyPtr, _: *Env) u32 {
        return 0;
    }
    fn eql(_: anywhere.util.AnyPtr, _: anywhere.util.AnyPtr, _: *Env) bool {
        return true;
    }
    fn init(_: anywhere.util.AnyPtr, _: *Env) Error!Decl {
        return .from(
            .fromSrc(@src()),
            Types.Builtin,
            &.{},
            &{},
        );
    }
};
const VoidDecl = struct {
    fn hash(_: anywhere.util.AnyPtr, _: *Env) u32 {
        return 0;
    }
    fn eql(_: anywhere.util.AnyPtr, _: anywhere.util.AnyPtr, _: *Env) bool {
        return true;
    }
    fn init(_: anywhere.util.AnyPtr, _: *Env) Error!Decl {
        return .from(
            .fromSrc(@src()),
            Types.Void,
            &.{},
            &{},
        );
    }
};
inline fn handleExpr_inner2(scope: *Scope, slot: Type, expr: parser.AstExpr) Error!Expr {
    const tree = scope.tree;
    const srcloc = tree.src(expr);
    switch (tree.tag(expr)) {
        .call => {
            // a: b is equivalent to {%1 = {infer T}: a; T.call(a, b)}
            const method_ast, const arg_ast = tree.children(expr, 2);

            // if we wanted to, we could pass the slot as:
            // `(arg: infer T) => Slot`, then make the arg slot T
            const method_expr = try scope.handleExpr(try scope.env.makeInfer(Types.Unknown.ty), method_ast);
            // now get type.arg_type
            // then call type.call(arg_expr)
            return method_expr.ty.call(scope, slot, method_expr, arg_ast, srcloc);
        },
        .access => {
            // a.b is equivalent to {%1 = {infer T}: a; T.access(a, b)}
            const obj_ast, const prop_ast = tree.children(expr, 2);

            // if we wanted, slot could be `{[infer T]: Slot}` then make prop slot T
            const obj_expr = try scope.handleExpr(try scope.env.makeInfer(Types.Unknown.ty), obj_ast);
            // get type.prop_type
            // call type.access(prop_expr)

            return obj_expr.ty.access(scope, slot, obj_expr, prop_ast, srcloc);
        },
        .builtin => {
            _ = tree.children(expr, 0);
            return scope.env.declExpr(srcloc, try scope.env.cachedDecl(BuiltinDecl, .{}));
        },
        .code => {
            // handle each expr in sequence
            var child = tree.firstChild(expr);
            while (child) |c| {
                const next = tree.next(c).?;
                const is_last = tree.tag(next) == .srcloc;

                if (is_last) return scope.handleExpr(slot, c);
                if (scope.handleExpr(Types.Void.ty, c)) |_| {} else |_| {}

                child = next;
            }
            unreachable; // there is always at least one expr in a code
        },
        .key => {
            const offset, const len = tree.children(expr, 2);
            const str = tree.readStr(offset, len);

            return scope.env.declExpr(srcloc, try scope.env.addDecl(.from(
                .fromSrc(@src()), // not sure what to use for this srcloc if we will have one per key
                Types.Key,
                &.{},
                try anywhere.util.dupeOne(scope.env.arena, try scope.env.comptimeKeyFromString(str)),
            )));
        },
        .map => {
            // we should consider preprocessing maps before sending them to the vtable:
            // - that way we can add in any decls to the scope that were added in the map
            //   & skip showing them to the vtable
            // - the vtable has an easier time because it gets `[]MapEntry`

            var ents: std.array_list.Managed(MapEnt) = .init(scope.env.arena);

            var ch = scope.tree.firstChild(expr).?;
            while (scope.tree.tag(ch) != .srcloc) : (ch = scope.tree.next(ch).?) {
                switch (scope.tree.tag(ch)) {
                    .map_entry => {
                        const key, const value = scope.tree.children(ch, 2);
                        try ents.append(.{ .key = key, .value = value, .srcloc = scope.tree.src(ch) });
                    },
                    .bind => {
                        scope.env.addErr(scope.tree.src(ch), "TODO impl bind in map", .{}) catch {};
                    },
                    else => {
                        try ents.append(.{ .key = null, .value = ch, .srcloc = scope.tree.src(ch) });
                    },
                }
            }

            if (slot.vtable.from_map == null) return scope.env.addErr(tree.src(expr), "Initialize map in slot {s} not supported", .{try slot.name(scope.env)});
            return slot.vtable.from_map.?(slot.data, scope, slot, ents.items, srcloc);
        },
        .init_void => {
            return scope.env.declExpr(srcloc, try scope.env.cachedDecl(VoidDecl, .{}));
        },
        .slot => {
            if (scope.with_slot_ty == null) unreachable;
            return scope.env.declExpr(srcloc, try scope.env.addDecl(.from(
                .fromSrc(@src()),
                Types.Ty,
                &.{},
                try anywhere.util.dupeOne(scope.env.arena, scope.with_slot_ty.?),
            )));
        },
        .with_slot => {
            const ch = scope.tree.children(expr, 1);
            if (scope.with_slot_ty != null) unreachable;
            scope.with_slot_ty = slot;
            defer scope.with_slot_ty = null;
            return scope.handleExpr(slot, ch);
        },
        .number => {
            const offset, const len = tree.children(expr, 2);
            const num_value = tree.readStr(offset, len);
            if (slot.vtable.from_number == null) return scope.env.addErr(tree.src(expr), "Initialize number in slot {s} not supported", .{try slot.name(scope.env)});
            return slot.vtable.from_number.?(slot.data, scope, slot, num_value, srcloc);
        },
        .string => {
            const offset = tree.firstChild(expr).?;
            const len = tree.next(offset).?;
            if (tree.tag(tree.next(len).?) != .srcloc) {
                return scope.env.addErr(tree.src(expr), "TODO: support string aggrandizements", .{});
            }

            const str_value = tree.readStr(offset, len);

            if (slot.vtable.from_string == null) return scope.env.addErr(tree.src(expr), "Initialize string in slot {s} not supported", .{try slot.name(scope.env)});
            return slot.vtable.from_string.?(slot.data, scope, slot, str_value, srcloc);
        },
        else => |t| return scope.env.addErr(tree.src(expr), "TODO expr: {s}", .{@tagName(t)}),
    }
}
const MapEnt = struct {
    key: ?parser.AstExpr,
    value: parser.AstExpr,
    srcloc: SrcLoc,
};

test "rv" {
    if (true) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    var tree = parser.parse(gpa, @embedFile("tests/rv.cvl"));
    defer tree.deinit();
    try std.testing.expect(!tree.owner.has_errors);

    // it is parsed. now handle the root file decl
    const root = tree.root();
    const first_decl = tree.firstChild(root).?;
    const fn_def = tree.next(tree.firstChild(first_decl).?).?;
    const fn_body = tree.next(tree.firstChild(fn_def).?).?;
    // std.log.err("val: {s}", .{@tagName(tree.tag(fn_body))});
    // it's a code expr

    var arena_backing = std.heap.ArenaAllocator.init(gpa);
    defer arena_backing.deinit();
    var env: Env = .{
        .gpa = gpa,
        .arena = arena_backing.allocator(),
        .decls = .empty,
        .comptime_keys = .empty,
        .string_to_comptime_key_map = .empty,
        .backend = .{
            .data = .from(Backends.Riscv32, &.{}),
            .vtable = Backends.Riscv32.vtable,
        },
        .decl_cache = .empty,
    };
    defer env.decl_cache.deinit(gpa);
    defer env.string_to_comptime_key_map.deinit(gpa);
    defer env.comptime_keys.deinit(gpa);
    defer env.decls.deinit(env.gpa);
    var emit_block: Backends.Riscv32.EmitBlock = .{
        .instructions = .empty,
    };
    defer emit_block.instructions.deinit(env.gpa);
    var scope: Scope = .{
        .env = &env,
        .tree = &tree,
        .block = .from(Backends.Riscv32.EmitBlock, &emit_block),
    };
    const res = try scope.handleExpr(try env.makeInfer(Types.Unknown.ty), fn_body);
    _ = res;

    var printed = std.ArrayListUnmanaged(u8).empty;
    defer printed.deinit(gpa);
    try emit_block.print(printed.writer(gpa).any());
    // in the future this may become:
    // x10 = x0 (.move) (toRuntime on the number emits nothing & returns x0)
    // ecall (.instr)
    // x10 = fakeuser x10 (.fakeuser)
    if (env.has_error) return error.HasError;
    try anywhere.util.testing.snap(@src(),
        \\x11 = ADD x10 x12
        \\
    , printed.items);
}

test "zig" {
    const gpa = std.testing.allocator;
    const src_in = try std.fs.cwd().readFileAlloc(gpa, "src/tests/zig.cvl", std.math.maxInt(usize));
    defer gpa.free(src_in);
    var tree = parser.parse(gpa, src_in);
    defer tree.deinit();
    if (tree.owner.has_errors) {
        var out = std.array_list.Managed(u8).init(gpa);
        defer out.deinit();
        std.log.err("has errors: `{s}`", .{try parser.testParser(&out, .{}, src_in)});
    }
    try std.testing.expect(!tree.owner.has_errors);

    // it is parsed. now handle the root file decl
    const root = tree.root();
    const first_decl = tree.firstChild(root).?;
    const fn_def = tree.next(tree.firstChild(first_decl).?).?;
    const fn_body = tree.next(tree.firstChild(fn_def).?).?;
    // std.log.err("val: {s}", .{@tagName(tree.tag(fn_body))});
    // it's a code expr

    var arena_backing = std.heap.ArenaAllocator.init(gpa);
    defer arena_backing.deinit();
    var env: Env = .{
        .gpa = gpa,
        .arena = arena_backing.allocator(),
        .decls = .empty,
        .comptime_keys = .empty,
        .string_to_comptime_key_map = .empty,
        .backend = .{
            .data = .from(Backends.Zig, &.{}),
            .vtable = Backends.Zig.vtable,
        },
        .decl_cache = .empty,
    };
    defer env.decl_cache.deinit(gpa);
    defer env.string_to_comptime_key_map.deinit(gpa);
    defer env.comptime_keys.deinit(gpa);
    defer env.decls.deinit(env.gpa);
    var emit_block: Backends.Zig.EmitBlock = .{
        .out = .empty,
    };
    defer emit_block.out.deinit(env.gpa);
    var scope: Scope = .{
        .env = &env,
        .tree = &tree,
        .block = .from(Backends.Zig.EmitBlock, &emit_block),
    };
    const res = try scope.handleExpr(try env.makeInfer(Types.Unknown.ty), fn_body);
    _ = res;

    if (env.has_error) return error.HasError;
    try anywhere.util.testing.snap(@src(),
        \\_ = std.log.info('hello, world!');
    , emit_block.out.items);
}

// notes:
// - runtime backing
// - an int[0, 255] at comptime is backed by comptime_int, but at runtime is backed by u8
// - that's fine, it just means when taking a comptime decl and emitting it at runtime,
//   we have to define transforms.
