const std = @import("std");

fn killProc(proc: *std.process.Child) void {
    _ = proc.kill() catch |e| {
        std.log.err("process kill error: {s}", .{@errorName(e)});
    };
}
pub fn main() !u8 {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();

    const gpa = gpa_state.allocator();

    const baseargs = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, baseargs);

    var proc_list: std.array_list.Managed(std.process.Child) = .init(gpa);
    defer proc_list.deinit();
    defer for (proc_list.items) |*proc| killProc(proc);

    if (baseargs.len < 2) return error.BadArgs;
    const splitseq = baseargs[1];

    const mainargs = baseargs[2..];

    var seg_start: usize = 0;
    for (0..mainargs.len + 1) |i| {
        const arg = if (i >= mainargs.len) splitseq else mainargs[i];
        if (std.mem.eql(u8, splitseq, arg)) {
            // commit
            const child_args = mainargs[seg_start..i];
            if (child_args.len > 0) {
                var proc = std.process.Child.init(child_args, gpa);

                try proc.spawn();
                errdefer killProc(&proc);

                try proc_list.append(proc);
            }

            seg_start = i + 1;
        } else {
            // append
        }
    }

    var fail = false;
    for (proc_list.items) |*proc| {
        const term = proc.wait() catch |e| {
            std.log.err("process wait error: {s}", .{@errorName(e)});
            continue;
        };
        if (term != .Exited or term.Exited != 0) fail = true;
    }
    proc_list.clearRetainingCapacity();
    return if (fail) 1 else 0;
}
