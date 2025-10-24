const std = @import("std");
const Beui = @import("Beui.zig");
const ft = Beui.font_experiment.ft;
const hb = Beui.font_experiment.hb;
const sb = Beui.font_experiment.sb;
const tracy = @import("anywhere").tracy;

const LayoutCache = @This();

const RenderedLineKey = struct {
    text: []const u8,
    max_width_times_16: u64,
};
const RenderedLineContext = struct {
    pub fn hash(self: @This(), s: RenderedLineKey) u32 {
        _ = self;
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(s.text);
        hasher.update(std.mem.asBytes(&s.max_width_times_16));

        return @as(u32, @truncate(hasher.final()));
    }
    pub fn eql(self: @This(), a: RenderedLineKey, b: RenderedLineKey, b_index: usize) bool {
        _ = self;
        _ = b_index;
        return std.mem.eql(u8, a.text, b.text) and a.max_width_times_16 == b.max_width_times_16;
    }
};

rendered_line_cache: std.ArrayHashMap(RenderedLineKey, TextLine, RenderedLineContext, true),
layout_cache: std.StringArrayHashMap(LayoutInfo),
font: Font,
gpa: std.mem.Allocator,
glyph_cache: std.AutoHashMap(u32, GlyphCacheEntry),

pub fn init(gpa: std.mem.Allocator, font: Font) LayoutCache {
    return .{
        .rendered_line_cache = .init(gpa),
        .layout_cache = .init(gpa),
        .font = font,
        .gpa = gpa,
        .glyph_cache = .init(gpa),
    };
}
pub fn deinit(self: *LayoutCache) void {
    for (self.rendered_line_cache.keys()) |v| self.gpa.free(v.text);
    for (self.rendered_line_cache.values()) |*v| v.deinit(self.gpa);
    self.rendered_line_cache.deinit();
    for (self.layout_cache.keys()) |k| self.gpa.free(k);
    for (self.layout_cache.values()) |v| self.gpa.free(v.items);
    self.layout_cache.deinit();
    self.glyph_cache.deinit();
    self.font.deinit();
}

pub const LayoutItem = struct {
    docbyte_offset_from_layout_line_start: u64,
    glyph_id: u32,
    offset: @Vector(2, f32),
    advance: @Vector(2, f32),
};
pub const LayoutInfo = struct {
    last_used: i64,
    ticked_last_frame: bool,
    height: f32,
    items: []LayoutItem,
};
const ShapingSegment = struct {
    length: usize,
    replace_text: ?[]const u8 = null,

    // TODO more stuff in here, ie text direction, ...
};
pub const Font = struct {
    // TODO
    // beui can hold a font cache
    // this can also be where getFtLib is defined

    hb_font: hb.Font,
    ft_face: ft.Face,

    pub fn init(font_data: []const u8) ?Font {
        // const hb_blob = hb.Blob.init(@constCast(font_data), .readonly) orelse return null;
        // errdefer hb_blob.deinit();

        // const hb_face = hb.Face.init(hb_blob, 0);
        // errdefer hb_face.deinit();

        // const hb_font = hb.Font.init(hb_face);
        // errdefer hb_font.deinit();

        const ft_face = Beui.font_experiment.getFtLib().createFaceMemory(font_data, 0) catch |err| {
            std.log.err("ft createFaceMemory fail: {s}", .{@errorName(err)});
            return null;
        };
        errdefer ft_face.deinit();

        ft_face.setCharSize(12 * 64, 12 * 64, 0, 0) catch return null;

        const hb_font = hb.Font.fromFreetypeFace(ft_face);
        errdefer hb_font.deinit();

        return .{
            .hb_font = hb_font,
            .ft_face = ft_face,
        };
    }

    pub fn deinit(self: *Font) void {
        self.hb_font.deinit();
        self.ft_face.deinit();
    }
};

// if we add an event listener for changes to the component:
// - we could maintain our own list of every character and its size, and modify
//   it when the component is edited
// - this will let us quickly go from bufbyte -> screen position
// - or from screen position -> bufbyte
// - and it will always give us access to total scroll height

pub fn getGlyphs(b2: *Beui.beui_experiment.Beui2) *@import("ImageCache.zig").OneFormatCache {
    return b2.persistent.image_cache.caches.getPtr(.grayscale);
}
pub fn tick(self: *LayoutCache, b2: *Beui.beui_experiment.Beui2) void {
    const beui = b2.persistent.beui1;
    const max_time = 10_000;
    const last_valid_time = beui.frame.frame_cfg.?.now_ms - max_time;

    if (getGlyphs(b2).just_cleared) {
        std.log.info("clearing rendered_line_cache because uvs changed", .{});

        // rendered_line_cache contains vertices which depend on these uvs
        for (self.rendered_line_cache.keys()) |v| self.gpa.free(v.text);
        for (self.rendered_line_cache.values()) |*v| v.deinit(self.gpa);
        self.rendered_line_cache.clearRetainingCapacity();
    }

    var i: usize = 0;
    while (i < self.layout_cache.count()) {
        const key = self.layout_cache.keys()[i];
        const value = &self.layout_cache.values()[i];
        if (!value.ticked_last_frame and value.last_used < last_valid_time) {
            self.gpa.free(value.items);
            // value pointer invalidates after this line
            std.debug.assert(self.layout_cache.swapRemove(key));
            self.gpa.free(key);
            // don't increment i; must process this item again because it just changed
        } else {
            value.ticked_last_frame = false;
            i += 1;
        }
    }

    // TODO clear rendered line cache too
}

const LineCharState = struct {
    const null_offset: @Vector(2, f32) = .{ std.math.nan(f32), std.math.nan(f32) };
    char_up_left_offset: @Vector(2, f32),
    line_height: f32,
    char_byte_in_string: usize,
    fn isNull(self: LineCharState) bool {
        return std.math.isNan(self.char_up_left_offset[0]);
    }
};
const rl = @import("render_list.zig");
pub const TextLine = struct {
    image: ?rl.RenderListImage,
    vertices: []const rl.RenderListVertex,
    indices: []const rl.RenderListIndex,
    cursor_positions: []const LineCharState,
    height: f32,
    multiline: bool,
    single_line_width: f32,
    last_used: i64,
    fn deinit(self: *TextLine, alloc: std.mem.Allocator) void {
        alloc.free(self.vertices);
        alloc.free(self.indices);
        alloc.free(self.cursor_positions);
    }
};
pub const Line = struct {
    text: []const u8,
    max_width: ?f32,
};
pub fn renderLine(self: *LayoutCache, b2: *Beui.beui_experiment.Beui2, line: Line) TextLine {
    const max_w_times_16: u64 = if (line.max_width) |m| std.math.lossyCast(u64, m * 16.0) else 0;
    // first, try for an exact match
    if (self.rendered_line_cache.getPtr(.{ .text = line.text, .max_width_times_16 = max_w_times_16 })) |xm| {
        xm.last_used = b2.persistent.beui1.frame.frame_cfg.?.now_ms;
        return xm.*;
    }
    // next, try for a match with max_width null and then check the resulting width. if it's less than max width, we can use it
    var exists_max_width_0 = false;
    if (self.rendered_line_cache.getPtr(.{ .text = line.text, .max_width_times_16 = 0 })) |xm| {
        exists_max_width_0 = true;
        if (!xm.multiline and (line.max_width == null or xm.single_line_width <= line.max_width.?)) {
            xm.last_used = b2.persistent.beui1.frame.frame_cfg.?.now_ms;
            return xm.*;
        }
    }
    // couldn't find in cache, have to rerender
    const layout = self.layoutLine(b2, line.text);
    var render_result = renderLine_nocache(self, b2, layout, line);
    render_result.last_used = b2.persistent.beui1.frame.frame_cfg.?.now_ms;
    if (exists_max_width_0 and !render_result.multiline) {
        // oops! we aren't wrapping yet.
        render_result.deinit(self.gpa);
        return self.rendered_line_cache.getPtr(.{ .text = line.text, .max_width_times_16 = 0 }).?.*;
    }
    const text_dupe = self.gpa.dupe(u8, line.text) catch @panic("oom");
    self.rendered_line_cache.putNoClobber(.{
        .text = text_dupe,
        .max_width_times_16 = if (render_result.multiline) max_w_times_16 else 0,
    }, render_result) catch @panic("oom");
    return render_result;
}
fn renderLine_nocache(self: *LayoutCache, b2: *Beui.beui_experiment.Beui2, layout: LayoutInfo, line: Line) TextLine {
    // TODO: this function should not reference 'docbyte's, those are a concept unique to TextDocument and are meaningless here.
    const tctx = tracy.trace(@src());
    defer tctx.end();

    // TODO: find three tiers of good break points based on the target width

    var vertices: std.array_list.Managed(rl.RenderListVertex) = .init(self.gpa);
    defer vertices.deinit();
    var indices: std.array_list.Managed(rl.RenderListIndex) = .init(self.gpa);
    defer indices.deinit();

    const line_state = self.gpa.alloc(LineCharState, line.text.len) catch @panic("oom");
    for (line_state) |*ls| ls.* = .{ .char_up_left_offset = LineCharState.null_offset, .line_height = 0, .char_byte_in_string = 0 };

    var cursor_pos: @Vector(2, f32) = .{ 0, 0 };
    var length_with_no_selection_render: f32 = 0.0;
    for (layout.items, 0..) |item, i| {
        const tctx_ = tracy.traceNamed(@src(), "handle char");
        defer tctx_.end();

        const item_docbyte = item.docbyte_offset_from_layout_line_start;
        const next_glyph_docbyte: u64 = if (i + 1 >= layout.items.len) item_docbyte + 1 else layout.items[i + 1].docbyte_offset_from_layout_line_start;
        const len = next_glyph_docbyte - item_docbyte;
        if (next_glyph_docbyte == item_docbyte) {
            length_with_no_selection_render += item.advance[0];
        } else {
            length_with_no_selection_render = 0;
        }
        const item_offset = @round(item.offset);

        const glyph_info = self.renderGlyph(b2, item.glyph_id, layout.height);
        if (glyph_info.region) |region| {
            const glyph_size: @Vector(2, f32) = @floatFromInt(glyph_info.size);
            const glyph_offset: @Vector(2, f32) = glyph_info.offset;

            // we should put this logic somewhere shared so we don't have to duplicate it here
            const ul = cursor_pos + item_offset + glyph_offset;
            const ur = ul + @Vector(2, f32){ glyph_size[0], 0 };
            const bl = ul + @Vector(2, f32){ 0, glyph_size[1] };
            const br = ul + glyph_size;

            const uv = region.calculateUV(getGlyphs(b2).texpack.size);
            const uv_ul: @Vector(2, f32) = .{ uv.pos[0], uv.pos[1] };
            const uv_ur: @Vector(2, f32) = .{ uv.pos[0] + uv.size[0], uv.pos[1] };
            const uv_bl: @Vector(2, f32) = .{ uv.pos[0], uv.pos[1] + uv.size[1] };
            const uv_br: @Vector(2, f32) = .{ uv.pos[0] + uv.size[0], uv.pos[1] + uv.size[1] };

            const tint: Beui.Color = .fromHexRgb(0xFFFFFF);

            const vstart = vertices.items.len;
            vertices.appendSlice(&.{
                .{ .pos = ul, .uv = uv_ul, .tint = tint.value, .circle = .{ 0, 0 } },
                .{ .pos = ur, .uv = uv_ur, .tint = tint.value, .circle = .{ 0, 0 } },
                .{ .pos = bl, .uv = uv_bl, .tint = tint.value, .circle = .{ 0, 0 } },
                .{ .pos = br, .uv = uv_br, .tint = tint.value, .circle = .{ 0, 0 } },
            }) catch @panic("oom");
            if (vertices.items.len > std.math.maxInt(u16)) {
                // there's lots of vertices. we need to report a frame warning somehow
                // b2.warn("lots of vertices")
                // anywhere_mod.beui.warn("lots of vertices")
            } else {
                indices.appendSlice(&.{
                    @intCast(vstart + 0), @intCast(vstart + 1), @intCast(vstart + 3),
                    @intCast(vstart + 0), @intCast(vstart + 3), @intCast(vstart + 2),
                }) catch @panic("oom");
            }
        }

        const total_width: f32 = length_with_no_selection_render + item.advance[0];
        // "…" is composed of "\xE2\x80\xA6" - this means it has three valid cursor positions (when moving with .byte). Include them all.
        for (0..@intCast(len)) |docbyte_offset| {
            const docbyte = item_docbyte + docbyte_offset;

            const portion = @floor(@as(f32, @floatFromInt(docbyte_offset)) / @as(f32, @floatFromInt(len)) * total_width);

            line_state[@intCast(docbyte)] = .{
                .char_up_left_offset = @floor(cursor_pos + @Vector(2, f32){ -length_with_no_selection_render + portion + 1, 0 }),
                .line_height = layout.height,
                .char_byte_in_string = @intCast(docbyte),
            };
        }

        cursor_pos += item.advance;
        cursor_pos = @floor(cursor_pos);
    }

    const res_height = layout.height + cursor_pos[1];

    const is_multiline = cursor_pos[1] != 0.0;

    return .{
        .image = .grayscale,
        .vertices = vertices.toOwnedSlice() catch @panic("oom"),
        .indices = indices.toOwnedSlice() catch @panic("oom"),
        .cursor_positions = line_state,
        .height = res_height,
        .multiline = is_multiline,
        .single_line_width = if (is_multiline) line.max_width orelse 0.0 else @min(cursor_pos[0], line.max_width orelse cursor_pos[0]),
        .last_used = 0,
    };
}

/// result pointer is valid until next layoutLine() call
pub fn layoutLine(self: *LayoutCache, b2: *Beui.beui_experiment.Beui2, line_text: []const u8) LayoutInfo {
    const tctx = tracy.trace(@src());
    defer tctx.end();

    const gpres = self.layout_cache.getOrPut(line_text) catch @panic("oom");
    if (gpres.found_existing) {
        gpres.value_ptr.last_used = b2.persistent.beui1.frame.frame_cfg.?.now_ms;
        gpres.value_ptr.ticked_last_frame = true;
        return gpres.value_ptr.*;
    }

    var layout_result_al: std.array_list.Managed(LayoutItem) = .init(self.gpa);
    defer layout_result_al.deinit();

    gpres.value_ptr.* = layoutLine_internal(self, line_text, &layout_result_al);
    gpres.key_ptr.* = self.gpa.dupe(u8, line_text) catch @panic("oom");
    gpres.value_ptr.last_used = b2.persistent.beui1.frame.frame_cfg.?.now_ms;
    gpres.value_ptr.ticked_last_frame = true;
    gpres.value_ptr.items = layout_result_al.toOwnedSlice() catch @panic("oom");

    return gpres.value_ptr.*;
}
fn layoutLine_internal(self: *LayoutCache, line_text: []const u8, layout_result_al: *std.array_list.Managed(LayoutItem)) LayoutInfo {
    const tctx = tracy.trace(@src());
    defer tctx.end();

    const line_height: f32 = 16;

    if (line_text.len == 0) return .{
        .last_used = 0,
        .ticked_last_frame = true,
        .height = line_height,
        .items = &.{
            // TODO add an invisible char for the last one or something
        },
    };

    // TODO: segment shape() calls based on:
    // - syntax highlighting style (eg in markdown we want to have some text rendered bold, or some as a heading)
    //   - syntax highlighting can change if a line above this one changed, so we will need to throw out the cache of
    //     anything below a changed line
    // - unicode bidi algorithm (fribidi or sheenbidi)
    // - different languages or something??
    //   - UAX 24, SheenBidi has a method for this
    // - fallback characters in different fonts????
    // - maybe use libraqm. it should handle all of this except fallback characters
    // - alternatively, use pango. it handles fallback characters too, if we can get it to build.

    var segments_al = std.array_list.Managed(ShapingSegment).init(self.gpa);
    defer segments_al.deinit();

    segments_al.append(.{ .length = line_text.len }) catch @panic("oom");
    std.debug.assert(line_text.len > 0); // handled above
    if (line_text[line_text.len - 1] == '\n') {
        var last = segments_al.pop().?;
        last.length -= 1;
        if (last.length > 0) segments_al.append(last) catch @panic("oom");
        segments_al.append(.{ .length = 1, .replace_text = "_" }) catch @panic("oom");
    }

    layout_result_al.clearRetainingCapacity();

    var start_offset: usize = 0;
    for (segments_al.items) |segment| {
        const buf: hb.Buffer = hb.Buffer.init() orelse @panic("oom");
        defer buf.deinit();

        if (segment.replace_text) |rpl| {
            std.debug.assert(rpl.len == segment.length);
            buf.addUTF8(rpl, 0, @intCast(segment.length));
        } else {
            _ = line_text[start_offset..][0..segment.length];
            buf.addUTF8(line_text, @intCast(start_offset), @intCast(segment.length)); // invalid utf-8 is ok, so we don't have to call the replace fn ourselves
        }
        defer start_offset += segment.length;

        buf.setDirection(.ltr);
        buf.setScript(.latin);
        buf.setLanguage(.fromString("en"));

        self.font.hb_font.shape(buf, null);

        for (
            buf.getGlyphInfos(),
            buf.getGlyphPositions().?,
        ) |glyph_info, glyph_relative_pos| {
            const glyph_id = glyph_info.codepoint;
            const glyph_docbyte = start_offset + glyph_info.cluster;
            const glyph_flags = glyph_info.getFlags();

            const glyph_offset: @Vector(2, i64) = .{ glyph_relative_pos.x_offset, glyph_relative_pos.y_offset };
            const glyph_advance: @Vector(2, i64) = .{ glyph_relative_pos.x_advance, glyph_relative_pos.y_advance };

            layout_result_al.append(.{
                .glyph_id = glyph_id,
                .docbyte_offset_from_layout_line_start = glyph_docbyte,
                .offset = @as(@Vector(2, f32), @floatFromInt(glyph_offset)) / @as(@Vector(2, f32), @splat(64.0)),
                .advance = @as(@Vector(2, f32), @floatFromInt(glyph_advance)) / @as(@Vector(2, f32), @splat(64.0)),
            }) catch @panic("oom");

            _ = glyph_flags;
        }
    }

    return .{
        .last_used = 0,
        .ticked_last_frame = true,
        .height = line_height,
        .items = layout_result_al.items,
    };
}

pub fn renderGlyph(self: *LayoutCache, b2: *Beui.beui_experiment.Beui2, glyph_id: u32, line_height: f32) GlyphCacheEntry {
    const gpres = self.glyph_cache.getOrPut(glyph_id) catch @panic("oom");
    if (gpres.found_existing) return gpres.value_ptr.*;
    const result: GlyphCacheEntry = self.renderGlyph_nocache(b2, glyph_id, line_height) catch |e| blk: {
        std.log.warn("render glyph error: glyph={d}, err={s}", .{ glyph_id, @errorName(e) });
        break :blk .{ .size = .{ 0, 0 }, .region = null };
    };
    gpres.value_ptr.* = result;
    return result;
}
fn renderGlyph_nocache(self: *LayoutCache, b2: *Beui.beui_experiment.Beui2, glyph_id: u32, line_height: f32) !GlyphCacheEntry {
    try self.font.ft_face.loadGlyph(glyph_id, .{ .render = true });
    const glyph = self.font.ft_face.glyph();
    const bitmap = glyph.bitmap();

    if (bitmap.buffer() == null) return error.NoBitmapBuffer;

    const region = getGlyphs(b2).texpack.reserve(self.gpa, bitmap.width(), bitmap.rows()) catch |e| switch (e) {
        error.AtlasFull => {
            getGlyphs(b2).full_last_frame = true;
            return .{ .size = .{ bitmap.width(), bitmap.rows() }, .region = null };
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    getGlyphs(b2).texpack.set(region, bitmap.buffer().?);

    return .{
        .offset = .{ @floatFromInt(glyph.bitmapLeft()), (line_height - 4) - @as(f32, @floatFromInt(glyph.bitmapTop())) },
        .size = .{ bitmap.width(), bitmap.rows() },
        .region = region,
    };
}

pub const GlyphCacheEntry = struct {
    size: @Vector(2, u32),
    offset: @Vector(2, f32) = .{ 0, 0 },
    region: ?Beui.Texpack.Region,
};
