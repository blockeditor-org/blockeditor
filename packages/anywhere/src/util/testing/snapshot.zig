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

// we should decide if we want snap(@src(), target).match(value())
// vs value().snap(@src(), target)
// vs snap(@src(), target, actual)
pub const Snapshot = struct {
    gpa: ?std.mem.Allocator,
    actual: []const u8,
    pub fn static(str: []const u8) Snapshot {
        return .{ .gpa = null, .actual = str };
    }
    pub fn from(gpa: std.mem.Allocator, str: []const u8) Snapshot {
        return .{ .gpa = gpa, .actual = str };
    }
    pub fn deinit(self: *const Snapshot) void {
        if (self.gpa) |gpa| gpa.free(self.actual);
    }

    /// the snapshot string is deinit-ed
    pub fn snap(self: *const Snapshot, src: ?std.builtin.SourceLocation, expected: ?[]const u8) !void {
        defer self.deinit();

        if (src != null and State.shouldUpdate() and (expected == null or !std.mem.eql(u8, expected.?, self.actual))) {
            State.post(.{
                .src = src.?,
                .actual = self.actual,
                .expected = expected,
            });
            return;
        }
        std.testing.expectEqualStrings(expected orelse "(needs update)", self.actual) catch |e| {
            std.log.err("Use -Dupdate_snapshots to update snapshots", .{});
            return e;
        };
    }
};

test Snapshot {
    try Snapshot.static("hello").snap(@src(),
        \\hello
    );
}

pub fn performReplacements(gpa: std.mem.Allocator, messages: []SnapshotMessage, eater: *Eater) !void {
    std.mem.sort(SnapshotMessage, messages, {}, lessThanSnapshotMessage);
    for (messages, 0..) |message, i| {
        if (i > 0) {
            const prev_msg = &messages[i - 1];
            if (message.src.line == prev_msg.src.line) {
                try validateSameLineMessages(eater, &message, prev_msg);
                continue;
            }
        }

        try eater.advanceTo(message.src.line, message.src.column, .copy);
        try eater.consumeExact("@src(),", .copy);

        const indent: usize = eater.indent;
        var commit: []const u8 = "";
        defer gpa.free(commit);
        if (try eater.tryConsumeExact(" null", .skip)) {
            if (message.expected != null) {
                return eater.postError("{s}:{d}:{d}: found 'null', but the report expected to find \"{f}\"", .{ eater.filepath, eater.lyn, eater.col, std.zig.fmtString(message.expected.?) });
            }
        } else {
            var in_src = std.Io.Writer.Allocating.init(gpa);
            defer in_src.deinit();
            complete: while (true) {
                const line = try eater.consumeFullLine(gpa);
                defer gpa.free(line);
                if (line.len == 0) break; // len 0 = does not include '\n'
                var tkz = std.zig.Tokenizer.init(line);
                while (true) {
                    const tok = tkz.next();
                    // arguably we can consume whatever until the final r_paren. this is just for validation.
                    switch (tok.tag) {
                        .eof => break,
                        .multiline_string_literal_line => {
                            const content = line[tok.loc.start + 2 .. tok.loc.end];
                            if (in_src.written().len > 0) try in_src.writer.writeByte('\n');
                            try in_src.writer.writeAll(content);
                        },
                        .r_paren => {
                            // finished; commit the remainder of the line
                            commit = try gpa.dupe(u8, line[tok.loc.start..]);
                            break :complete;
                        },
                        else => {
                            return eater.postError("{s}:{d}:{d}: unexpected token: .{s}", .{ eater.filepath, eater.lyn, eater.col, @tagName(tok.tag) });
                        },
                    }
                }
            }
            if (message.expected == null or !std.mem.eql(u8, message.expected.?, in_src.written())) {
                return eater.postError("{s}:{d}:{d}: found \"{f}\", but the report expected to find \"{f}\"", .{ eater.filepath, eater.lyn, eater.col, std.zig.fmtString(in_src.written()), std.zig.fmtString(message.expected.?) });
            }
        }

        var split = std.mem.splitScalar(u8, message.actual, '\n');
        while (split.next()) |line| {
            // TODO: detect & escape nonprintable characters or something
            // which will complicate the consumer a bit. though if we were to use the zig tokenizer it wouldn't be much harder
            try eater.writer.writeByte('\n');
            try eater.writer.splatByteAll(' ', indent + 4);
            try eater.writer.writeAll("\\\\");
            try eater.writer.writeAll(line);
        }
        try eater.writer.writeByte('\n');
        try eater.writer.splatByteAll(' ', indent);
        try eater.writer.writeAll(commit);
    }

    // finish
    _ = try eater.reader.streamRemaining(eater.writer);
}
pub const Eater = struct {
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    lyn: u32 = 1,
    col: u32 = 1,
    indent: u32 = 0,
    indent_complete: bool = false,
    filepath: []const u8,
    error_mode: enum { log, write },

    fn advanceLynColWithByte(self: *Eater, byte: u8) void {
        switch (byte) {
            '\n' => {
                self.lyn += 1;
                self.col = 1;
                self.indent_complete = false;
                self.indent = 0;
            },
            ' ' => {
                if (!self.indent_complete) self.indent += 1;
                self.col += 1;
            },
            else => {
                self.col += 1;
                self.indent_complete = true;
            },
        }
    }
    pub fn advanceTo(self: *Eater, lyn: u32, col: u32, mode: WriteMode) !void {
        while (self.lyn < lyn or self.col < col) {
            const rem = try self.reader.peekGreedy(1);
            var i: usize = 0;
            for (rem) |byte| {
                if (self.lyn >= lyn and self.col >= col) break;
                self.advanceLynColWithByte(byte);
                i += 1;
            }

            try self.consumeN(i, mode);
        }
        if (self.lyn != lyn or self.col != col) {
            return self.postError("{s}:{d}:{d}: failed to advance to {d}:{d}", .{ self.filepath, self.lyn, self.col, lyn, col });
        }
    }
    pub fn consumeExact(self: *Eater, msg: []const u8, mode: WriteMode) !void {
        if (!try self.tryConsumeExact(msg, mode)) {
            return self.postError("{s}:{d}:{d}: expected exactly \"{f}\"", .{ self.filepath, self.lyn, self.col, std.zig.fmtString(msg) });
        }
    }
    pub fn tryConsumeExact(self: *Eater, msg: []const u8, mode: WriteMode) !bool {
        const rem = self.reader.peek(msg.len) catch |e| switch (e) {
            error.EndOfStream => return false,
            else => |e2| return e2,
        };
        if (!std.mem.eql(u8, rem, msg)) {
            return false;
        }
        for (rem) |char| self.advanceLynColWithByte(char);
        try self.consumeN(rem.len, mode);
        return true;
    }
    pub fn consumeFullLine(self: *Eater, gpa: std.mem.Allocator) ![:0]const u8 {
        var dst = std.Io.Writer.Allocating.init(gpa);
        _ = try self.reader.streamDelimiterEnding(&dst.writer, '\n');
        if (self.reader.peekByte() catch |e| switch (e) {
            error.EndOfStream => '\x00',
            else => |e2| return e2,
        } == '\n') try self.reader.streamExact(&dst.writer, 1);

        for (dst.written()) |byte| self.advanceLynColWithByte(byte);
        return try dst.toOwnedSliceSentinel(0);
    }

    const WriteMode = enum { copy, skip };
    fn consumeN(self: *Eater, n: usize, mode: WriteMode) !void {
        switch (mode) {
            .copy => try self.reader.streamExact(self.writer, n),
            .skip => self.reader.toss(n),
        }
    }

    pub fn postError(self: *Eater, comptime msg: []const u8, fmt: anytype) error{ Posted, WriteFailed } {
        switch (self.error_mode) {
            .log => std.log.err(msg, fmt),
            .write => {
                if (!@import("builtin").is_test) unreachable;
                try self.writer.writeAll("<-\n");
                try self.writer.writeAll("error: ");
                try self.writer.print(msg, fmt);
            },
        }
        return error.Posted;
    }
};

fn validateSameLineMessages(eater: *Eater, message: *const SnapshotMessage, prev_msg: *const SnapshotMessage) !void {
    if (message.src.column != prev_msg.src.column) {
        return eater.postError("{s}:{d}:{d}: multiple snapshots in the same line but on different columns (prev at {d}:{d})", .{
            eater.filepath,
            message.src.line,
            message.src.column,
            prev_msg.src.line,
            prev_msg.src.column,
        });
    }
    if (!std.mem.eql(u8, message.actual, prev_msg.actual)) {
        return eater.postError("{s}:{d}:{d}: multiple snapshots in the same position but different values for 'actual'.\nthis snapshot:\n====\n{s}\n====\n\nprev snapshot:\n====\n{s}\n====\n", .{
            eater.filepath,
            message.src.line,
            message.src.column,
            message.actual,
            prev_msg.actual,
        });
    }
    if (!std.mem.eql(u8, message.expected orelse "(needs update)", prev_msg.expected orelse "(needs update)")) {
        return eater.postError("{s}:{d}:{d}: multiple snapshots in the same position but different values for 'expected'.\nthis snapshot:\n====\n{s}\n====\n\nprev snapshot:\n====\n{s}\n====\n", .{
            eater.filepath,
            message.src.line,
            message.src.column,
            message.expected orelse "(needs update)",
            prev_msg.expected orelse "(needs update)",
        });
    }
    // this message is in the same line as the previous message, but it's okay because they are identical
}

fn lessThanSnapshotMessage(_: void, a: SnapshotMessage, b: SnapshotMessage) bool {
    if (a.src.line < b.src.line) return true;
    if (a.src.line > b.src.line) return false;
    if (a.src.column < b.src.column) return true;
    if (a.src.column > b.src.column) return false;
    return false; // equal is not less than ig
}

const TestingPartialMessage = struct {
    lyn: u32,
    col: u32,
    expected: ?[]const u8,
    actual: []const u8,
};
fn testPerformReplacements(gpa: std.mem.Allocator, messages: []const TestingPartialMessage, from: []const u8) !Snapshot {
    const res_messages = try gpa.alloc(SnapshotMessage, messages.len);
    defer gpa.free(res_messages);
    for (messages, res_messages) |*msg, *out| {
        out.* = .{
            .expected = msg.expected,
            .actual = msg.actual,
            .src = .{
                .module = "root",
                .file = "test.zig",
                .line = msg.lyn,
                .column = msg.col,
                .fn_name = "testFn",
            },
        };
    }
    var reader = std.Io.Reader.fixed(from);
    var writer = std.Io.Writer.Allocating.init(gpa);
    defer writer.deinit();
    var eater: Eater = .{
        .reader = &reader,
        .writer = &writer.writer,
        .filepath = "root/test.zig",
        .error_mode = .write,
    };
    performReplacements(gpa, res_messages, &eater) catch |e| switch (e) {
        error.Posted => {},
        else => |e2| return e2,
    };
    return .from(gpa, try writer.toOwnedSlice());
}

test performReplacements {
    const gpa = std.testing.allocator;
    try (try testPerformReplacements(gpa, &.{
        .{
            .lyn = 1,
            .col = 10,
            .expected = null,
            .actual = "hello",
        },
    },
        \\    snap(@src(), null);
    )).snap(@src(),
        \\    snap(@src(),
        \\        \\hello
        \\    );
    );
    try (try testPerformReplacements(gpa, &.{
        .{
            .lyn = 1,
            .col = 10,
            .expected = "hello",
            .actual = "goodbye",
        },
    },
        \\    snap(@src(), null);
    )).snap(@src(),
        \\    snap(@src(),<-
        \\error: root/test.zig:1:22: found 'null', but the report expected to find "hello"
    );
    try (try testPerformReplacements(gpa, &.{
        .{
            .lyn = 1,
            .col = 10,
            .expected = "hello",
            .actual = "goodbye",
        },
    },
        \\    snap(@src(),
        \\        \\hello
        \\    );
    )).snap(@src(),
        \\    snap(@src(),
        \\        \\goodbye
        \\    );
    );
    try (try testPerformReplacements(gpa, &.{
        .{
            .lyn = 1,
            .col = 10,
            .expected = "hello",
            .actual = "goodbye",
        },
    },
        \\    snap(@src(),
        \\        \\what's this?
        \\    );
    )).snap(@src(),
        \\    snap(@src(),<-
        \\error: root/test.zig:3:7: found "what's this?", but the report expected to find "hello"
    );
}
