const anywhere = @import("../../root.zig");
const std = @import("std");

// consider changing how snapshots are implemented:
// Snapshot.init()
// defer Snapshot.deinit()
// Snapshot.writer.print()
// Snapshot.expect();
// also I thought -u was implemented but I guess not

const State = struct {
    var mutex = std.Thread.Mutex{};
    var _initialized: std.atomic.Value(bool) = .init(false);
    var _update_writer: ?*std.Io.Writer = undefined;
    fn initialize() void {
        if (_initialized.load(.acquire)) return; // initialized already

        mutex.lock();
        defer mutex.unlock();
        if (_initialized.raw) return; // initialized already
        defer _initialized.raw = true;
        initializeInternal() catch |e| {
            std.debug.panic("failed to set up snapshot: {s}", .{@errorName(e)});
        };
    }
    fn initializeInternal() !void {
        _update_writer = null;

        const env_val = std.process.getEnvVarOwned(std.testing.allocator, "ANYWHERE_SNAPSHOT_UPDATE") catch {
            return;
        };
        defer std.testing.allocator.free(env_val);

        const file = try std.heap.smp_allocator.create(std.fs.File);
        file.* = try std.fs.cwd().openFile(env_val, .{ .mode = .write_only });
        const buffer = try std.heap.smp_allocator.alloc(u8, 2048);
        const writer = try std.heap.smp_allocator.create(std.fs.File.Writer);
        writer.* = file.writer(buffer);
        _update_writer = &writer.interface;
    }

    fn shouldUpdate() bool {
        initialize();
        return _update_writer != null;
    }
    fn post(msg: SnapshotMessage) void {
        initialize();
        mutex.lock();
        defer mutex.unlock();
        _update_writer.?.print("{f}\n", .{std.json.fmt(msg, .{})}) catch @panic("failed to write snapshot update");
        _update_writer.?.flush() catch @panic("failed to write snapshot update");
    }
};

pub const SnapshotMessage = struct {
    src: std.builtin.SourceLocation,
    actual: []const u8,
    expected: ?[]const u8,
};

// TODO: actual must be moved before src. so snap(actual, @src(), null);
pub fn snap(src: std.builtin.SourceLocation, actual: []const u8, expected: ?[]const u8) !void {
    if (State.shouldUpdate() and (expected == null or !std.mem.eql(u8, expected.?, actual))) {
        State.post(.{
            .src = src,
            .actual = actual,
            .expected = expected,
        });
        return;
    }
    std.testing.expectEqualStrings(expected orelse "(needs update)", actual) catch |e| {
        std.log.err("Use -Dupdate_snapshots to update snapshots", .{});
        return e;
    };
}

test snap {
    try snap(@src(), "hello", null);
}
