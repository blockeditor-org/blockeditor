const anywhere = @import("anywhere");
const std = @import("std");
const snapshot = anywhere.util.testing.snapshot;

pub fn main() !u8 {
    var gpa_backing = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa_backing.deinit() == .ok);
    const gpa = gpa_backing.allocator();

    var arena_backing = std.heap.ArenaAllocator.init(gpa);
    defer arena_backing.deinit();
    const arena = arena_backing.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var module_name_map = std.StringArrayHashMapUnmanaged(?[]const u8).empty;
    defer module_name_map.deinit(gpa);
    var first_arg: usize = 0;
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "-M")) {
            const full = arg["-M".len..];
            const eql = std.mem.indexOfScalar(u8, full, '=') orelse std.debug.panic("bad arg: {s}", .{full});
            const before, const after = .{ full[0..eql], full[eql + 1 ..] };
            if (try module_name_map.fetchPut(gpa, before, std.fs.path.dirname(after))) |prev_val| {
                std.debug.panic("duplicate arg: {s}, previous value={s}", .{ full, prev_val.value orelse "/" });
            }
        } else {
            break;
        }
        first_arg += 1;
    }

    module_name_map.lockPointers();
    defer module_name_map.unlockPointers();

    const result = blk: {
        var env_map = try std.process.getEnvMap(gpa);
        defer env_map.deinit();

        // create pipe

        var cproc = std.process.Child.init(args[1 + first_arg ..], gpa);

        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();

        {
            const tmp_file = try tmp_dir.dir.createFile("snapshot", .{});
            defer tmp_file.close();
        }

        const snapshot_path = try tmp_dir.dir.realpathAlloc(gpa, "snapshot");
        defer gpa.free(snapshot_path);

        try env_map.put("ANYWHERE_SNAPSHOT_UPDATE", snapshot_path);
        cproc.env_map = &env_map;

        const term = try cproc.spawnAndWait();

        const result = try tmp_dir.dir.readFileAlloc(gpa, "snapshot", std.math.maxInt(usize));
        errdefer gpa.free(result);

        switch (term) {
            .Exited => |code| {
                if (code != 0) return code;
            },
            else => {
                std.log.err("child exited with code {any}", .{term});
                return 1;
            },
        }
        break :blk result;
    };
    defer gpa.free(result);

    if (result.len == 0) return 0; // no snapshots to update; skip
    std.log.info("got snapshot data: {s}", .{result});

    var iter = std.mem.splitScalar(u8, result, '\n');
    // we need to convert this to:
    // - map( [module,file] => [line, column, actual, expected] )

    const Key = struct {
        module: usize,
        file: []const u8,
    };
    const StringContext = struct {
        pub fn hash(_: @This(), s: Key) u32 {
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(&std.mem.toBytes(s.module));
            hasher.update(s.file);
            return @as(u32, @truncate(hasher.final()));
        }
        pub fn eql(_: @This(), a: Key, b: Key, _: usize) bool {
            return a.module == b.module and std.mem.eql(u8, a.file, b.file);
        }
    };

    var result_map = std.ArrayHashMapUnmanaged(Key, std.ArrayListUnmanaged(snapshot.SnapshotMessage), StringContext, true).empty;
    defer result_map.deinit(gpa);
    defer for (result_map.values()) |*value| {
        value.deinit(gpa);
    };
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        const dec: std.json.Parsed(snapshot.SnapshotMessage) = try std.json.parseFromSlice(snapshot.SnapshotMessage, arena, line, .{ .allocate = .alloc_if_needed });
        // no need to free, it is in the arena
        const module_index = module_name_map.getIndex(dec.value.src.module) orelse std.debug.panic("missing definition for module {s}", .{dec.value.src.module});
        const gpres = try result_map.getOrPut(gpa, .{ .module = module_index, .file = dec.value.src.file });
        if (!gpres.found_existing) {
            gpres.value_ptr.* = .empty;
        }
        try gpres.value_ptr.append(gpa, dec.value);
    }

    // now we loop over each module and update the file
    var has_error: std.atomic.Value(bool) = .init(false);
    {
        var pool: std.Thread.Pool = undefined;
        try pool.init(.{ .allocator = gpa });
        defer pool.deinit();
        for (result_map.keys(), result_map.values()) |k, v| {
            try pool.spawn(updateOneFile, .{ gpa, module_name_map.values()[k.module], k.file, v.items, &has_error });
        }
    }
    if (has_error.raw) return 1;

    std.log.info("snapshot update success", .{});

    return 0;
}

fn updateOneFile(gpa: std.mem.Allocator, module_path: ?[]const u8, file_path: []const u8, messages: []snapshot.SnapshotMessage, has_error: *std.atomic.Value(bool)) void {
    return updateOneFileInternal(gpa, module_path, file_path, messages) catch |e| {
        switch (e) {
            error.Posted => {},
            else => |err| {
                std.log.err("{s}/{s}: error applying snapshots: {s}", .{ module_path orelse "", file_path, @errorName(err) });
            },
        }
        has_error.store(true, .unordered);
    };
}
fn updateOneFileInternal(gpa: std.mem.Allocator, module_path: ?[]const u8, file_path: []const u8, messages: []snapshot.SnapshotMessage) !void {
    //     - sort so the earliest line & column numbers are first
    //     - error if the same line number appears multiple times (we can allow it if all the values are the same)
    //     - now we will re-output the whole file into an arraylist, replacing as needed. and we will validate.

    const whole_path = try std.fs.path.join(gpa, &.{ module_path orelse "", file_path });
    defer gpa.free(whole_path);

    var src_file = try std.fs.cwd().openFile(whole_path, .{});
    defer src_file.close();
    var reader_buf: [1024]u8 = undefined;
    var src_file_reader = src_file.reader(&reader_buf);

    var atomic_file_buffer: [1024]u8 = undefined;
    var dst_file = try std.fs.cwd().atomicFile(whole_path, .{ .write_buffer = &atomic_file_buffer });
    defer dst_file.deinit();

    var fout = std.Io.Writer.Allocating.init(gpa);
    defer fout.deinit();

    var eater: snapshot.Eater = .{
        .reader = &src_file_reader.interface,
        .writer = &dst_file.file_writer.interface,
        .filepath = whole_path,
        .error_mode = .log,
    };
    try snapshot.performReplacements(gpa, messages, &eater);

    try dst_file.finish();

    std.log.info("updated {d} snapshots in {s}", .{ messages.len, file_path });
}
