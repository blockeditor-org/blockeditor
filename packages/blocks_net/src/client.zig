const std = @import("std");
const ws = @import("websocket");
const blocks_mod = @import("blocks");
const db_mod = blocks_mod.blockdb;
const log = std.log.scoped(.tcp_client);
const shared = @import("shared.zig");

pub const TcpSync = struct {
    gpa: std.mem.Allocator,
    db: *db_mod.BlockDB,

    client: ?ws.Client,
    client_available_to_close: std.Thread.Semaphore,
    client_ready_to_send: std.Thread.Semaphore,
    closed: std.atomic.Value(bool),
    kill_send_thread: std.atomic.Value(bool),
    write_mutex: std.Thread.Mutex,

    send_thread: std.Thread,
    recv_thread: std.Thread,

    pub fn init(self: *TcpSync, gpa: std.mem.Allocator, db: *db_mod.BlockDB) void {
        self.* = .{
            .gpa = gpa,
            .db = db,
            .client = undefined,
            .client_available_to_close = .{},
            .client_ready_to_send = .{},
            .closed = .{ .raw = false },
            .kill_send_thread = .{ .raw = false },
            .write_mutex = .{},

            .send_thread = undefined,
            .recv_thread = undefined,
        };

        self.recv_thread = std.Thread.spawn(.{}, recvThread, .{self}) catch @panic("spawn recv_thread fail");
        self.send_thread = std.Thread.spawn(.{}, sendThread, .{self}) catch @panic("spawn send_thread fail");
    }

    pub fn deinit(self: *TcpSync) void {
        log.info("deinit TcpSync", .{});

        self.kill_send_thread.store(true, .monotonic);
        self.db.send_queue.signal();

        log.info("-> wait for client ready", .{});
        self.client_available_to_close.wait();
        log.info("-> client ready, close stream", .{});
        self._close();
        log.info("-> stream closed, join recv thread", .{});
        self.recv_thread.join();

        log.info("-> recv thread closed, join send thread", .{});
        self.send_thread.join();

        log.info("-> send thread closed, deinit", .{});
        if (self.client) |*client| {
            client.deinit();
        }
        log.info("-> done.", .{});
    }

    fn _close(self: *TcpSync) void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();

        self.closed.store(true, .monotonic);
        // ok to call close twice
        if (self.client) |*client| {
            client.close(.{ .code = 4000, .reason = "bye" }) catch |e| switch (e) {
                error.ReasonTooLong => unreachable,
            };
        }
    }

    fn recvThread(self: *TcpSync) void {
        self.recvThread_error() catch |e| {
            log.err("recv thread fail: {s}", .{@errorName(e)});
            self._close();
            return;
        };
    }
    fn recvThread_error(self: *TcpSync) !void {
        self.client = null;
        {
            defer self.client_ready_to_send.post();
            {
                defer self.client_available_to_close.post();
                if (@import("builtin").target.os.tag == .windows) {
                    // https://github.com/karlseguin/websocket.zig/issues/46
                    // possibly zig std problems
                    log.err("TcpSync is not supported on windows. Will not attempt to connect.", .{});
                    return error.UnsupportedOperatingSystem;
                }
                self.client = try ws.Client.init(self.gpa, .{
                    .port = 9224,
                    .host = "localhost",
                });
            }
            if (self.client == null) return;

            try self.client.?.handshake("/ws", .{
                .timeout_ms = 10_000,
                .headers = "Host: localhost:9224", // separate multiple headers with \r\n
            });
        }

        // self.client.?.readTimeout(1000) catch {};
        while (true) {
            const msg = self.client.?.read() catch |e| {
                log.err("read fail: {s}", .{@errorName(e)});
                self._close();
                return;
            } orelse continue; // no timeout = never null
            defer self.client.?.done(msg);

            switch (msg.type) {
                .text, .binary => {
                    log.info("received: \"{f}\"", .{std.zig.fmtString(msg.data)});
                    // self.write_mutex.lock(); defer self.write_mutex.unlock(); try self.client.?.write(msg.data);
                },
                .ping => {
                    try self.client.?.writePong(msg.data);
                },
                .pong => {},
                .close => {
                    return error.ConnectionClosedByServer;
                },
            }
        }
    }
    fn sendThread(self: *TcpSync) void {
        sendThread_error(self) catch |e| {
            std.log.err("send thread error: {s}", .{@errorName(e)});
        };
    }

    fn _writeBin(self: *TcpSync, msg: []const u8) !usize {
        std.debug.assert(self.send_thread_msg_buf.items.len == 0);
        try self.send_thread_msg_buf.appendSlice(msg);
        defer self.send_thread_msg_buf.clearRetainingCapacity();

        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        try self.client.?.writeBin(self.send_thread_msg_buf.items);

        return msg.len;
    }
    fn sendThread_error(self: *TcpSync) !void {
        self.client_ready_to_send.wait();
        if (self.client == null) return;
        if (self.closed.load(.monotonic)) return;

        var builder: CombinedMessageBuilder = .{
            .message = .init(self.gpa),
            .client = &self.client.?,
            .mutex = &self.write_mutex,
        };
        defer builder.message.deinit();

        while (true) {
            const item = blk: {
                if (self.db.send_queue.tryRead()) |v| break :blk v;
                try builder.flush();
                break :blk self.db.send_queue.waitRead(&self.kill_send_thread) orelse break;
            };
            defer item.deinit(self.db);

            switch (item) {
                .fetch_and_watch_block => |op| {
                    try builder.addMessage(.{
                        .tag = .fetch_and_watch_block,
                        .block_id = op,
                    }, "");
                },
                .unwatch_block => |op| {
                    try builder.addMessage(.{
                        .tag = .unwatch_block,
                        .block_id = op,
                    }, "");
                },
                .create_block => |op| {
                    try builder.addMessage(.{
                        .tag = .create_block,
                        .block_id = op.block_id,
                    }, op.initial_value_owned);
                },
                .apply_operation => |op| {
                    try builder.addMessage(.{
                        .tag = .apply_operation,
                        .block_id = op.block_id,
                    }, op.operation_owned);
                },
            }
        }
    }
};

const CombinedMessageBuilder = struct {
    message: std.array_list.Managed(u8),
    client: *ws.Client,
    mutex: *std.Thread.Mutex,

    pub fn flush(self: *CombinedMessageBuilder) !void {
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.client.writeBin(self.message.items);
        }
        self.message.clearRetainingCapacity();
    }

    pub fn addMessage(self: *CombinedMessageBuilder, header: struct {
        tag: shared.message_tag_v1,
        block_id: blocks_mod.blockinterface2.BlockID,
    }, contents: []const u8) !void {
        self.message.writer().writeStructEndian(shared.message_header_v1{
            .tag = header.tag,
            .block_id = .{ .value = @intFromEnum(header.block_id) },
            .remaining_length = contents.len,
        }, .little) catch @panic("oom");
        self.message.writer().writeAll(contents) catch @panic("oom");
    }
};
