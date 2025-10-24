const std = @import("std");
const Beui = @import("Beui.zig");

// TODO:
// - the whole result should end up in one vertex and index buffer.
// - we should have three arrays:
// - vertices, indices, segments. segments contains subarrays of
//   (vertices[start, end], indices[start, end], and ?RenderListImage)
// - that way we copy one vertex array and then draw repeatedly from
//   different parts of the vertex array

// we could, if everything is a rectangle, just have 6 vertices
// and do everything with instanced draw calls
// probably saves on some bytes, who knows if it's faster though.

pub const RenderListImage = enum(u64) {
    grayscale,
    rgb,
    rgba,
    _,
};
pub const RenderListIndex = u16;
pub const RenderListVertex = struct {
    pos: @Vector(2, f32),
    uv: @Vector(2, f32),
    tint: @Vector(4, u8),
    circle: @Vector(2, f32),
    // TODO: rounding, shadow
};
pub const RenderListCommand = struct {
    vertex_count: usize, // internal only, wgpu doesn't care
    index_count: u32,
    first_index: u32,
    base_vertex: i32, // not sure if this is what I think it is
    image: ?RenderListImage,
    clip: RenderList.Clip,
};

pub const RenderList = struct {
    gpa: std.mem.Allocator,
    vertices: std.array_list.Managed(RenderListVertex),
    indices: std.array_list.Managed(RenderListIndex),
    commands: std.array_list.Managed(RenderListCommand),

    pub fn init(gpa: std.mem.Allocator) RenderList {
        return .{
            .gpa = gpa,
            .vertices = .init(gpa),
            .indices = .init(gpa),
            .commands = .init(gpa),
        };
    }
    pub fn deinit(self: *RenderList) void {
        self.vertices.deinit();
        self.indices.deinit();
        self.commands.deinit();
    }
    pub fn clear(self: *RenderList) void {
        self.vertices.clearRetainingCapacity();
        self.indices.clearRetainingCapacity();
        self.commands.clearRetainingCapacity();
    }

    fn getCmd(self: *RenderList, image: ?RenderListImage, min_remaining_vertices: usize, clip: Clip) *RenderListCommand {
        // empty case: create a new command
        if (self.commands.items.len == 0) {
            return self.addCmd(image, clip);
        }
        const last = &self.commands.items[self.commands.items.len - 1];
        // clip rect is different
        if (!std.meta.eql(last.clip, clip)) return self.addCmd(image, clip);
        // last item does not have enough remaining indices to hold new vertices case: create new sublist
        if (last.vertex_count + min_remaining_vertices > std.math.maxInt(RenderListIndex)) {
            return self.addCmd(image, clip);
        }
        // last item does not have an image assigned yet: assign image
        if (last.image == null) {
            last.image = image;
            return last;
        }
        // last item has an image assigned, but it is not the right image: create new sublist
        if (image != null and last.image.? != image.?) {
            return self.addCmd(image, clip);
        }
        // last image has an image assigned and it is the right image
        return last;
    }
    fn addCmd(self: *RenderList, image: ?RenderListImage, clip: Clip) *RenderListCommand {
        self.commands.append(.{
            .vertex_count = 0,
            .index_count = 0,
            .first_index = @intCast(self.indices.items.len),
            .base_vertex = @intCast(self.vertices.items.len), // not sure if this usage is right?
            .image = image,
            .clip = clip,
        }) catch @panic("oom");
        return &self.commands.items[self.commands.items.len - 1];
    }

    pub fn addVertices(self: *RenderList, image: ?RenderListImage, vertices: []const RenderListVertex, indices: []const RenderListIndex, offset_pos: @Vector(2, f32), clip: Beui.beui_experiment.RepositionableDrawList.ClipCfg) void {
        var cmd = self.getCmd(image, vertices.len, .{
            .x = @intFromFloat(@ceil(clip.ul[0])),
            .y = @intFromFloat(@ceil(clip.ul[1])),
            .w = @intFromFloat(@max(0, @floor(clip.br[0] - clip.ul[0]))),
            .h = @intFromFloat(@max(0, @floor(clip.br[1] - clip.ul[1]))),
        });

        const prev_vertices_len: u16 = @intCast(cmd.vertex_count); // vertices len can never be larger than (maxInt(u16) - vertices.len)
        self.vertices.ensureUnusedCapacity(vertices.len) catch @panic("oom");
        for (vertices) |vtx| {
            self.vertices.appendAssumeCapacity(.{
                .pos = vtx.pos + offset_pos,
                .uv = vtx.uv,
                .tint = vtx.tint,
                .circle = vtx.circle,
            });
        }
        self.indices.ensureUnusedCapacity(indices.len) catch @panic("oom");
        for (indices) |index| {
            std.debug.assert(index < vertices.len);
            self.indices.appendAssumeCapacity(prev_vertices_len + index);
        }
        cmd.vertex_count += vertices.len;
        cmd.index_count += @intCast(indices.len);
    }
    const Clip = struct {
        x: u32,
        y: u32,
        w: u32,
        h: u32,
    };
};
