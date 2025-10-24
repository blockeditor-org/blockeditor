const std = @import("std");

pub fn forceRuntime(val: f32) f32 {
    const ptr: *const volatile f32 = &val;
    return ptr.*;
}

pub const Sys = struct {
    pub const print = 3;
    pub const exit = 1;
};
var panic_stage: usize = 0;
const panic_header = "[PANIC]";
const panicked_during_a_painc = "Panicked during a panic";
pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    panic_stage += 1;
    switch (panic_stage) {
        1 => {}, // regular
        2 => {
            _ = syscall2(Sys.print, @intFromPtr(panicked_during_a_painc), panicked_during_a_painc.len);
            _ = syscall1(Sys.exit, 1);
        },
        else => {
            @trap();
        },
    }
    _ = syscall2(Sys.print, @intFromPtr(panic_header.ptr), panic_header.len);
    _ = syscall2(Sys.print, @intFromPtr(msg.ptr), msg.len);
    _ = syscall1(Sys.exit, 1);
    unreachable;
}

pub fn syscall0(number: usize) usize {
    return asm volatile ("ecall"
        : [ret] "={x10}" (-> usize),
        : [number] "{x17}" (number),
        : .{ .memory = true });
}

pub fn syscall1(number: usize, arg1: usize) usize {
    return asm volatile ("ecall"
        : [ret] "={x10}" (-> usize),
        : [number] "{x17}" (number),
          [arg1] "{x10}" (arg1),
        : .{ .memory = true });
}

pub fn syscall2(number: usize, arg1: usize, arg2: usize) usize {
    return asm volatile ("ecall"
        : [ret] "={x10}" (-> usize),
        : [number] "{x17}" (number),
          [arg1] "{x10}" (arg1),
          [arg2] "{x11}" (arg2),
        : .{ .memory = true });
}

pub fn syscall3(number: usize, arg1: usize, arg2: usize, arg3: usize) usize {
    return asm volatile ("ecall"
        : [ret] "={x10}" (-> usize),
        : [number] "{x17}" (number),
          [arg1] "{x10}" (arg1),
          [arg2] "{x11}" (arg2),
          [arg3] "{x12}" (arg3),
        : .{ .memory = true });
}

pub fn syscall4(number: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize) usize {
    return asm volatile ("ecall"
        : [ret] "={x10}" (-> usize),
        : [number] "{x17}" (number),
          [arg1] "{x10}" (arg1),
          [arg2] "{x11}" (arg2),
          [arg3] "{x12}" (arg3),
          [arg4] "{x13}" (arg4),
        : .{ .memory = true });
}

pub fn syscall5(number: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) usize {
    return asm volatile ("ecall"
        : [ret] "={x10}" (-> usize),
        : [number] "{x17}" (number),
          [arg1] "{x10}" (arg1),
          [arg2] "{x11}" (arg2),
          [arg3] "{x12}" (arg3),
          [arg4] "{x13}" (arg4),
          [arg5] "{x14}" (arg5),
        : .{ .memory = true });
}

pub fn syscall6(number: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize, arg6: usize) usize {
    return asm volatile ("ecall"
        : [ret] "={x10}" (-> usize),
        : [number] "{x17}" (number),
          [arg1] "{x10}" (arg1),
          [arg2] "{x11}" (arg2),
          [arg3] "{x12}" (arg3),
          [arg4] "{x13}" (arg4),
          [arg5] "{x14}" (arg5),
          [arg6] "{x15}" (arg6),
        : .{ .memory = true });
}
