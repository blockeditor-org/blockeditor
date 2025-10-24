// if we want to switch to wasm, we can modify this
// https://github.com/rdunnington/bytebox

const util = @import("anywhere").util;
const std = @import("std");
const log = std.log.scoped(.rvemu);
pub const rvinstrs = @import("rvinstrs.zig");
pub const loader = @import("loader.zig");

comptime {
    std.debug.assert(@import("builtin").cpu.arch.endian() == .little);
}

const InstrEnum = blk: {
    const total_len = rvinstrs.instrs.len + 1;
    var fields: [total_len]std.builtin.Type.EnumField = undefined; //[1]std.builtin.Type.EnumField{undefined} ** total_len;
    var i: usize = 0;
    fields[i] = std.builtin.Type.EnumField{
        .name = "invalid",
        .value = i,
    };
    i += 1;
    for (rvinstrs.instrs) |instr| {
        fields[i] = std.builtin.Type.EnumField{
            .name = @tagName(instr.name),
            .value = i,
        };
        i += 1;
    }

    // fields = fields ++ ;

    break :blk @Type(std.builtin.Type{ .Enum = .{
        .tag_type = std.math.IntFittingRange(0, fields.len),
        .fields = &fields,
        .decls = &.{},
        .is_exhaustive = true,
    } });
};

fn decodeInstr(instr_in: Instruction, user_data: anytype) @TypeOf(user_data).RetTy {
    // how to improve:
    // - we can make a few different masks and then '&' them with the instr
    //   and look them up in a map.
    // - feels like there should be a fancy way to do that with a hash
    // - anyway say we have like 8 masks we need : that's a minimum of like
    //   16 cpu instructions just to make all the masked versions (have to mask
    //   and set bitflags to say what we masked to prevent false positives)
    // - and then a few more instructions to check the map
    // - goodness.
    // sample:
    //   const instr_u64: u64 = instr;
    //   const mask_opcode: u32 = @bitCast(AnyType{.opcode = ~0, .unknown = 0});
    //   const flag_opcode: u64 = 1 << 32;
    //   const mask_1: u64 = (instr_u64 & (mask_opcode)) | (flag_opcode)
    // that doesn't seem too bad to implement. and then we can emit a switch statement
    // on all the masks and hopefully the compiler can make it nice. or we can try to
    // make our own ComptimeStringMap but for numbers.
    // => compiler turns a switch on 100 random ints mapping to enum values into ~33 instructions
    //       with a bunch of jumps. that's not ideal.
    // ok probably skip this fancy bitflags stuff (unless a comptimeStringMap for numbers is really good)
    //       - comptimeStringMap seems to search in an array of strings sorted by length.
    //         that doesn't look like what we want.
    // let's do probably: a top level table based just on opcode -> inner tables8
    inline for (rvinstrs.instrs) |instr_details| {
        if (instr_in.any.opcode == instr_details.opcode) {
            var match = true;
            if (instr_details.funct2) |funct2| if (instr_in.R4.funct2 != funct2) {
                match = false;
            };
            if (instr_details.funct3) |funct3| if (instr_in.R4.funct3 != funct3) {
                match = false;
            };
            if (instr_details.funct7) |funct7| if (instr_in.R.funct7 != funct7) {
                match = false;
            };
            if (instr_details.funct7_sub5) |funct7_sub5| if (instr_in.RAtomic.funct7_sub5 != funct7_sub5) {
                match = false;
            };
            if (instr_details.imm_11_0) |imm_11_0| if (instr_in.I.imm_11_0 != imm_11_0) {
                match = false;
            };
            if (instr_details.rd) |rd| if (instr_in.I.rd != rd) {
                match = false;
            };
            if (instr_details.rs1) |rs1| if (instr_in.I.rs1 != rs1) {
                match = false;
            };
            if (instr_details.rs2) |rs2| if (instr_in.B.rs2 != rs2) {
                match = false;
            };

            if (match) {
                return user_data.handle(instr_details, instr_in);
            }
        }
    }
    return user_data.handleInvalid(instr_in);
}

// we shouldn't have to implement this. this is a pain. it's annoying to read riscv docs
// alternatives:
// - https://github.com/cnlohr/mini-rv32ima
// we need full coveage of base, a, d, m for zig's 'baseline' riscv
// - can probably skip atomics? that's for multithreading
// we also should conformance test probably

// https://drive.google.com/file/d/1uviu1nH-tScFfgrovvFCrj7Omv8tFtkp/view

pub const FloatingPointControlStatus = packed struct(u32) {
    NX: u1,
    UF: u1,
    OF: u1,
    DZ: u1,
    NV: u1,
    Rounding_Mode: u3,
    _Reserved: u24,
};

pub const PtrRange = struct {
    generation: u32,
    min: u32,
    max: u32,
    first_child: ?*PtrRange,
    next: ?*PtrRange,
};
pub const ShadowFloatReg = struct {
    is_undefined: bool,
};
pub const ShadowIntReg = packed struct(u64) {
    // viral. if any arg has it, the result has it. with simd, it is per-item. branching
    // on undefined = error. calls can decide what to do for undefined.
    is_undefined: bool,
    // if one arg has it, the result has it. if 2+ or 0 args have it, the result does not.
    range_offset: u31,
    range_generation: u32,
};
const EmulatorCfg = struct {
    memory_safety: bool,
    track_features: bool,
};
const cfg: EmulatorCfg = .{
    .memory_safety = true,
    .track_features = true,
};
const ShadowByte = packed struct(u8) {
    is_leftmost_byte_of_pointer: bool,
    is_undefined: bool,
    _6: u6,
};

pub const Emulator = struct {
    memory: []align(@alignOf(u128)) u8,
    // shadow_memory: []ShadowByte,

    pc: u32 = 0,
    int_regs: [32]i32 = @splat(0), // reg 0 is hardcoded to 0 so yeah
    shadow_int_regs: [32]ShadowIntReg = @splat(.{
        .is_undefined = false,
        .range_offset = 0,
        .range_generation = 0,
    }),
    fcsr: FloatingPointControlStatus = @bitCast(@as(u32, 0)),
    float_regs: [32]f32 = @splat(0),
    shadow_float_regs: [32]ShadowFloatReg = @splat(.{ .is_undefined = false }),
    cost: u128 = 0,

    features: if (cfg.track_features) struct {
        used_instructions: std.EnumSet(rvinstrs.InstrName) = .initEmpty(),
    } else void = if (cfg.track_features) .{} else {},

    pub fn readReg(self: *Emulator, comptime bank: rvinstrs.RegBank, reg: u5) bank.Type() {
        return switch (bank) {
            .sint => self.int_regs[reg],
            .uint => @bitCast(self.int_regs[reg]),
            .float => self.float_regs[reg],
            .double => self.double_regs[reg],
        };
    }
    pub fn writeReg(self: *Emulator, comptime bank: rvinstrs.RegBank, reg: u5, val: bank.Type()) void {
        switch (bank) {
            .sint => {
                if (reg == 0) return;
                self.int_regs[reg] = val;
            },
            .uint => {
                if (reg == 0) return;
                self.int_regs[reg] = @bitCast(val);
            },
            .float => {
                self.float_regs[reg] = val;
            },
            .double => {
                self.double_regs[reg] = val;
            },
        }
    }

    pub fn readIntReg(self: *Emulator, reg: u5) i32 {
        return self.readReg(.sint, reg);
    }
    pub fn writeIntReg(self: *Emulator, reg: u5, value: i32) void {
        return self.writeReg(.sint, reg, value);
    }

    pub fn addCost(emu: *Emulator, add_count: usize) !void {
        emu.cost += add_count;
    }

    pub fn step(emu: *Emulator) !void {
        try emu.addCost(1);
        const instr = try util.safePtrCast(Instruction, try emu.readSlice(emu.pc, 4));
        // decodeInstr(instr.*, DecodeToFmt{});
        try decodeInstr(instr.*, DecodeToCall{ .emu = emu });
        std.debug.assert(emu.int_regs[0] == 0);
        emu.pc += 4;
    }
    pub fn run(emu: *Emulator, usr_data: anytype, comptime handle_syscall: anytype) !void {
        while (true) {
            emu.step() catch |e| switch (e) {
                error.Ecall => {
                    try emu.addCost(100); // base syscall cost
                    const syscall_tag: i32 = emu.readIntReg(17);
                    const syscall_args = [_]i32{
                        emu.readIntReg(10),
                        emu.readIntReg(11),
                        emu.readIntReg(12),
                        emu.readIntReg(13),
                        emu.readIntReg(14),
                        emu.readIntReg(15),
                    };
                    const res = try handle_syscall(usr_data, syscall_tag, syscall_args);
                    emu.writeIntReg(10, res);
                    emu.pc += 4;
                },
                else => return e,
            };
        }
    }

    pub fn logState(emu: *Emulator) void {
        log.info("pc: {d}, int_regs: {d}", .{ emu.pc, emu.int_regs });
    }

    /// when used in a syscall, after the syscall is complete we will check any regions
    /// read and store if they were modified. we will also make sure reads are only
    /// stored with their initial values before the syscall.
    pub fn readSlice(emu: *Emulator, ptr: usize, len: usize) ExecError![]u8 {
        if (ptr > emu.memory.len) return error.OutOfBoundsAccess;
        const sliced = emu.memory[ptr..];
        if (len > sliced.len) return error.OutOfBoundsAccess;
        return sliced[0..len];
    }

    pub fn loadElf(emu: *Emulator, disk: []align(@alignOf(u128)) u8) !void {
        const elf_res = try loader.loadElf(disk, emu.memory);

        emu.pc = elf_res.main_ptr;

        // put emu in main
        emu.writeIntReg(1, 0); // return address
        emu.writeIntReg(2, @bitCast(elf_res.stack_ptr)); // stack pointer.
        emu.writeIntReg(3, 0); // global pointer
        emu.writeIntReg(4, 0); // thread pointer
    }
    pub fn markUsedInstruction(emu: *Emulator, instr: rvinstrs.InstrName) void {
        if (!cfg.track_features) return;
        emu.features.used_instructions.setPresent(instr, true);
    }
};

fn storeInstr2(emu: *Emulator, comptime Size: type, lhs: i32, imm: i32, rhs: i32) !void {
    const addr_base: u32 = @bitCast(lhs);
    const addr_offset = imm;
    const addr: u32 = @intCast(@as(i33, addr_base) + addr_offset);

    const store_value: Size = @truncate(@as(u32, @bitCast(rhs)));
    const ptr = try util.safePtrCastMut(Size, try emu.readSlice(addr, @sizeOf(Size)));
    ptr.* = store_value;
}
fn loadInstr2(emu: *Emulator, comptime Size: type, lhs: i32, imm: i12) !i32 {
    const addr_base: u32 = @bitCast(lhs);
    const addr_offset = imm;
    const addr: u32 = @intCast(@as(i33, addr_base) + addr_offset);

    const ptr = try util.safePtrCastMut(Size, try emu.readSlice(addr, @sizeOf(Size)));
    return ptr.*;
}
fn condBr(emu: *Emulator, comptime compare: fn (a: i32, b: i32) bool, rs1: i32, rs2: i32, imm: i13) ExecError!void {
    // All branch instructions use the B-type instruction format. The 12-bit
    // B-immediate encodes signed offsets in multiples of 2 bytes. The
    // offset is sign-extended and added to the address of the branch
    // instruction to give the target address. The conditional branch range
    // is ±4 KiB.
    // ^ I feel like it should be multiples of 4 bytes and then the compilers can
    //    cry about it when they want to jump to the second half of a compressed
    //    instruction. it roughly doubles the range but may require the insertion
    //    of a NOP instruction at the jump target.

    // Branch instructions compare two registers. BEQ and BNE take the branch
    // if registers rs1 and rs2 are equal or unequal respectively. BLT and BLTU
    // take the branch if rs1 is less than rs2, using signed and unsigned
    // comparison respectively. BGE and BGEU take the branch if rs1 is greater
    // than or equal to rs2, using signed and unsigned comparison respectively.
    // Note, BGT, BGTU, BLE, and BLEU can be synthesized by reversing the
    // operands to BLT, BLTU, BGE, and BGEU, respectively.

    if (compare(rs1, rs2)) {
        const target_addr: u32 = @intCast(@as(i33, emu.pc) + imm);
        if (target_addr & 0b1 != 0) return error.MisalignedBranch;
        emu.pc = target_addr - 4; // we add 4 right after this runs
    }
}

const DecodeToEnum = struct {
    pub const RetTy = InstrEnum;
    pub fn handle(_: DecodeToEnum, comptime instr: rvinstrs.InstrSpec, _: Instruction) RetTy {
        return instr.name;
    }
    pub fn handleInvalid(_: DecodeToEnum, _: Instruction) RetTy {
        return .invalid;
    }
};
const u_type_instrs = struct {
    // in rvinstrs.zig, we'll have to define which banks the different things come from
    // so that we can use the right registers
    pub fn LUI(_: *Emulator, immediate: i32) ExecError!i32 {
        return immediate;
    }
    pub fn AUIPC(emu: *Emulator, immediate: i32) ExecError!i32 {
        return @intCast(@as(i33, emu.pc) + immediate);
    }
};
const i_type_instrs = struct {
    pub fn ADDI(_: *Emulator, lhs: i32, imm: i12) ExecError!i32 {
        return lhs +% imm;
    }
    pub fn ANDI(_: *Emulator, lhs: i32, imm: i12) ExecError!i32 {
        // Performs bitwise AND on register rs1 and the sign-extended 12-bit
        // immediate and place the result in rd
        return lhs & @as(i32, imm);
        // x[rd] = x[rs1] & sext(immediate)
    }
    pub fn ORI(_: *Emulator, lhs: i32, imm: i12) ExecError!i32 {
        return lhs | @as(i32, imm);
    }
    pub fn XORI(_: *Emulator, lhs: i32, imm: i12) ExecError!i32 {
        return lhs ^ @as(i32, imm);
    }

    pub fn LB(emu: *Emulator, lhs: i32, imm: i12) ExecError!i32 {
        return loadInstr2(emu, i8, lhs, imm); // byte
    }
    pub fn LH(emu: *Emulator, lhs: i32, imm: i12) ExecError!i32 {
        return loadInstr2(emu, i16, lhs, imm); // half
    }
    pub fn LW(emu: *Emulator, lhs: i32, imm: i12) ExecError!i32 {
        return loadInstr2(emu, i32, lhs, imm); // word
    }
    pub fn LBU(emu: *Emulator, lhs: i32, imm: i12) ExecError!i32 {
        return loadInstr2(emu, u8, lhs, imm); // byte unsigned
    }
    pub fn LHU(emu: *Emulator, lhs: i32, imm: i12) ExecError!i32 {
        return loadInstr2(emu, u16, lhs, imm); // half unsigned
    }

    pub fn SLTI(_: *Emulator, lhs: i32, imm: i12) ExecError!i32 {
        // SLTI (set less than immediate) places the value 1 in register rd if
        // register rs1 is less than the sign-extended immediate when both are
        // treated as signed numbers, else 0 is written to rd.
        return switch (cmp.lt(lhs, imm)) {
            false => 0,
            true => 1,
        };
    }
    pub fn SLTIU(_: *Emulator, lhs: i32, imm: i12) ExecError!i32 {
        // SLTIU is similar but compares the values as unsigned numbers (i.e.,
        // the immediate is first sign-extended to XLEN bits then treated as an
        // unsigned number). Note, SLTIU rd, rs1, 1 sets rd to 1 if rs1 equals
        // zero, otherwise sets rd to 0 (assembler pseudoinstruction SEQZ rd, rs).
        return switch (cmp.lt_u(lhs, imm)) {
            false => 0,
            true => 1,
        };
    }

    pub fn JALR(emu: *Emulator, lhs: u32, imm: i12) ExecError!u32 {
        // The indirect jump instruction JALR (jump and link register) uses the
        // I-type encoding. The target address is obtained by adding the
        // sign-extended 12-bit I-immediate to the register rs1, then setting the
        // least-significant bit of the result to zero. The address of the instruction
        // following the jump (pc+4) is written to register rd. Register x0 can be
        // used as the destination if the result is not required.
        const ret_addr = emu.pc + 4;
        var target_addr: u32 = @intCast(@as(i33, lhs) + imm);
        target_addr &= ~@as(u32, 0b1);
        emu.pc = target_addr - 4; // we add 4 right after this runs
        return ret_addr;
    }
};
const i_shift_type_instrs = struct {
    pub fn SLLI(_: *Emulator, lhs: u32, rhs: u5) ExecError!u32 {
        // Performs logical left shift on the value in register rs1 by the shift
        // amount held in the lower 5 bits of the immediate. In RV64, bit-25
        // is used to shamt[5].
        return lhs << rhs;
        // x[rd] = x[rs1] << shamt
    }
    pub fn SRLI(_: *Emulator, lhs: u32, rhs: u5) ExecError!u32 {
        return lhs >> rhs;
    }
    pub fn SRAI(_: *Emulator, lhs: i32, rhs: u5) ExecError!i32 {
        // Shift Right Arithmetic Immediate
        return lhs >> rhs;
    }
};
const s_type_instrs = struct {
    pub fn SB(emu: *Emulator, lhs: i32, imm: i12, rhs: i32) ExecError!void {
        try storeInstr2(emu, u8, lhs, imm, rhs);
    }
    pub fn SH(emu: *Emulator, lhs: i32, imm: i12, rhs: i32) ExecError!void {
        try storeInstr2(emu, u16, lhs, imm, rhs);
    }
    pub fn SW(emu: *Emulator, lhs: i32, imm: i12, rhs: i32) ExecError!void {
        try storeInstr2(emu, u32, lhs, imm, rhs);
    }
};
const r_type_instrs = struct {
    pub fn SLTU(_: *Emulator, lhs: i32, rhs: i32) ExecError!i32 {
        // Place the value 1 in register rd if register rs1 is less than register
        // rs2 when both are treated as unsigned numbers, else 0 is written to rd.
        return switch (cmp.lt_u(lhs, rhs)) {
            false => 0,
            true => 1,
        };
        // x[rd] = x[rs1] <u x[rs2]
    }
    pub fn SLT(_: *Emulator, lhs: i32, rhs: i32) ExecError!i32 {
        // Place the value 1 in register rd if register rs1 is less than register
        // rs2 when both are treated as signed numbers, else 0 is written to rd.
        return switch (cmp.lt(lhs, rhs)) {
            false => 0,
            true => 1,
        };
        // x[rd] = x[rs1] <u x[rs2]
    }
    /// SLL, SRL, and SRA perform logical left, logical right, and arithmetic right shifts on the value in register rs1 by the shift amount held in the lower 5 bits of register rs2.
    pub fn SLL(_: *Emulator, lhs: u32, rhs: i32) ExecError!u32 {
        const rhs_5b: u5 = @intCast(rhs & 0b11111);
        return lhs << rhs_5b;
    }
    pub fn SRL(_: *Emulator, lhs: u32, rhs: i32) ExecError!u32 {
        const rhs_5b: u5 = @intCast(rhs & 0b11111);
        return lhs >> rhs_5b;
    }
    pub fn SRA(_: *Emulator, lhs: i32, rhs: i32) ExecError!i32 {
        std.debug.assert(@as(i1, -1) >> 0 == -1);
        const rhs_5b: u5 = @intCast(rhs & 0b11111);
        return lhs >> rhs_5b;
    }
    pub fn AND(_: *Emulator, lhs: i32, rhs: i32) ExecError!i32 {
        return lhs & rhs;
    }
    pub fn OR(_: *Emulator, lhs: i32, rhs: i32) ExecError!i32 {
        return lhs | rhs;
    }
    pub fn XOR(_: *Emulator, lhs: i32, rhs: i32) ExecError!i32 {
        return lhs ^ rhs;
    }
    pub fn ADD(_: *Emulator, lhs: i32, rhs: i32) ExecError!i32 {
        return lhs +% rhs;
    }
    pub fn SUB(_: *Emulator, lhs: i32, rhs: i32) ExecError!i32 {
        // Subs the register rs2 from rs1 and stores the result in rd.
        // Arithmetic overflow is ignored and the result is simply the
        // low XLEN bits of the result.
        return lhs -% rhs;
        // x[rd] = x[rs1] - x[rs2]
    }

    //
    // RV32M Standard Extension
    //

    pub fn MUL(_: *Emulator, lhs: i32, rhs: i32) ExecError!i32 {
        const res = @as(i64, lhs) * @as(i64, rhs);
        return @truncate(res);
    }
    pub fn MULH(_: *Emulator, lhs: i32, rhs: i32) ExecError!i32 {
        const res: i64 = @as(i64, lhs) * @as(i64, rhs);
        const res_trunc: i32 = @intCast(res >> 32);
        return res_trunc;
    }
    pub fn MULHU(_: *Emulator, lhs: u32, rhs: u32) ExecError!u32 {
        const res: u64 = @as(u64, lhs) * @as(u64, rhs);
        const res_trunc: u32 = @intCast(res >> 32);
        return res_trunc;
    }
    pub fn DIVU(_: *Emulator, lhs: u32, rhs: u32) ExecError!u32 {
        // https://five-embeddev.com/riscv-user-isa-manual/Priv-v1.12/m.html#division-operations
        if (rhs == 0) return std.math.maxInt(u32);

        return @divTrunc(lhs, rhs);
    }
    pub fn REMU(_: *Emulator, lhs: u32, rhs: u32) ExecError!u32 {
        // https://five-embeddev.com/riscv-user-isa-manual/Priv-v1.12/m.html#division-operations
        if (rhs == 0) @panic("TODO check link above");
        return @rem(lhs, rhs);
    }
};
const j_type_instrs = struct {
    pub fn JAL(emu: *Emulator, imm: i21) ExecError!u32 {
        // The jump and link (JAL) instruction uses the J-type format, where the
        // J-immediate encodes a signed offset in multiples of 2 bytes. The offset
        // is sign-extended and added to the address of the jump instruction to
        // form the jump target address. Jumps can therefore target a ±1 MiB
        // range. JAL stores the address of the instruction following the jump
        // ('pc'+4) into register rd. The standard software calling convention uses
        // 'x1' as the return address register and 'x5' as an alternate link register.
        const ret_addr = emu.pc + 4;
        const target_addr: u32 = @intCast(@as(i33, emu.pc) + imm);
        if (target_addr & 0b1 != 0) return error.MisalignedJump;
        emu.pc = target_addr - 4; // we add 4 right after this runs
        return ret_addr;
    }
};
const b_type_instrs = struct {
    pub fn BEQ(emu: *Emulator, rs1: i32, rs2: i32, imm: i13) ExecError!void {
        try condBr(emu, cmp.eq, rs1, rs2, imm);
    }
    pub fn BNE(emu: *Emulator, rs1: i32, rs2: i32, imm: i13) ExecError!void {
        try condBr(emu, cmp.neq, rs1, rs2, imm);
    }
    pub fn BGE(emu: *Emulator, rs1: i32, rs2: i32, imm: i13) ExecError!void {
        try condBr(emu, cmp.geq, rs1, rs2, imm);
    }
    pub fn BGEU(emu: *Emulator, rs1: i32, rs2: i32, imm: i13) ExecError!void {
        try condBr(emu, cmp.geq_u, rs1, rs2, imm);
    }
    pub fn BLTU(emu: *Emulator, rs1: i32, rs2: i32, imm: i13) ExecError!void {
        try condBr(emu, cmp.lt_u, rs1, rs2, imm);
    }
    pub fn BLT(emu: *Emulator, rs1: i32, rs2: i32, imm: i13) ExecError!void {
        try condBr(emu, cmp.lt, rs1, rs2, imm);
    }
};
const none_type_instrs = struct {
    pub fn ECALL(_: *Emulator) ExecError!void {
        return error.Ecall;
    }
};

pub const ExecError = error{
    BadInstr,
    Ecall,

    UnalignedMemory,
    BadSize,
    MisalignedJump,
    MisalignedBranch,
    OutOfBoundsAccess,

    Ecall_BadArgs,
    Ecall_Exit,
};
const FmtReg = struct {
    bank: rvinstrs.RegBank,
    reg: u5,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) !void {
        switch (self.bank) {
            .int => try writer.print("x{d}", .{self.reg}),
            .float => try writer.print("f{d}", .{self.reg}),
            .double => try writer.print("d{d}", .{self.reg}),
        }
    }
};
const DecodeToFmt = struct {
    pub const RetTy = void;
    pub fn handle(_: DecodeToFmt, comptime instr_spec: rvinstrs.InstrSpec, instr: Instruction) RetTy {
        const instr_name = @tagName(instr_spec.name);
        if (instr_spec.banks == null and instr_spec.format != .None) {
            std.log.info("{s} : [missing banks]", .{instr_name});
            return;
        }
        switch (instr_spec.format) {
            .None => {
                std.log.info("{s}", .{instr_name});
            },
            .U => {
                std.log.info("{s} ->{} {d}", .{
                    instr_name,
                    FmtReg{ .bank = instr_spec.banks.?.rd.?, .reg = instr.U.rd },
                    instr.U.immediate(),
                });
            },
            .I => {
                std.log.info("{s} ->{} {} {d}", .{
                    instr_name,
                    FmtReg{ .bank = instr_spec.banks.?.rd.?, .reg = instr.I.rd },
                    FmtReg{ .bank = instr_spec.banks.?.rs1.?, .reg = instr.I.rs1 },
                    instr.I.imm_11_0,
                });
            },
            .IShift => {
                std.log.info("{s} ->{} {} {d}", .{
                    instr_name,
                    FmtReg{ .bank = instr_spec.banks.?.rd.?, .reg = instr.IShift.rd },
                    FmtReg{ .bank = instr_spec.banks.?.rs1.?, .reg = instr.IShift.rs1 },
                    instr.IShift.imm_4_0,
                });
            },
            .S => {
                std.log.info("{s} {} {d} {}", .{
                    instr_name,
                    FmtReg{ .bank = instr_spec.banks.?.rs1.?, .reg = instr.S.rs1 },
                    instr.S.immediate(),
                    FmtReg{ .bank = instr_spec.banks.?.rs2.?, .reg = instr.S.rs2 },
                });
            },
            .R => {
                std.log.info("{s} ->{} {} {}", .{
                    instr_name,
                    FmtReg{ .bank = instr_spec.banks.?.rd.?, .reg = instr.R.rd },
                    FmtReg{ .bank = instr_spec.banks.?.rs1.?, .reg = instr.R.rs1 },
                    FmtReg{ .bank = instr_spec.banks.?.rs2.?, .reg = instr.R.rs2 },
                });
            },
            .J => {
                std.log.info("{s} ->{} {d}", .{
                    instr_name,
                    FmtReg{ .bank = instr_spec.banks.?.rd.?, .reg = instr.J.rd },
                    instr.J.immediate(),
                });
            },
            .B => {
                std.log.info("{s} {} {} {d}", .{
                    instr_name,
                    FmtReg{ .bank = instr_spec.banks.?.rs1.?, .reg = instr.B.rs1 },
                    FmtReg{ .bank = instr_spec.banks.?.rs2.?, .reg = instr.B.rs2 },
                    instr.B.immediate(),
                });
            },
            else => @panic("TODO"),
        }
    }
    pub fn handleInvalid(_: DecodeToFmt, instr: Instruction) void {
        std.log.info("Invalid: {x}", .{@as(u32, @bitCast(instr))});
    }
};
const DecodeToCall = struct {
    emu: *Emulator,

    pub const RetTy = ExecError!void;
    pub fn handle(self: DecodeToCall, comptime instr_spec: rvinstrs.InstrSpec, instr: Instruction) RetTy {
        const emu = self.emu;

        const instr_name = instr_spec.name;
        emu.markUsedInstruction(@field(rvinstrs.InstrName, instr_spec.name));
        switch (instr_spec.format) {
            .None => {
                if (!@hasDecl(none_type_instrs, instr_name)) @panic("TODO none_type_instrs." ++ instr_name);

                try @field(none_type_instrs, instr_name)(emu);
            },
            .U => {
                if (!@hasDecl(u_type_instrs, instr_name)) @panic("TODO u_type_instrs." ++ instr_name);

                const imm = instr.U.immediate();
                const result = try @field(u_type_instrs, instr_name)(emu, imm);
                emu.writeReg(instr_spec.banks.?.rd.?, instr.U.rd, result);
            },
            .I => {
                if (!@hasDecl(i_type_instrs, instr_name)) @panic("TODO i_type_instrs." ++ instr_name);

                const lhs = emu.readReg(instr_spec.banks.?.rs1.?, instr.I.rs1);
                const imm = instr.I.imm_11_0;
                const result = try @field(i_type_instrs, instr_name)(emu, lhs, imm);
                emu.writeReg(instr_spec.banks.?.rd.?, instr.I.rd, result);
            },
            .IShift => {
                if (!@hasDecl(i_shift_type_instrs, instr_name)) @panic("TODO i_shift_type_instrs." ++ instr_name);

                const lhs = emu.readReg(instr_spec.banks.?.rs1.?, instr.IShift.rs1);
                const imm = instr.IShift.imm_4_0;
                const result = try @field(i_shift_type_instrs, instr_name)(emu, lhs, imm);
                emu.writeReg(instr_spec.banks.?.rd.?, instr.IShift.rd, result);
            },
            .S => {
                if (!@hasDecl(s_type_instrs, instr_name)) @panic("TODO s_type_instrs." ++ instr_name);

                const lhs = emu.readReg(instr_spec.banks.?.rs1.?, instr.S.rs1);
                const imm = instr.S.immediate();
                const rhs = emu.readReg(instr_spec.banks.?.rs2.?, instr.S.rs2);
                try @field(s_type_instrs, instr_name)(emu, lhs, imm, rhs);
            },
            .R => {
                if (!@hasDecl(r_type_instrs, instr_name)) @panic("TODO r_type_instrs." ++ instr_name);

                const lhs = emu.readReg(instr_spec.banks.?.rs1.?, instr.R.rs1);
                const rhs = emu.readReg(instr_spec.banks.?.rs2.?, instr.R.rs2);
                const result = try @field(r_type_instrs, instr_name)(emu, lhs, rhs);
                emu.writeReg(instr_spec.banks.?.rd.?, instr.R.rd, result);
            },
            .J => {
                if (!@hasDecl(j_type_instrs, instr_name)) @panic("TODO j_type_instrs." ++ instr_name);

                const imm = instr.J.immediate();
                const result = try @field(j_type_instrs, instr_name)(emu, imm);
                emu.writeReg(instr_spec.banks.?.rd.?, instr.J.rd, result);
            },
            .B => {
                if (!@hasDecl(b_type_instrs, instr_name)) @panic("TODO b_type_instrs." ++ instr_name);

                const rs1 = emu.readReg(instr_spec.banks.?.rs1.?, instr.B.rs1);
                const rs2 = emu.readReg(instr_spec.banks.?.rs2.?, instr.B.rs2);
                const imm = instr.B.immediate();
                try @field(b_type_instrs, instr_name)(emu, rs1, rs2, imm);
            },
            else => @panic("TODO"),
        }
    }
    pub fn handleInvalid(_: DecodeToCall, _: Instruction) RetTy {
        return error.BadInstr;
    }
};

const cmp = struct {
    fn eq(a: i32, b: i32) bool {
        return a == b;
    }
    fn neq(a: i32, b: i32) bool {
        return a != b;
    }
    fn geq(a: i32, b: i32) bool {
        return a >= b;
    }
    fn geq_u(a_in: i32, b_in: i32) bool {
        const a: u32 = @bitCast(a_in);
        const b: u32 = @bitCast(b_in);
        return a >= b;
    }
    fn lt_u(a_in: i32, b_in: i32) bool {
        const a: u32 = @bitCast(a_in);
        const b: u32 = @bitCast(b_in);
        return a < b;
    }
    fn lt(a: i32, b: i32) bool {
        return a < b;
    }
};

// zig's baseline implements:
//     .a,
//     .c,
//     .d,
//     .m,
// so that's what we need to implement
//     - multiply/divide
//     - atomic instructions (maybe we can remove this from the featureset list & skip, we're not multithreaded)
//     - f32
//     - f64

pub const Instruction = packed union {
    any: AnyType,
    R: RType,
    R4: R4Type,
    RAtomic: RAtomicType,
    I: IType,
    IShift: IShiftType,
    IFence: IFenceType,
    S: SType,
    B: BType,
    U: UType,
    J: JType,
};
const AnyType = packed struct(u32) {
    opcode: u7,
    unknown: u25,
};
const RType = packed struct(u32) {
    opcode: u7,
    rd: u5,
    funct3: u3,
    rs1: u5,
    rs2: u5,
    funct7: u7,
};
const R4Type = packed struct(u32) {
    opcode: u7,
    rd: u5,
    funct3: u3,
    rs1: u5,
    rs2: u5,
    funct2: u2,
    rs3: u5,
};
const RAtomicType = packed struct(u32) {
    opcode: u7,
    rd: u5,
    funct3: u3,
    rs1: u5,
    rs2: u5,
    aq: u1,
    rl: u1,
    funct7_sub5: u5,
};
const IType = packed struct(u32) {
    opcode: u7,
    rd: u5,
    funct3: u3,
    rs1: u5,
    imm_11_0: i12,
};
const IShiftType = packed struct(u32) {
    opcode: u7,
    rd: u5,
    funct3: u3,
    rs1: u5,
    imm_4_0: u5,
    funct7: u7,
};
const IFenceType = packed struct(u32) {
    opcode: u7,
    rd: u5,
    funct3: u3,
    rs1: u5,
    succ: u4,
    pred: u4,
    fm: u4,
};
const SType = packed struct(u32) {
    opcode: u7,
    imm_4_0: u5,
    funct3: u3,
    rs1: u5,
    rs2: u5,
    imm_11_5: i7,
    pub fn immediate(fmt: SType) i12 {
        return (@as(i12, fmt.imm_11_5) << 5) | fmt.imm_4_0;
    }
};
const BType = packed struct(u32) {
    opcode: u7,
    imm_11: u1,
    imm_4_1: u4,
    funct3: u3,
    rs1: u5,
    rs2: u5,
    imm_10_5: u6,
    imm_12: i1,
    // imm_0 is known to be 0 because this is for a two-byte aligned instr

    pub fn immediate(fmt: BType) i13 {
        const res: i13 = (@as(i13, fmt.imm_4_1) << 1) | (@as(i13, fmt.imm_10_5) << 5) | (@as(i13, fmt.imm_11) << 11) | (@as(i13, fmt.imm_12) << 12);
        return @bitCast(res);
    }
};
const UType = packed struct(u32) {
    opcode: u7,
    rd: u5,
    imm_31_12: i20,
    pub fn immediate(self: UType) i32 {
        return @as(i32, self.imm_31_12) << 12;
    }
};

const JType = packed struct(u32) {
    opcode: u7,
    rd: u5,
    // what the heck
    imm_19_12: u8,
    imm_11: u1,
    imm_10_1: u10,
    imm_20: i1,
    pub fn immediate(fmt: JType) i21 {
        return (0 //
            | (@as(i21, fmt.imm_10_1) << 1) //
            | (@as(i21, fmt.imm_11) << 11) //
            | (@as(i21, fmt.imm_19_12) << 12) //
            | (@as(i21, fmt.imm_20) << 20) //
        );
    }
};
