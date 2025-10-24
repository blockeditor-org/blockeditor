const std = @import("std");
const rvemu = @import("rvemu");

pub const EmitBlock = struct {
    // two pass:
    // - one: the instrs are made with references to other instrs
    //   and references to block jumps
    // - two: register allocation & emit
    //   - register allocation may require storing instructions to the stack
    //   - explicit registers can never be stored to the stack
    //     - (ie no saving the value in x10 before )
    pub const RvVar = enum(u32) {
        _,
        pub const lowest_int_reg = std.math.maxInt(u32) - 0b11111;
        pub fn fromIntReg(reg: u5) RvVar {
            return @enumFromInt(lowest_int_reg + @as(u32, reg));
        }
        pub fn isIntReg(rv: RvVar) ?u5 {
            const rvint = @intFromEnum(rv);
            if (rvint >= lowest_int_reg) return @intCast(rvint - (lowest_int_reg));
            return null;
        }
        pub fn format(value: RvVar, writer: *std.Io.Writer) !void {
            if (value.isIntReg()) |intreg| {
                try writer.print("x{d}", .{intreg});
            } else {
                try writer.print("%{d}", .{@intFromEnum(value)});
            }
        }
    };
    pub const RvInstr = union(enum) {
        instr: struct {
            // null = fakeuser
            // rather than fakeuser, couldn't we have instructions indicate what they use?
            // like 'ecall'. make it say 'reads <...regs>, writes <...regs>' but as fakeread and fakewrite?
            op: ?rvemu.rvinstrs.InstrName,
            rs1: ?RvVar = null,
            rs2: ?RvVar = null,
            rs3: ?RvVar = null,
            rd: ?RvVar = null,
            imm_11_0: ?i12 = null,
        },
    };
    instructions: std.ArrayListUnmanaged(RvInstr),

    pub fn print(self: *EmitBlock, writer: std.Io.AnyWriter) anyerror!void {
        for (self.instructions.items) |instr| {
            switch (instr) {
                .instr => |m| {
                    if (m.rd) |rd| try writer.print("{} = ", .{rd});
                    if (m.op) |o| {
                        try writer.print("{s}", .{@tagName(o)});
                    } else {
                        try writer.writeAll("fakeuser");
                    }
                    if (m.rs1) |rs1| try writer.print(" {}", .{rs1});
                    if (m.rs2) |rs2| try writer.print(" {}", .{rs2});
                    if (m.rs3) |rs3| try writer.print(" {}", .{rs3});
                    if (m.imm_11_0) |imm_11_0| try writer.print(" 0x{x}", .{imm_11_0});
                    try writer.writeAll("\n");
                },
            }
        }
    }
};
