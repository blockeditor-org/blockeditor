const std = @import("std");
const wuffs = blk: {
    const v = @import("wuffs");
    if (@hasDecl(v, "_wuffs_temp_fix")) break :blk v._wuffs_temp_fix;
    break :blk v;
};
const log = std.log.scoped(.loadimage);

// TODO: diagnostic pattern for wuffs errors

pub const LoadedImage = struct {
    w: u32,
    h: u32,
    rgba: []align(@alignOf(u32)) const u8,

    pub fn deinit(self: *const LoadedImage, gpa: std.mem.Allocator) void {
        gpa.free(self.rgba);
    }
};
const max_align = @alignOf(std.c.max_align_t);
pub const Loader = struct {
    // gpa is required to:
    // - allocate the decoder
    // - allocate the workbuf
    // if we would like to remove this we can:
    // - use a fixed size for the decoder buffer (eg [64]u8 maybe)
    // - require the user to pass the format in init() and allocate the workbuf themselves

    size: @Vector(2, u32),
    internal: struct {
        g_src: wuffs.wuffs_base__io_buffer,
        decoder_raw: []align(max_align) u8,
        g_image_decoder: *wuffs.wuffs_base__image_decoder,
        g_image_config: wuffs.wuffs_base__image_config,
        gpa: std.mem.Allocator,
    },

    const Format = enum {
        rgba_nonpremul,
        pub fn channels(self: Format) u32 {
            return switch (self) {
                .rgba_nonpremul => 4,
            };
        }
        fn wuffsFormat(self: Format) u32 {
            return switch (self) {
                .rgba_nonpremul => wuffs.WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL,
            };
        }
    };

    pub fn init(gpa: std.mem.Allocator, file_cont: []const u8) !Loader {
        var g_src = wuffs.wuffs_base__ptr_u8__reader(@constCast(file_cont.ptr), file_cont.len, true);

        const g_fourcc = wuffs.wuffs_base__magic_number_guess_fourcc(
            wuffs.wuffs_base__io_buffer__reader_slice(&g_src),
            g_src.meta.closed,
        );
        if (g_fourcc < 0) return error.CouldNotGuessFileFormat;

        const decoder_size = getDecoderAllocationSize(g_fourcc) orelse return error.UnsupportedImageFormat;
        const decoder_raw = try gpa.alignedAlloc(u8, .fromByteUnits(max_align), decoder_size);
        errdefer gpa.free(decoder_raw);
        @memset(decoder_raw, 0);

        const g_image_decoder = try initAndUpcast(g_fourcc, decoder_raw);

        var g_image_config = std.mem.zeroes(wuffs.wuffs_base__image_config);
        try wrapErr(wuffs.wuffs_base__image_decoder__decode_image_config(
            g_image_decoder,
            &g_image_config,
            &g_src,
        ));

        const g_width = wuffs.wuffs_base__pixel_config__width(&g_image_config.pixcfg);
        const g_height = wuffs.wuffs_base__pixel_config__height(&g_image_config.pixcfg);

        return .{
            .size = .{ g_width, g_height },
            .internal = .{
                .g_src = g_src,
                .decoder_raw = decoder_raw,
                .g_image_decoder = g_image_decoder,
                .g_image_config = g_image_config,
                .gpa = gpa,
            },
        };
    }

    pub fn deinit(self: *Loader) void {
        self.internal.gpa.free(self.internal.decoder_raw);
    }

    pub fn read(self: *Loader, format: Format, pixbuf_data: []u8) !void {
        std.debug.assert(pixbuf_data.len == @as(usize, self.size[0]) * @as(usize, self.size[1]) * format.channels());

        // Override the image's native pixel format
        wuffs.wuffs_base__pixel_config__set(
            &self.internal.g_image_config.pixcfg,
            format.wuffsFormat(),
            wuffs.WUFFS_BASE__PIXEL_SUBSAMPLING__NONE,
            self.size[0],
            self.size[1],
        );

        const workbuf_len = wuffs.wuffs_base__image_decoder__workbuf_len(self.internal.g_image_decoder).max_incl;
        const workbuf_data = try self.internal.gpa.alloc(u8, std.math.cast(usize, workbuf_len) orelse return error.OutOfBounds);
        defer self.internal.gpa.free(workbuf_data);

        @memset(pixbuf_data, 0);
        @memset(workbuf_data, 0);
        const g_workbuf_slice = wuffs.wuffs_base__make_slice_u8(workbuf_data.ptr, workbuf_data.len);
        const g_pixbuf_slice = wuffs.wuffs_base__make_slice_u8(pixbuf_data.ptr, pixbuf_data.len);

        var g_pixbuf = std.mem.zeroes(wuffs.wuffs_base__pixel_buffer);
        try wrapErr(wuffs.wuffs_base__pixel_buffer__set_from_slice(&g_pixbuf, &self.internal.g_image_config.pixcfg, g_pixbuf_slice));

        const tab = wuffs.wuffs_base__pixel_buffer__plane(&g_pixbuf, 0);
        if (tab.width != self.size[0] * format.channels() or tab.height != self.size[1]) {
            return error.InconsistentPixelBufferDimensions;
        }

        var g_frame_config = std.mem.zeroes(wuffs.wuffs_base__frame_config);
        try wrapErr(wuffs.wuffs_base__image_decoder__decode_frame_config(
            self.internal.g_image_decoder,
            &g_frame_config,
            &self.internal.g_src,
        ));

        try wrapErr(wuffs.wuffs_base__image_decoder__decode_frame(
            self.internal.g_image_decoder,
            &g_pixbuf,
            &self.internal.g_src,
            switch (wuffs.wuffs_base__frame_config__overwrite_instead_of_blend(&g_frame_config)) {
                true => wuffs.WUFFS_BASE__PIXEL_BLEND__SRC,
                false => wuffs.WUFFS_BASE__PIXEL_BLEND__SRC_OVER,
            },
            g_workbuf_slice,
            null,
        ));
    }
};
pub fn loadImage(gpa: std.mem.Allocator, file_cont: []const u8) !LoadedImage {
    var loader: Loader = try .init(gpa, file_cont);
    defer loader.deinit();
    const pixbuf_data = try gpa.alignedAlloc(u8, .of(u32), @as(usize, loader.size[0]) * @as(usize, loader.size[1]) * 4);
    errdefer gpa.free(pixbuf_data);
    try loader.read(.rgba_nonpremul, pixbuf_data);

    return .{
        .w = loader.size[0],
        .h = loader.size[1],
        .rgba = pixbuf_data,
    };
}

fn wrapErr(status: wuffs.wuffs_base__status) !void {
    if (wuffs.wuffs_base__status__message(&status)) |emsg| {
        log.err("image load error: {s}", .{emsg});
        return error.WuffsError;
    }
}

fn getDecoderAllocationSize(g_fourcc: i32) ?usize {
    return switch (g_fourcc) {
        wuffs.WUFFS_BASE__FOURCC__BMP => wuffs.sizeof__wuffs_bmp__decoder(),
        wuffs.WUFFS_BASE__FOURCC__GIF => wuffs.sizeof__wuffs_gif__decoder(),
        wuffs.WUFFS_BASE__FOURCC__JPEG => wuffs.sizeof__wuffs_jpeg__decoder(),
        wuffs.WUFFS_BASE__FOURCC__NPBM => wuffs.sizeof__wuffs_netpbm__decoder(),
        wuffs.WUFFS_BASE__FOURCC__NIE => wuffs.sizeof__wuffs_nie__decoder(),
        wuffs.WUFFS_BASE__FOURCC__PNG => wuffs.sizeof__wuffs_png__decoder(),
        wuffs.WUFFS_BASE__FOURCC__QOI => wuffs.sizeof__wuffs_qoi__decoder(),
        wuffs.WUFFS_BASE__FOURCC__TGA => wuffs.sizeof__wuffs_tga__decoder(),
        wuffs.WUFFS_BASE__FOURCC__WBMP => wuffs.sizeof__wuffs_wbmp__decoder(),
        wuffs.WUFFS_BASE__FOURCC__WEBP => wuffs.sizeof__wuffs_webp__decoder(),
        else => null,
    };
}
fn initAndUpcast(
    g_fourcc: i32,
    decoder_raw: []align(max_align) u8,
) !*wuffs.wuffs_base__image_decoder {
    return switch (g_fourcc) {
        wuffs.WUFFS_BASE__FOURCC__BMP => {
            try wrapErr(wuffs.wuffs_bmp__decoder__initialize(@ptrCast(decoder_raw.ptr), decoder_raw.len, wuffs.WUFFS_VERSION, wuffs.WUFFS_INITIALIZE__ALREADY_ZEROED));
            return wuffs.wuffs_bmp__decoder__upcast_as__wuffs_base__image_decoder(@ptrCast(decoder_raw.ptr)).?;
        },
        wuffs.WUFFS_BASE__FOURCC__GIF => {
            try wrapErr(wuffs.wuffs_gif__decoder__initialize(@ptrCast(decoder_raw.ptr), decoder_raw.len, wuffs.WUFFS_VERSION, wuffs.WUFFS_INITIALIZE__ALREADY_ZEROED));
            return wuffs.wuffs_gif__decoder__upcast_as__wuffs_base__image_decoder(@ptrCast(decoder_raw.ptr)).?;
        },
        wuffs.WUFFS_BASE__FOURCC__JPEG => {
            try wrapErr(wuffs.wuffs_jpeg__decoder__initialize(@ptrCast(decoder_raw.ptr), decoder_raw.len, wuffs.WUFFS_VERSION, wuffs.WUFFS_INITIALIZE__ALREADY_ZEROED));
            return wuffs.wuffs_jpeg__decoder__upcast_as__wuffs_base__image_decoder(@ptrCast(decoder_raw.ptr)).?;
        },
        wuffs.WUFFS_BASE__FOURCC__NPBM => {
            try wrapErr(wuffs.wuffs_netpbm__decoder__initialize(@ptrCast(decoder_raw.ptr), decoder_raw.len, wuffs.WUFFS_VERSION, wuffs.WUFFS_INITIALIZE__ALREADY_ZEROED));
            return wuffs.wuffs_netpbm__decoder__upcast_as__wuffs_base__image_decoder(@ptrCast(decoder_raw.ptr)).?;
        },
        wuffs.WUFFS_BASE__FOURCC__NIE => {
            try wrapErr(wuffs.wuffs_nie__decoder__initialize(@ptrCast(decoder_raw.ptr), decoder_raw.len, wuffs.WUFFS_VERSION, wuffs.WUFFS_INITIALIZE__ALREADY_ZEROED));
            return wuffs.wuffs_nie__decoder__upcast_as__wuffs_base__image_decoder(@ptrCast(decoder_raw.ptr)).?;
        },
        wuffs.WUFFS_BASE__FOURCC__PNG => {
            try wrapErr(wuffs.wuffs_png__decoder__initialize(@ptrCast(decoder_raw.ptr), decoder_raw.len, wuffs.WUFFS_VERSION, wuffs.WUFFS_INITIALIZE__ALREADY_ZEROED));
            return wuffs.wuffs_png__decoder__upcast_as__wuffs_base__image_decoder(@ptrCast(decoder_raw.ptr)).?;
        },
        wuffs.WUFFS_BASE__FOURCC__QOI => {
            try wrapErr(wuffs.wuffs_qoi__decoder__initialize(@ptrCast(decoder_raw.ptr), decoder_raw.len, wuffs.WUFFS_VERSION, wuffs.WUFFS_INITIALIZE__ALREADY_ZEROED));
            return wuffs.wuffs_qoi__decoder__upcast_as__wuffs_base__image_decoder(@ptrCast(decoder_raw.ptr)).?;
        },
        wuffs.WUFFS_BASE__FOURCC__TGA => {
            try wrapErr(wuffs.wuffs_tga__decoder__initialize(@ptrCast(decoder_raw.ptr), decoder_raw.len, wuffs.WUFFS_VERSION, wuffs.WUFFS_INITIALIZE__ALREADY_ZEROED));
            return wuffs.wuffs_tga__decoder__upcast_as__wuffs_base__image_decoder(@ptrCast(decoder_raw.ptr)).?;
        },
        wuffs.WUFFS_BASE__FOURCC__WBMP => {
            try wrapErr(wuffs.wuffs_wbmp__decoder__initialize(@ptrCast(decoder_raw.ptr), decoder_raw.len, wuffs.WUFFS_VERSION, wuffs.WUFFS_INITIALIZE__ALREADY_ZEROED));
            return wuffs.wuffs_wbmp__decoder__upcast_as__wuffs_base__image_decoder(@ptrCast(decoder_raw.ptr)).?;
        },
        wuffs.WUFFS_BASE__FOURCC__WEBP => {
            try wrapErr(wuffs.wuffs_webp__decoder__initialize(@ptrCast(decoder_raw.ptr), decoder_raw.len, wuffs.WUFFS_VERSION, wuffs.WUFFS_INITIALIZE__ALREADY_ZEROED));
            return wuffs.wuffs_webp__decoder__upcast_as__wuffs_base__image_decoder(@ptrCast(decoder_raw.ptr)).?;
        },
        else => return error.UnsupportedImageFormat,
    };
}

test loadImage {
    const gpa = std.testing.allocator;

    const loaded = try loadImage(gpa, @embedFile("test_image.png"));
    defer loaded.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), loaded.w);
    try std.testing.expectEqual(@as(usize, 1), loaded.h);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, loaded.rgba);
}
