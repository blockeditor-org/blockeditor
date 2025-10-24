const std = @import("std");
const ws = @import("websocket");

const App = struct { client: ws.Client };

pub fn main() !void {
    var gpa_backing = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa_backing.deinit() == .ok);
    const gpa = gpa_backing.allocator();

    var app: App = .{
        .client = try ws.Client.init(gpa, .{
            .port = 9224,
            .host = "localhost",
        }),
    };
    defer app.client.deinit();

    try app.client.handshake("/ws", .{
        .timeout_ms = 10_000,
        .headers = "Host: localhost:9224", // separate multiple headers with \r\n
    });

    const recv_thread = try std.Thread.spawn(.{}, recvThread, .{&app});
    defer recv_thread.join();

    defer app.client.close(.{}) catch |e| std.log.err("close error: {s}", .{@errorName(e)});

    std.log.info("wsnc. enter to exit", .{});

    // wait for enter key to be pressed
    while (true) {
        const msg = try std.Io.getStdIn().reader().readUntilDelimiterAlloc(gpa, '\n', std.math.maxInt(usize));
        defer gpa.free(msg);
        if (std.mem.eql(u8, msg, "") or std.mem.eql(u8, msg, "\r")) {
            // exit
            break;
        }
        std.log.info("sending \"{f}\"...", .{std.zig.fmtString(msg)});
        try app.client.writeBin(msg);
        std.log.info("-> sent", .{});
    }
}

fn recvThread(self: *App) void {
    while (true) {
        const msg = (self.client.read() catch return) orelse unreachable;
        defer self.client.done(msg);

        std.log.info("received message: \"{f}\"", .{std.zig.fmtString(msg.data)});
    }
}
