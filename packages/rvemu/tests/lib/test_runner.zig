const std = @import("std");
const rvemu = @import("rvemu");

pub fn main() !u8 {
    var gpa_backing = std.heap.GeneralPurposeAllocator(.{}).init;
    defer std.debug.assert(gpa_backing.deinit() == .ok);
    const gpa = gpa_backing.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var rem = args[1..];

    var update_snapshots = false;
    if (rem.len >= 1 and std.mem.eql(u8, rem[0], "-u")) {
        update_snapshots = true;
        rem = rem[1..];
    }
    if (rem.len < 1) return error.MissingArg;
    const hashes_file = rem[0];
    rem = rem[1..];

    const itms = @divFloor(rem.len, 2);
    var progress = std.Progress.start(.{ .root_name = "rv tests", .estimated_total_items = itms });
    defer progress.end();

    std.log.info("running tests", .{});
    for (rem) |itm| {
        std.log.info("  {s}", .{itm});
    }

    var success: bool = true;

    var hashes_file_cont = std.array_list.Managed([]const u8).init(gpa);
    defer hashes_file_cont.deinit();
    defer for (hashes_file_cont.items) |ent| gpa.free(ent);

    while (rem.len > 1) {
        const src = rem[0];
        const dst = rem[1];
        const name = std.fs.path.basename(src);
        rem = rem[2..];

        var node = progress.start(name, 0);
        defer node.end();

        const mem_ptr = try gpa.alignedAlloc(u8, @alignOf(u128), 2097152); // 2mb
        defer gpa.free(mem_ptr);
        for (mem_ptr) |*b| b.* = 0;

        const disk = try std.fs.cwd().readFileAllocOptions(gpa, src, 2097152, null, @alignOf(u128), null);
        defer gpa.free(disk);

        var disk_hasher = std.crypto.hash.sha2.Sha256.init(.{});
        disk_hasher.update(disk);
        const disk_hash = disk_hasher.finalResult();

        const snapshot = std.fs.cwd().readFileAlloc(gpa, dst, 2097152) catch "";
        defer gpa.free(snapshot); // if the file read failed, it won't free. so that's ok.

        var emu: rvemu.Emulator = .{ .memory = mem_ptr };
        try emu.loadElf(disk);

        var snapshot_result = std.array_list.Managed(u8).init(gpa);
        defer snapshot_result.deinit();

        // start emu-lating
        var env: Env = .{
            .emu = &emu,
            .snapshot_result = &snapshot_result,
            .exit_code = 1,
        };
        emu.run(&env, handleSyscall) catch |e| switch (e) {
            error.Ecall_Exit => {},
            else => return e,
        };

        // these should go in a seperate file because they will change with zig updates
        try snapshot_result.writer().print("Exited with code {d}\n", .{env.exit_code});

        {
            var apres = std.array_list.Managed(u8).init(gpa);
            defer apres.deinit();
            try apres.writer().print("{s}: {d}\n  {}\n  Features", .{ name, emu.cost, std.fmt.fmtSliceHexLower(&disk_hash) });
            for (0..std.meta.fields(rvemu.rvinstrs.InstrName).len) |i| {
                const field_flag: rvemu.rvinstrs.InstrName = @enumFromInt(i);
                if (env.emu.features.used_instructions.contains(field_flag)) {
                    try apres.writer().print(", {s}", .{@tagName(field_flag)});
                }
            }
            try apres.writer().print("\n", .{});
            try hashes_file_cont.append(try apres.toOwnedSlice());
        }

        if (!std.mem.eql(u8, snapshot_result.items, snapshot)) {
            std.log.err("{s}:\n=== EXPECTED ===\n{s}\n=== GOT ===\n{s}\n=== ===", .{ name, snapshot, snapshot_result.items });
            success = false;
            if (update_snapshots) {
                try std.fs.cwd().writeFile(.{ .sub_path = dst, .data = snapshot_result.items });
            }
        }
    }
    if (rem.len != 0) return error.BadArgs;

    std.mem.sort([]const u8, hashes_file_cont.items, {}, strLessThan);
    {
        var hashes_res = std.array_list.Managed(u8).init(gpa);
        defer hashes_res.deinit();
        try hashes_res.appendSlice("# Hashes file. Changes when zig updates or cost calculation changes.\n\n");
        for (hashes_file_cont.items) |itm| try hashes_res.appendSlice(itm);
        const prev_hashes_file = std.fs.cwd().readFileAlloc(gpa, hashes_file, 2097152) catch "";
        defer gpa.free(prev_hashes_file);
        if (!std.mem.eql(u8, prev_hashes_file, hashes_res.items)) {
            std.log.err("Hashes file changed.", .{});
            success = false;
            if (update_snapshots) {
                try std.fs.cwd().writeFile(.{ .sub_path = hashes_file, .data = hashes_res.items });
            }
        }
    }

    if (!success) {
        if (!update_snapshots) {
            std.log.info("use -u to update snapshots.", .{});
        } else {
            std.log.info("snapshots updated. re-run tests to confirm.", .{});
        }
        return 1;
    }
    return 0;
}
fn strLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}
const Env = struct {
    emu: *rvemu.Emulator,
    snapshot_result: *std.array_list.Managed(u8),
    exit_code: i32,
};
pub fn handleSyscall(env: *Env, kind: i32, args: [6]i32) !i32 {
    switch (kind) {
        1 => {
            env.exit_code = args[0];
            return error.Ecall_Exit;
        },
        3 => {
            const ptr: u32 = @bitCast(args[0]);
            const len: u32 = @bitCast(args[1]);
            try env.emu.addCost(len);
            try env.snapshot_result.appendSlice("[LOG] ");
            try env.snapshot_result.appendSlice(try env.emu.readSlice(ptr, len));
            try env.snapshot_result.appendSlice("\n");
            return 0;
        },
        else => @panic("bad ecall"),
    }
}

// test "fuzz"

// trace impl:
// - serialize program state
// - save every syscall
// - if the trace gets too long: serialize emu state & clear the trace.
//   keep saving syscalls after this.
