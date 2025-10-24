//! syscalls impl for `.cart` files using `ecall`

pub const constants = @import("constants");

pub fn syscall0(number: constants.SYS) usize {
    return asm volatile ("ecall"
        : [ret] "={x10}" (-> usize),
        : [number] "{x17}" (@intFromEnum(number)),
        : .{ .memory = true });
}

pub fn syscall1(number: constants.SYS, arg1: usize) usize {
    return asm volatile ("ecall"
        : [ret] "={x10}" (-> usize),
        : [number] "{x17}" (@intFromEnum(number)),
          [arg1] "{x10}" (arg1),
        : .{ .memory = true });
}

pub fn syscall2(number: constants.SYS, arg1: usize, arg2: usize) usize {
    return asm volatile ("ecall"
        : [ret] "={x10}" (-> usize),
        : [number] "{x17}" (@intFromEnum(number)),
          [arg1] "{x10}" (arg1),
          [arg2] "{x11}" (arg2),
        : .{ .memory = true });
}

pub fn syscall3(number: constants.SYS, arg1: usize, arg2: usize, arg3: usize) usize {
    return asm volatile ("ecall"
        : [ret] "={x10}" (-> usize),
        : [number] "{x17}" (@intFromEnum(number)),
          [arg1] "{x10}" (arg1),
          [arg2] "{x11}" (arg2),
          [arg3] "{x12}" (arg3),
        : .{ .memory = true });
}

pub fn syscall4(number: constants.SYS, arg1: usize, arg2: usize, arg3: usize, arg4: usize) usize {
    return asm volatile ("ecall"
        : [ret] "={x10}" (-> usize),
        : [number] "{x17}" (@intFromEnum(number)),
          [arg1] "{x10}" (arg1),
          [arg2] "{x11}" (arg2),
          [arg3] "{x12}" (arg3),
          [arg4] "{x13}" (arg4),
        : .{ .memory = true });
}

pub fn syscall5(number: constants.SYS, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) usize {
    return asm volatile ("ecall"
        : [ret] "={x10}" (-> usize),
        : [number] "{x17}" (@intFromEnum(number)),
          [arg1] "{x10}" (arg1),
          [arg2] "{x11}" (arg2),
          [arg3] "{x12}" (arg3),
          [arg4] "{x13}" (arg4),
          [arg5] "{x14}" (arg5),
        : .{ .memory = true });
}

pub fn syscall6(number: constants.SYS, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize, arg6: usize) usize {
    return asm volatile ("ecall"
        : [ret] "={x10}" (-> usize),
        : [number] "{x17}" (@intFromEnum(number)),
          [arg1] "{x10}" (arg1),
          [arg2] "{x11}" (arg2),
          [arg3] "{x12}" (arg3),
          [arg4] "{x13}" (arg4),
          [arg5] "{x14}" (arg5),
          [arg6] "{x15}" (arg6),
        : .{ .memory = true });
}
