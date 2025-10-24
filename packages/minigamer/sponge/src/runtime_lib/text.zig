const std = @import("std");
const lib = @import("lib.zig");
const assets = @import("assets");

const default_font = struct {
    pub const asset = lib.ImageSub.fromAsset(assets.font);
};

pub fn print(layer: u2, pos: @Vector(2, i32), comptime fmt: []const u8, args: anytype) void {
    var tr = TextRenderer.init(layer, pos);
    const writer = tr.writer();
    try writer.print(fmt, args);
}

const EmptyErrorSet = error{};
const TextRenderWriter = std.Io.Writer(*TextRenderer, EmptyErrorSet, TextRenderer.write);
const TextRenderer = struct {
    layer: u2,
    pos: @Vector(2, i32),
    x: i32,
    pub fn init(layer: u2, pos: @Vector(2, i32)) TextRenderer {
        return .{ .layer = layer, .pos = pos, .x = pos[0] };
    }
    pub fn writer(self: *TextRenderer) TextRenderWriter {
        return .{ .context = self };
    }
    fn write(tr: *TextRenderer, text: []const u8) EmptyErrorSet!usize {
        for (text) |char| switch (char) {
            '\n' => {
                tr.pos[0] = tr.x;
                tr.pos[1] += 10;
            },
            else => {
                renderChar(tr.layer, tr.pos, char);
                tr.pos += .{ 6, 0 };
            },
        };
        return text.len;
    }
};
fn renderChar(layer: u2, pos: @Vector(2, i32), char: u8) void {
    const cs: @Vector(2, i32) = .{ char % 16, char / 16 };

    const char_img = default_font.asset.subrect(cs * @Vector(2, i32){ 6, 10 } + @Vector(2, i32){ 1, 1 }, .{ 5, 9 }).?;
    lib.gpu.draw(layer, char_img, pos, .replace);
}
