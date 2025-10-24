//! DO NOT USE IN ReleaseFast!
//! there will be many out of bounds accesses
//! TODO: audit loader.zig, rvemu.zig, ... to bounds check every slice.

const std = @import("std");
const rvemu = @import("rvemu");
pub const constants = @import("constants.zig");
const util = @import("anywhere").util;
const gpu = @import("gpu.zig");
const log = std.log.scoped(.emu);

pub const FrameInput = struct {
    time_ms: u64,
    buttons: struct {
        up: bool,
        left: bool,
        down: bool,
        right: bool,

        interact: bool,
        jump: bool,
        menu: bool,
    },
    // should there be a seperate mouse position for each layer?
    // should mouse position include subpixel?
    mouse: ?@Vector(2, i16),
};
pub const FrameOutput = struct {
    frame: *[constants.EMU_SCREEN_DATA_SIZE_U32 * constants.EMU_SCREEN_NLAYERS]u32,
    layer_offsets: ?*[constants.EMU_SCREEN_NLAYERS]@Vector(2, i8) = null,
    background_color: ?*u32,
};

pub const Program = struct {
    emu: rvemu.Emulator,
    state: enum { active, err },
    input: FrameInput,

    privilege: enum { launcher, game } = .game,

    // big stuff
    mem: *align(@alignOf(u128)) [constants.EMU_MEM_SIZE]u8,
    gpu: *gpu.GPU, // < this struct is huge for some reason, we should at least put it in a pointer

    print_buf: [128]u8 = undefined,
    print_buf_idx: usize = 0,

    time: ?struct {
        first_exec: u64,
        rendered_frames_count: u64,
    },

    pub fn loadFromFile(gpa: std.mem.Allocator, file: []const u8) !Program {
        // TODO: treat the file as a zip file once mach updates zig
        // (the new zig has std.zip while we only have std.tar)
        // (tar files don't have a single place where all the entries are listed, you have to
        //  iterate over the whole tar file to find an element you want. at least you can seek
        //  a bunch. also maybe that's completely fine. we can use tar files.)

        const mem_ptr = &(try gpa.alignedAlloc([constants.EMU_MEM_SIZE]u8, .of(u128), 1))[0];
        errdefer gpa.destroy(mem_ptr);
        for (mem_ptr) |*b| b.* = 0;

        const gpu_ptr = try gpa.create(gpu.GPU);
        errdefer gpa.destroy(gpu_ptr);
        gpu_ptr.* = .{};

        const disk_aligned_mut = try gpa.alignedAlloc(u8, .of(u128), file.len);
        defer gpa.free(disk_aligned_mut);
        @memcpy(disk_aligned_mut, file);

        var emu: rvemu.Emulator = .{ .memory = mem_ptr };
        try emu.loadElf(disk_aligned_mut);

        return .{
            .emu = emu,
            .state = .active,
            .mem = mem_ptr,
            .gpu = gpu_ptr,
            .input = undefined,
            .time = null,
        };
    }
    pub fn unload(self: *Program, alloc: std.mem.Allocator) void {
        alloc.destroy(self.mem);
        alloc.destroy(self.gpu);
    }
};

fn renderErrorScreen(output: FrameOutput, label: []const u8) void {
    for (output.frame) |*itm| itm.* = 0;
    if (output.layer_offsets) |lo| for (lo) |*itm| {
        itm.* = .{ 0, 0 };
    };
    if (output.background_color) |bc| bc.* = 0;
    _ = label;
}

// const stdout_writer = std.Io.getStdOut().writer();
// var stdout_buffer = std.Io.bufferedWriter(stdout_writer);
// defer stdout_buffer.flush() catch {};
// const stdout = stdout_buffer.writer();
pub const Syscalls = struct {
    fn print_append(program: *Program, arg_0: i32, arg_1: i32) !i32 {
        const str_ptr: u32 = @bitCast(arg_0);
        var str_len: u32 = @bitCast(arg_1);

        const buf_rem = program.print_buf[program.print_buf_idx..];
        if (str_len > buf_rem.len) str_len = @intCast(buf_rem.len);
        const buf_section = buf_rem[0..str_len];
        @memcpy(buf_section, program.emu.memory[str_ptr..][0..str_len]);
        program.print_buf_idx += str_len;

        return 0;
    }
    fn print_flush(program: *Program) !i32 {
        std.log.info("flush: `{s}`", .{program.print_buf[0..program.print_buf_idx]});
        program.print_buf_idx = 0;
        return 0;
    }
    fn exit(program: *Program, arg_0: i32) !i32 {
        _ = program;
        const exit_code = arg_0;
        std.log.info("exit {d}", .{arg_0});
        if (exit_code != 0) return error.BadExitCode;
        return error.Exited;
    }
    fn gpu_set_background_color(program: *Program, arg_0: i32) !i32 {
        program.gpu.background_color = @bitCast(arg_0);
        return 0;
    }
    fn gpu_draw_image(program: *Program, arg_0: i32, arg_1: i32) !i32 {
        // gpu draw image
        const cmd_ptr: u32 = @bitCast(arg_0);
        const img_ptr: u32 = @bitCast(arg_1);

        const cmd_data = try util.safePtrCast(constants.DrawImageCmd, program.mem[cmd_ptr..][0..@sizeOf(constants.DrawImageCmd)]);
        const img_data = std.mem.bytesAsSlice(u32, try util.safeAlignCastMut(.of(u32), program.mem[img_ptr..][0 .. cmd_data.src.stride * std.math.lossyCast(u32, cmd_data.src.size[1]) * @sizeOf(u32)]));

        if (cmd_data.dest.layer >= constants.EMU_SCREEN_NLAYERS) return error.BadLayer;
        if (program.gpu.image_count >= constants.EMU_GPU_MAX_IMAGES) return error.MaxImagesReached;
        program.gpu.image_count += 1;

        program.gpu.drawImage(cmd_data, img_data);
        return 0;
    }
    fn gpu_set_layer_offset(program: *Program, arg_0: i32, arg_1: i32, arg_2: i32) !i32 {
        const lo_layer: u32 = @bitCast(arg_0);
        const lo_x: i32 = arg_1;
        const lo_y: i32 = arg_2;
        if (lo_layer >= constants.EMU_SCREEN_NLAYERS) return error.BadLayer;
        program.gpu.setLayerOffset(lo_layer, @truncate(lo_x), @truncate(lo_y));

        return 0;
    }
    fn get_buttons(program: *Program) !i32 {
        // get input
        var res: u32 = 0;
        if (program.input.buttons.up) res |= constants.BUTTON_UP;
        if (program.input.buttons.right) res |= constants.BUTTON_RIGHT;
        if (program.input.buttons.down) res |= constants.BUTTON_DOWN;
        if (program.input.buttons.left) res |= constants.BUTTON_LEFT;
        if (program.input.buttons.interact) res |= constants.BUTTON_INTERACT;
        if (program.input.buttons.jump) res |= constants.BUTTON_JUMP;
        if (program.input.buttons.menu) res |= constants.BUTTON_MENU;
        return @bitCast(res);
    }
    fn get_mouse(program: *Program) !i32 {
        // get input
        if (program.input.mouse) |mouse| {
            return @bitCast(mouse);
        } else {
            return @bitCast(@Vector(2, i16){ std.math.minInt(i16), std.math.minInt(i16) });
        }
    }
};

pub const Emu = struct {
    program: ?Program,
    frame_count: usize = 0,

    pub fn init() Emu {
        return .{
            .program = null,
        };
    }
    pub fn deinit(self: *Emu) void {
        if (self.program != null) @panic("must unload all programs before deinnit()");
    }

    pub fn unloadProgram(self: *Emu, gpa: std.mem.Allocator) void {
        const program = &self.program;
        if (program.* == null) @panic("program unloaded twice");
        program.*.?.unload(gpa);
        program.* = null;
    }
    pub fn loadProgram(self: *Emu, gpa: std.mem.Allocator, disk_unaligned: []const u8) !void {
        if (self.program != null) return error.NoFreeProgramSlots;

        self.program = try Program.loadFromFile(gpa, disk_unaligned);
    }

    /// simulate the frame & write it to output.rendered_buffer
    pub fn simulate(self: *Emu, input: FrameInput, output: FrameOutput) void {
        if (self.program == null) {
            return renderErrorScreen(output, "No program");
        }
        const active_program = &self.program.?;

        if (active_program.state == .err) {
            return renderErrorScreen(output, "Program errored");
        }
        active_program.input = input;
        runFrame(active_program) catch |e| switch (e) {
            error.TookTooLong => {
                // TODO: fade the screen out over 500ms
                // and then display a loading bar
                return renderErrorScreen(output, "Took too long");
            },
            else => {
                std.log.err("frame run error! {s}", .{@errorName(e)});
                active_program.state = .err;
                return renderErrorScreen(output, "Program errored; TODO write error");
            },
        };
        const SU32 = constants.EMU_SCREEN_DATA_SIZE_U32;
        @memcpy(output.frame[SU32 * 0 ..][0..SU32], &active_program.gpu.layers[0].image);
        @memcpy(output.frame[SU32 * 1 ..][0..SU32], &active_program.gpu.layers[1].image);
        @memcpy(output.frame[SU32 * 2 ..][0..SU32], &active_program.gpu.layers[2].image);
        @memcpy(output.frame[SU32 * 3 ..][0..SU32], &active_program.gpu.layers[3].image);
        if (output.layer_offsets) |layer_offsets| {
            for (layer_offsets, 0..) |*layer_offset, i| {
                layer_offset.* = active_program.gpu.layers[i].offset;
            }
        }
        if (output.background_color) |bgc| {
            bgc.* = active_program.gpu.background_color;
        }
    }

    fn runFrame(program: *Program) !void {
        if (program.time == null) {
            program.time = .{
                .first_exec = program.input.time_ms,
                .rendered_frames_count = 0,
            };
        }
        const time = &program.time.?;
        if (time.first_exec > program.input.time_ms) {
            time.* = .{
                .first_exec = program.input.time_ms,
                .rendered_frames_count = 0,
            };
        }

        // 1. determine the expected number of rendered frames (plus one for the first frame)
        const time_running = program.input.time_ms - time.first_exec;
        const expected_rendered_frames = (time_running * 60 / 1000) + 1;
        // 2.
        //   - if t

        var actual_rendered_frames = time.rendered_frames_count;

        if (actual_rendered_frames > expected_rendered_frames) {
            // uh oh!
            actual_rendered_frames = expected_rendered_frames - 1;
            time.* = .{
                .first_exec = program.input.time_ms,
                .rendered_frames_count = 0,
            };
        }

        var diff = expected_rendered_frames - actual_rendered_frames;

        if (diff > 3) {
            // we can't keep up! or maybe runFrame hasn't been called in a little while
            // because the game is paused
            // TODO: consider averaging all the frames rendered in one frame
            //           so that 30fps people can still see one-frame effects
            diff = 1;
            time.* = .{
                .first_exec = program.input.time_ms,
                .rendered_frames_count = 0,
            };
        }

        for (0..@intCast(diff)) |_| {
            program.gpu.clear();
            try _actuallyRunFrame(program);
            time.rendered_frames_count += 1;
        }
    }
    fn _actuallyRunFrame(program: *Program) !void {
        const emu = &program.emu;

        var i: usize = 0;
        while (i < constants.EMU_INSTRUCTIONS_PER_FRAME) : (i += 1) {
            emu.step() catch |e| switch (e) {
                error.Ecall => {
                    const syscall_tag: u32 = @bitCast(emu.readIntReg(17));
                    const syscall_args = [_]i32{
                        emu.readIntReg(10),
                        emu.readIntReg(11),
                        emu.readIntReg(12),
                        emu.readIntReg(13),
                        emu.readIntReg(14),
                        emu.readIntReg(15),
                    };

                    switch (@as(constants.SYS, @enumFromInt(syscall_tag))) {
                        .wait_for_next_frame => {
                            // end frame
                            // const duration = timer.read();
                            const i_f: f64 = @floatFromInt(i);
                            const max_f: f64 = @floatFromInt(constants.EMU_INSTRUCTIONS_PER_FRAME);
                            log.info("Frame executed in {d} / {d} instrs ({d:.2}%)", .{ i, constants.EMU_INSTRUCTIONS_PER_FRAME, i_f / max_f * 100.0 });
                            emu.writeIntReg(10, 0);
                            emu.pc += 4;
                            return;
                        },
                        .print_append => {
                            const res = try Syscalls.print_append(program, syscall_args[0], syscall_args[1]);
                            emu.writeIntReg(10, res);
                            emu.pc += 4;
                        },
                        .exit => {
                            const res = try Syscalls.exit(program, syscall_args[0]);
                            emu.writeIntReg(10, res);
                            emu.pc += 4;
                        },
                        .print_flush => {
                            const res = try Syscalls.print_flush(program);
                            emu.writeIntReg(10, res);
                            emu.pc += 4;
                        },
                        .gpu_set_background_color => {
                            const res = try Syscalls.gpu_set_background_color(program, syscall_args[0]);
                            emu.writeIntReg(10, res);
                            emu.pc += 4;
                        },
                        .gpu_draw_image => {
                            const res = try Syscalls.gpu_draw_image(program, syscall_args[0], syscall_args[1]);
                            emu.writeIntReg(10, res);
                            emu.pc += 4;
                        },
                        .gpu_set_layer_offset => {
                            const res = try Syscalls.gpu_set_layer_offset(program, syscall_args[0], syscall_args[1], syscall_args[2]);
                            emu.writeIntReg(10, res);
                            emu.pc += 4;
                        },
                        .get_buttons => {
                            const res = try Syscalls.get_buttons(program);
                            emu.writeIntReg(10, res);
                            emu.pc += 4;
                        },
                        .get_mouse => {
                            const res = try Syscalls.get_mouse(program);
                            emu.writeIntReg(10, res);
                            emu.pc += 4;
                        },
                        else => {
                            log.err("TODO syscall: {d}", .{syscall_tag});
                            return error.BadSyscall;
                        },
                    }
                },
                else => return e,
            };
        }
        return error.TookTooLong;
    }
};

pub fn main() !void {
    var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa_alloc.deinit() == .leak) @panic("memory leak");
    const gpa = gpa_alloc.allocator();

    const file_unaligned = try std.fs.cwd().readFileAlloc(gpa, "zig-out/bin/ex0", std.math.maxInt(usize));
    defer gpa.free(file_unaligned);

    var emu = Emu.init();
    defer emu.deinit();

    const program_id = try emu.loadProgram(gpa, file_unaligned);
    defer emu.unloadProgram(gpa, program_id);

    var frame_out = std.mem.zeroes([constants.EMU_SCREEN_DATA_SIZE_U32 * constants.EMU_SCREEN_NLAYERS]u32);
    for (0..3) |_| {
        emu.simulate(.{
            .time_ms = 437908,
            .dpad = .{
                .up = false,
                .left = false,
                .down = false,
                .right = false,
            },
            .mouse_held = null,
        }, .{
            .frame = &frame_out,
        });
    }
}

//
// StaticFns, used when statically linking in native game code
//

pub const StaticFns = struct {
    extern fn minigamer_frame() void;
    export fn minigamer_syscall0(number: constants.SYS) usize {
        _ = number;
        @panic("TODO syscall0");
    }
    export fn minigamer_syscall1(number: constants.SYS, arg1: usize) usize {
        _ = number;
        _ = arg1;
        @panic("TODO syscall0");
    }
    export fn minigamer_syscall2(number: constants.SYS, arg1: usize, arg2: usize) usize {
        _ = number;
        _ = arg1;
        _ = arg2;
        @panic("TODO syscall0");
    }
    export fn minigamer_syscall3(number: constants.SYS, arg1: usize, arg2: usize, arg3: usize) usize {
        _ = number;
        _ = arg1;
        _ = arg2;
        _ = arg3;
        _ = number;
        @panic("TODO syscall0");
    }
    export fn minigamer_syscall4(number: constants.SYS, arg1: usize, arg2: usize, arg3: usize, arg4: usize) usize {
        _ = number;
        _ = arg1;
        _ = arg2;
        _ = arg3;
        _ = arg4;
        _ = number;
        @panic("TODO syscall0");
    }
    export fn minigamer_syscall5(number: constants.SYS, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) usize {
        _ = number;
        _ = arg1;
        _ = arg2;
        _ = arg3;
        _ = arg4;
        _ = arg5;
        _ = number;
        @panic("TODO syscall0");
    }
    export fn minigamer_syscall6(number: constants.SYS, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize, arg6: usize) usize {
        _ = number;
        _ = arg1;
        _ = arg2;
        _ = arg3;
        _ = arg4;
        _ = arg5;
        _ = arg6;
        _ = number;
        @panic("TODO syscall0");
    }

    threadlocal var _frame_static_ptr: ?*Program = undefined;
    fn runFrameStatic(program: *Program) !void {
        // oops can't be multithreaded
        std.debug.assert(_frame_static_ptr == null);
        _frame_static_ptr = program;
        defer _frame_static_ptr = null;

        minigamer_frame();
    }
};
