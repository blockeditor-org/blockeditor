// ImageCache is used to draw images:
// - rdl entries reference an Image
// - Images which are used in an rdl this frame are flagged to keep
// - Images not used this frame are flagged as dead, and will be cleaned
//   up next time their texture is full

const std = @import("std");
const Texpack = @import("Texpack.zig");
const B2 = @import("beui_experiment.zig");

var _image_id: usize = 0;

// an image that is actively being rendered on the screen ends existing twice
// in cpu memory - once for the image contents and once in the atlas. wasted space.
pub const Image = struct {
    pub const ID = enum(usize) { _ };
    id: ID,
    size: @Vector(2, u16),
    format: Format,
    contents: []align(@alignOf(u32)) const u8,
    /// set to false once the image is written to an atlas. true means to write it again
    modified: bool,
    pub const Format = enum {
        grayscale,
        // rgb,
        rgba,
        fn nchannels(format: Format) usize {
            return switch (format) {
                .grayscale => 1,
                // .rgb => 3,
                .rgba => 4,
            };
        }
    };

    /// must fill image.mutate() after creating the image! otherwise it's uninitialized!
    pub fn create(gpa: std.mem.Allocator, size: @Vector(2, u16), format: Format) *Image {
        const npx = @as(usize, size[0]) * @as(usize, size[1]) * format.nchannels();
        const image = gpa.create(Image) catch @panic("oom");
        _image_id += 1;
        image.* = .{
            .id = @enumFromInt(_image_id),
            .size = size,
            .format = format,
            .contents = gpa.alignedAlloc(u8, .of(u32), npx) catch @panic("oom"),
            .modified = false,
        };
        return image;
    }
    pub fn mutate(self: *Image) []align(@alignOf(u32)) u8 {
        self.modified = true;
        return @constCast(self.contents);
    }
    pub fn destroy(self: *Image, gpa: std.mem.Allocator) void {
        gpa.free(self.contents);
        gpa.destroy(self);
    }
};

pub const Cache = struct {
    caches: std.EnumArray(Image.Format, OneFormatCache),

    pub fn init(gpa: std.mem.Allocator) Cache {
        return .{
            .caches = .init(.{
                .grayscale = .init(gpa, .grayscale),
                // .rgb = .init(gpa, .rgb),
                .rgba = .init(gpa, .rgba),
            }),
        };
    }
    pub fn deinit(self: *Cache) void {
        for (&self.caches.values) |*v| v.deinit();
    }

    pub fn notifyFrameStart(self: *Cache) void {
        for (&self.caches.values) |*v| v.notifyFrameStart();
    }
    pub fn getImageUVOnRenderFromRdl(self: *Cache, image: *Image) Texpack.Region.UV {
        return self.caches.getPtr(image.format).getImageUVOnRenderFromRdl(image);
    }
};
pub const OneFormatCache = struct {
    gpa: std.mem.Allocator,
    texpack: Texpack,
    image_id_to_region_map: std.AutoArrayHashMapUnmanaged(Image.ID, Texpack.Region),
    full_last_frame: bool,
    full_frames_in_row: usize = 0,
    just_cleared: bool = false,

    pub fn init(gpa: std.mem.Allocator, format: Image.Format) OneFormatCache {
        return .{
            .gpa = gpa,
            .texpack = Texpack.init(gpa, 2048, switch (format) {
                .grayscale => .greyscale,
                // .rgb => .rgb,
                .rgba => .rgba,
            }) catch @panic("oom"),
            .image_id_to_region_map = .empty,
            .full_last_frame = false,
        };
    }
    pub fn deinit(self: *OneFormatCache) void {
        self.texpack.deinit(self.gpa);
        self.image_id_to_region_map.deinit(self.gpa);
    }

    pub fn notifyFrameStart(self: *OneFormatCache) void {
        self.just_cleared = false;
        if (self.full_last_frame) {
            self.full_frames_in_row += 1;
            std.log.warn("clearing oneformatcache", .{});
            self.texpack.clear();
            self.image_id_to_region_map.clearRetainingCapacity();
            self.just_cleared = true;
            self.full_last_frame = false;
            // TODO: add a cooldown for the next time it's allowed to clear
            // because otherwise it will lag really bad
        } else {
            self.full_frames_in_row = 0;
        }
    }
    fn _reserve(self: *OneFormatCache, image: *Image) ?Texpack.Region {
        // reserve the image
        const reservation = self.texpack.reserve(self.gpa, image.size[0], image.size[1]) catch |e| switch (e) {
            error.AtlasFull => return null,
            error.OutOfMemory => @panic("oom"),
        };
        // save
        self.image_id_to_region_map.put(self.gpa, image.id, reservation) catch @panic("oom");
        return reservation;
    }
    const none_uv = Texpack.Region.UV{ .size = .{ 0, 0 }, .pos = .{ -1, -1 } };
    pub fn getImageUVOnRenderFromRdl(self: *OneFormatCache, image: *Image) Texpack.Region.UV {
        if (@reduce(.Or, image.size > @as(@Vector(2, u16), @splat(@intCast(self.texpack.size / 2))))) return none_uv; // don't even try;
        if (@reduce(.Or, image.size == @as(@Vector(2, u16), @splat(0)))) return none_uv;
        if (self.image_id_to_region_map.getPtr(image.id)) |region| {
            if (image.modified) {
                self.texpack.set(region.*, image.contents);
                image.modified = false;
            }
            return region.calculateUV(self.texpack.size);
        } else {
            const reservation = self._reserve(image) orelse {
                // failed to reserve
                self.full_last_frame = true;
                return none_uv;
            };
            self.texpack.set(reservation, image.contents);
            image.modified = false;
            return reservation.calculateUV(self.texpack.size);
        }
    }
};
