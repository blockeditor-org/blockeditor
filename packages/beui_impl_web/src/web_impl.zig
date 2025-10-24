// we will be able to use tracy on android. tracy can connect over the network.

extern fn @"web:console.debug"(msg: [*]const u8, len: usize) void;
extern fn @"web:console.info"(msg: [*]const u8, len: usize) void;
extern fn @"web:console.warn"(msg: [*]const u8, len: usize) void;
extern fn @"web:console.error"(msg: [*]const u8, len: usize) void;

const Beui = @import("beui").Beui;
const B2 = Beui.beui_experiment.Beui2;
const std = @import("std");
pub const std_options = blk: {
    var res: std.Options = if (@hasDecl(App, "std_options")) App.std_options else .{};
    res.logFn = webLog;
    break :blk res;
};
pub fn webLog(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    var res_al = std.array_list.Managed(u8).init(std.heap.c_allocator);
    defer res_al.deinit();

    const writer = res_al.writer();
    writer.print((if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ") ++ format, args) catch return;

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    switch (message_level) {
        .debug => @"web:console.debug"(res_al.items.ptr, res_al.items.len),
        .info => @"web:console.info"(res_al.items.ptr, res_al.items.len),
        .warn => @"web:console.warn"(res_al.items.ptr, res_al.items.len),
        .err => @"web:console.error"(res_al.items.ptr, res_al.items.len),
    }
}

const App = @import("app");

var app: App = undefined;
var beui: Beui = undefined;
var b2: Beui.beui_experiment.Beui2 = undefined;
var draw_list: Beui.draw_lists.RenderList = undefined;
var arena_state: std.heap.ArenaAllocator = undefined;

const BeuiVtable = struct {
    fn setClipboard(_: *const Beui.FrameCfg, _: [:0]const u8) void {
        std.log.info("TODO setClipboard", .{});
    }
    fn getClipboard(_: *const Beui.FrameCfg, _: *std.array_list.Managed(u8)) void {
        std.log.info("TODO getClipboard", .{});
    }
    pub const vtable: *const Beui.FrameCfgVtable = &.{
        .type_id = @typeName(BeuiVtable),
        .set_clipboard = &setClipboard,
        .get_clipboard = &getClipboard,
    };
};

export fn @"zig:init"() void {
    //_ = App;
    const gpa = std.heap.c_allocator;

    beui = .{};
    b2.init(&beui, gpa);
    app.init(std.heap.c_allocator);
    draw_list = .init(gpa);
    arena_state = .init(gpa);
}
export fn @"zig:renderFrame"() void {
    _ = arena_state.reset(.retain_capacity);
    const arena = arena_state.allocator();
    draw_list.clear();
    {
        var beui_vtable: BeuiVtable = .{};
        beui.newFrame(.{
            .arena = arena,
            .now_ms = std.time.milliTimestamp(),
            .user_data = @ptrCast(@alignCast(&beui_vtable)),
            .vtable = BeuiVtable.vtable,
        });
        defer beui.endFrame();

        const id = b2.newFrame(.{ .size = .{ 1024, 1024 } });
        const rdl = app.render(id.sub(@src()));
        b2.endFrame(rdl, &draw_list);
    }

    {
        // rewrite index data to not use base_vertex. glDrawElementsBaseVertex is available in gles3.2, but the emulator
        // in android studio only supports up to gles3.0
        // TODO: share this code between android and web
        const index_buffer_clone = arena.alloc(u32, draw_list.indices.items.len) catch @panic("oom");
        for (draw_list.commands.items) |command| {
            for (index_buffer_clone[command.first_index..][0..command.index_count], draw_list.indices.items[command.first_index..][0..command.index_count]) |*dest, src| {
                dest.* = @intCast(src + command.base_vertex);
            }
        }
    }

    for (draw_list.commands.items) |command| {
        _ = command;
    }
}
