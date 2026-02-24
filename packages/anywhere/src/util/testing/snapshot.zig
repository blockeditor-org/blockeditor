const anywhere = @import("../../root.zig");
const std = @import("std");

// consider changing how snapshots are implemented:
// Snapshot.init()
// defer Snapshot.deinit()
// Snapshot.writer.print()
// Snapshot.expect();
// also I thought -u was implemented but I guess not

var mutex = std.Thread.Mutex{};
var _initialized: std.atomic.Value(bool) = .init(false);
var _should_update: bool = undefined;
// TODO: actual must be moved before src. so snap(actual, @src(), null);
pub fn snap(src: std.builtin.SourceLocation, actual: []const u8, expected: ?[]const u8) !void {
    if (!_initialized.load(.acquire)) {
        mutex.lock();
        defer mutex.unlock();

        // inside mutex so it's ok to view .raw
        if (_initialized.raw == false) blk: {
            const env_val = std.process.getEnvVarOwned(std.testing.allocator, "ZIG_UPDATE_SNAPSHOT") catch {
                _should_update = false;
                break :blk;
            };
            defer std.testing.allocator.free(env_val);
            _should_update = true;
        }
        _initialized.raw = true;
    }
    if (_should_update and (expected == null or !std.mem.eql(u8, expected.?, actual))) {
        mutex.lock();
        defer mutex.unlock();

        // needs update!
        std.log.err("needs update:\n  module: \"{f}\"\n  file: \"{f}\"\n  pos: {d}:{d}", .{ std.zig.fmtString(src.module), std.zig.fmtString(src.file), src.line, src.column });

        return;
    }
    try std.testing.expectEqualStrings(expected orelse "(needs update)", actual);

    // TODO:
    // - the env var will contain a file
    // - we will append serialized update information to the file:
    //   - what module, what file, what pos, what was the old value, what is the new value
    // - an 'update snapshot' script will read this file and:
    //   - for each file:
    //     - convert all lyn:col to byte offset
    //     - sort so the highest byte offsets are first
    //     - deduplicate any values with the same byte offset
    //       - if they are not identical, remove them entirely & error
    //     - at the source location, validate that the expected string appears:
    //       "@src(),\n", then count whitespace, then expect "\\\\"
    //     - parse the existing string. if it is not equal to the old value, error
    //     - replace it with the new string.
    // - (alternatively) we can have the update happen in the snap mutex:
    //   - will have to write every time anything changes
    //   - we keep a cache of what the original was here, then for every update we generate out the new
    //     and write it
}
