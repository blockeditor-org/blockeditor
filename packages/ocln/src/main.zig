const std = @import("std");
const anywhere = @import("anywhere");
const util = anywhere.util;
const math = util.math;
const Grid = anywhere.util.grid.Grid;
const zpool = anywhere.util.zpool;
const print = @import("print.zig");
const loadimage = @import("loadimage");
const vec = util.vec;
const connection_layer = @import("connection_layer.zig");
const ConnectionLayer = connection_layer.ConnectionLayer;
const buildings = @import("buildings.zig");
const power = @import("power.zig");

const Beui = @import("beui").Beui;
const B2 = Beui.beui_experiment;

// storage:
//   for pathfinding, we want:
//     (x, y) => packed struct {can_stand: bool, can_climb: bool}
//   for heat transfer, we want:
//     (x, y, layer) => heat transfer info
//   for wire resolution, we want:
//     (x, y) => [4]Wire.Handle: list of wire ids that are on this handle
//        - this is so when you delete a wire, it can identify which wire to split in the graph
//        - or when you place a wire, it can identify
//        - and while rendering, if a wires_and_pipes tile is identified, it can determine which wire sprite to render
//        - note that crossovers are implemented by having two wires | - whereas connections are implemented by
//          having four wires -||-
//     place/remove a wire: add/remove it from the graph
//  for fluid pressure transfer, we want:
//    - not sure yet
//    - we have to go over the whole grid and output [4]f32 for each tile = newtons force in that direction
//    - and we have to keep stepping somehow to continue to resolve
//      ie there is a 2N force from the left tile, here is how it propagates (X=water,S=solid,V is applying the force)
//      V
//      ↓2N
//      X →2N X -0N X -0N S
//      X →2N X →2N X -0N S
//      X →2N X →2N X →2N S
//      X →2N X →2N X -0N S
//      X →2N X -0N X -0N S
//      X -0N X -0N X -0N S
//      that might be a linear equation solver. surely there is a way we can shift it over multiple frames
//      so it doesn't take 8e12 steps for a 100x200 grid.
//  for gui, we want:
//     (x, y) => wire|pipe|tile|..., and it can literally be a linear scan if we need. it's once per frame.
// so:
// - we will have:
//   - heat_transfer: Grid(3, i32, HeatTransferInfo)
//   - flags: Grid(2, i32, TileFlags)
//   - wire_pool: Pool(16, 16, Wire, struct {ptr: Wire})
// - TileFlags = packed struct { can_stand: bool, can_climb: bool, has_wire: bool, has_pipe: bool };
// - for heat transfer we will have a Grid(3, i32, Material)
// - heat transfer will occur between all layers
// - we could have 3 layers [tile,wires_and_pipes,buildings]

const Layers = enum {
    // liquid/gas | solid
    tile,
    // none | wire | pipe | wire_and_pipe
    wires_and_pipes,
    //
    buildings,

    pub fn int(self: Layers) i32 {
        return @intFromEnum(self);
    }
};

// fluid https://en.wikipedia.org/wiki/Bernoulli%27s_principle#Incompressible_flow_equation
// https://en.wikipedia.org/wiki/Siphon
//
// force amounts
// 100kPa = 10kN
// 1kG = 10N
// a cube of 100Kg water with air above it applies forces:
// - 11N force down (air pressure + gravity)
// - 10.5N force left/right (air pressure + ½gravity) (at the bottom it is 1gravity, at the top it is 0gravity, linear interpolation)
// - 10N force up (cancelling air pressure)
// - the net is no change

// pipes: we need to decide on a mini 3x3 grid vs a hex grid
// probably 3x3 is our choice. it seems more fun.

const App = @This();
gpa: std.mem.Allocator,
game: Game,
art: ?*B2.ImageCache.Image,
pub fn init(self: *App, gpa: std.mem.Allocator) void {
    self.* = .{ .gpa = gpa, .game = undefined, .art = null };
    self.game.init(gpa);
    self.game.map.generate(.{ 45, 20 }) catch @panic("oom");
    _ = self.game.map.placeBuilding(.{
        .tag = .generator,
        .center = .{ 8, 10 },
    }) catch @panic("placeBuilding");
    _ = self.game.map.createWire(.{
        .sides = .{
            .{ 8, 6 },
            .{ 8, 18 },
        },
        .user = .{},
    }) catch @panic("createWire");
    _ = self.game.map.createWire(.{
        .sides = .{
            .{ 2, 10 },
            .{ 20, 10 },
        },
        .user = .{},
    }) catch @panic("createWire");
    _ = self.game.map.createWire(.{
        .sides = .{
            .{ 10, 10 },
            .{ 10, 15 },
        },
        .user = .{},
    }) catch @panic("createWire");
    _ = self.game.map.placeBuilding(.{ .tag = .power_outlet, .center = .{ 10, 14 } }) catch @panic("placeBuilding");
    _ = self.game.map.placeBuilding(.{ .tag = .lamp, .center = .{ 13, 14 } }) catch @panic("placeBuilding");

    self.game.interface.overlay = .wires;
    self.game.interface.camera.scale *= 4;
    self.game.update() catch @panic("update");
}
pub fn deinit(self: *App) void {
    self.game.deinit();
    if (self.art) |art| art.destroy(self.gpa);
}
pub fn render(self: *App, call_id: B2.ID) *B2.RepositionableDrawList {
    const b2 = call_id.b2;
    const rdl = call_id.b2.draw();
    const id = call_id.sub(@src());
    const frame_size = b2.frame.frame_cfg.size;
    self.game.interface.camera.frame_size = frame_size;

    if (self.art == null) {
        var loader: loadimage.Loader = loadimage.Loader.init(self.gpa, @embedFile("art.png")) catch @panic("loadimage fail");
        defer loader.deinit();
        self.art = B2.ImageCache.Image.create(self.gpa, @intCast(loader.size), .rgba);
        loader.read(.rgba_nonpremul, self.art.?.mutate()) catch @panic("loadimage fail");
    }

    // render tiles (TODO: for perf let's at least use addVertices directly instead of many calls to addRect)
    // - 6ms is spent here & then finalizing. so we definitely shouldn't do this. maybe addVertices will be
    //   enough but we should probably:
    //   - make it into one buffer
    //   - send it off in parallel to the gpu (double-buffered, render the previous frame's vertices this frame)
    //   - make sure the camera buffer is applied as a uniform this frame so we get smooth camera movement
    //     even if the contents of some renders are one frame delayed
    // especially we want our own vertex format instead of the generic one

    var renderer: Renderer = .init(rdl, self.gpa, &self.game.interface.camera);
    defer renderer.deinit();

    switch (self.game.interface.overlay) {
        .normal => {},
        .wires => renderer.renderWiresOverlay(&self.game, self.art.?, id.sub(@src())),
    }
    renderer.renderRemaining(&self.game, self.art.?);
    renderer.flush();

    rdl.addRect(.{ .pos = .{ 0, 0 }, .size = frame_size, .tint = .fromHexRgb(0x00c0c0) });

    rdl.addMouseEventCapture2(call_id.sub(@src()), .{ 0, 0 }, frame_size, .{
        .buttons = .all,
        .onMouseEvent = .from(self, onMouseEvent),
        .onScrollEvent = .from(self, onScrollEvent),
    });

    // next:
    // - add a mouse catcher
    //   - [ ] right-click pan
    //   - [ ] scroll zoom
    //   - [ ] left click set tile
    // - keyboard catcher
    //   - [ ] change active tile to set
    // - save and load

    return rdl;
}

const Renderer = struct {
    rdl: *B2.RepositionableDrawList,
    gpa: std.mem.Allocator,
    vertices: std.ArrayList(B2.render_list.RenderListVertex),
    indices: std.ArrayList(B2.render_list.RenderListIndex),
    last_art: ?*B2.ImageCache.Image,
    camera: *Camera,
    rendered: struct {
        wires: bool = false,
    } = .{},

    pub fn init(rdl: *B2.RepositionableDrawList, gpa: std.mem.Allocator, camera: *Camera) Renderer {
        return .{ .vertices = .empty, .indices = .empty, .last_art = null, .rdl = rdl, .gpa = gpa, .camera = camera };
    }

    pub fn deinit(renderer: *Renderer) void {
        renderer.vertices.deinit(renderer.gpa);
        renderer.indices.deinit(renderer.gpa);
    }

    pub fn renderRemaining(renderer: *Renderer, game: *Game, art: *B2.ImageCache.Image) void {
        renderer.renderBuildings(game, art);
        if (!renderer.rendered.wires) renderer.renderWires(game, art);
        renderer.renderTiles(game, art);
    }

    pub fn renderBuildings(renderer: *Renderer, game: *Game, art: *B2.ImageCache.Image) void {
        var iter = game.map.building_pool.liveHandles();
        while (iter.next()) |building_handle| {
            const building: *Building = game.map.building_pool.getColumnPtrAssumeLive(building_handle, .ptr);
            const descriptor = buildings.building_to_descriptor_map.getPtrConst(building.tag);

            const center: @Vector(2, f32) = @floatFromInt(building.center);

            renderer.add(.from(center + descriptor.image.world.pos, descriptor.image.world.size), art, descriptor.image.spritesheet);
        }
    }

    pub fn renderWiresOverlay(renderer: *Renderer, game: *Game, art: *B2.ImageCache.Image, call_id: B2.ID) void {
        const id = call_id.sub(@src());
        var segments_iter = game.map.wires.segments.liveHandles();
        const loop_id_outer = id.pushLoop(@src(), Wires.SegmentPool.Handle);
        while (segments_iter.next()) |segment_handle| {
            const loop_id = loop_id_outer.value(@src(), segment_handle);
            const segment: *Wires.Segment = game.map.wires.segments.getColumnPtrAssumeLive(segment_handle, .ptr);
            // render text halfway between the sides
            const rounded = @round(segment.user.value * 100) / 100;
            const arrow = switch (std.math.order(rounded, 0)) {
                .lt => switch (segment.direction()) {
                    .x => "l", //"←",
                    .y => "d", //"↓",
                },
                .eq => "",
                .gt => switch (segment.direction()) {
                    .x => "r", //"→",
                    .y => "u", //"↑",
                },
            };
            const unit = if (rounded == 0) "" else "kJ/s";
            const msg = renderer.rdl.b2.fmt("{s}{d:.2}{s}", .{ arrow, @abs(rounded), unit });

            const sbl: math.vec2f32 = @floatFromInt(segment.sides[0]);
            const sur: math.vec2f32 = @floatFromInt(segment.sides[1]);
            const ul = game.interface.camera.worldToWindow().transformPoint(.{ sbl[0] + 0.5, sur[1] + 0.5 });
            const br = game.interface.camera.worldToWindow().transformPoint(.{ sur[0] + 0.5, sbl[1] + 0.5 });

            renderer.flush();
            const text_line = B2.textLine(.{ .caller_id = loop_id.sub(@src()), .constraints = .{ .available_size = .{ .w = null, .h = null } } }, .{ .text = msg });
            renderer.rdl.place(text_line.rdl, .{
                .offset = (br - ul) / @as(math.vec2f32, @splat(2)) + ul - (text_line.size / @as(math.vec2f32, @splat(2))),
            });
        }
        renderer.renderWires(game, art);
    }
    pub fn renderWires(renderer: *Renderer, game: *Game, art: *B2.ImageCache.Image) void {
        renderer.rendered.wires = true;
        var iter = vec.Iterator(2, i32).size(game.map.size_int);
        while (iter.next()) |posint| {
            const pos: math.vec2f32 = @floatFromInt(posint);

            const display = game.map.wires.getSegmentDisplay(posint);
            const val: usize = display.toInt();
            const start: math.vec2f32 = .{ 0, 224 };
            const addx = @mod(val, 16);
            const addy = @divFloor(val, 16);
            const addvec: math.vec2f32 = @floatFromInt(math.vec2usize{ addx, addy });
            renderer.add(.from(pos, @splat(1)), art, .from(start + addvec * math.vec2f32{ 16, 16 }, @splat(16)));
        }
    }

    pub fn renderTiles(renderer: *Renderer, game: *Game, art: *B2.ImageCache.Image) void {
        for (0..game.map.size_usize[1]) |y| {
            for (0..game.map.size_usize[0]) |x| {
                const posint: @Vector(2, i32) = @intCast(@Vector(2, usize){ x, y });
                const pos: @Vector(2, f32) = @floatFromInt(posint);
                const tile = game.map.materials.get(.{ posint[0], posint[1], Layers.tile.int() }) orelse Material.empty;
                if (tile.material == .none) continue;

                const image = getTileImage(tile.material);

                renderer.add(.from(pos + image.world.pos, image.world.size), art, image.spritesheet);
            }
        }
    }

    pub fn add(renderer: *Renderer, rect_worldspace: math.Rect(2, f32), image: *B2.ImageCache.Image, image_sub: math.Rect(2, f32)) void {
        const image_uv_raw = renderer.rdl.b2.persistent.image_cache.getImageUVOnRenderFromRdl(image);
        const image_uv: math.UV(2, f32) = .{ .pos = image_uv_raw.pos, .size = image_uv_raw.size };
        const img_size: math.vec2f32 = @floatFromInt(image.size);

        const uv = image_uv.innerRect(.from(image_sub.pos, image_sub.size, img_size));

        const bl: math.vec2f32 = renderer.camera.worldToWindow().transformPoint(rect_worldspace.pos);
        const ur: math.vec2f32 = renderer.camera.worldToWindow().transformPoint(rect_worldspace.pos + rect_worldspace.size);
        const br: math.vec2f32 = .{ ur[0], bl[1] };
        const ul: math.vec2f32 = .{ bl[0], ur[1] };

        const uv_ul = uv.pos;
        const uv_ur = uv.pos + math.vec2f32{ uv.size[0], 0 };
        const uv_bl = uv.pos + math.vec2f32{ 0, uv.size[1] };
        const uv_br = uv.pos + uv.size;

        if (renderer.vertices.items.len + 3 >= std.math.maxInt(B2.render_list.RenderListIndex) or (renderer.last_art != null and image != renderer.last_art)) {
            // need to commit
            renderer.flush();
        }
        const ib: B2.render_list.RenderListIndex = @intCast(renderer.vertices.items.len);
        renderer.vertices.appendSlice(renderer.gpa, &.{
            .{ .pos = ul, .uv = uv_ul, .tint = Beui.Color.fromHexRgb(0xFFFFFF).value, .circle = .{ 0, 0 } },
            .{ .pos = ur, .uv = uv_ur, .tint = Beui.Color.fromHexRgb(0xFFFFFF).value, .circle = .{ 0, 0 } },
            .{ .pos = bl, .uv = uv_bl, .tint = Beui.Color.fromHexRgb(0xFFFFFF).value, .circle = .{ 0, 0 } },
            .{ .pos = br, .uv = uv_br, .tint = Beui.Color.fromHexRgb(0xFFFFFF).value, .circle = .{ 0, 0 } },
        }) catch @panic("oom");
        renderer.indices.appendSlice(renderer.gpa, &.{
            // note that these are inverted because ul/br/ur/bl are inverted
            ib + 0, ib + 1, ib + 3,
            ib + 0, ib + 3, ib + 2,
        }) catch @panic("oom");
        renderer.last_art = image;
    }
    pub fn flush(renderer: *Renderer) void {
        if (renderer.vertices.items.len == 0) return;
        renderer.rdl.addVertices(.rgba, renderer.vertices.items, renderer.indices.items);
        renderer.vertices.clearRetainingCapacity();
        renderer.indices.clearRetainingCapacity();
        renderer.last_art = null;
    }
};

fn onMouseEvent(self: *App, b2: *B2.Beui2, ev: B2.MouseEvent) ?Beui.Cursor {
    // std.log.info("onMouseEvent: {f}", .{print.autoPrint(ev)});
    if (ev.action == .move_while_down or ev.action == .up) {
        self.game.interface.camera.centered_on_pos += self.game.interface.camera.worldToWindow().inverse().transformVector(ev.offset);
    }
    _ = b2;
    return .arrow;
}
fn onScrollEvent(self: *App, b2: *B2.Beui2, ev: B2.ScrollEvent) bool {
    _ = self;
    _ = b2;
    _ = ev;
    // this isn't called yet oops
    return true;
}

const Camera = struct {
    centered_on_pos: @Vector(2, f32) = @splat(0),
    scale: f32 = 16,

    frame_size: @Vector(2, f32) = .{ 1, 1 },

    pub fn worldToWindow(camera: *Camera) math.Transform2D {
        return .from(
            .from(camera.centered_on_pos, .{ 1, -1 }),
            .from(camera.frame_size / @as(math.vec2f32, @splat(2)), @splat(camera.scale)),
        );
    }

    pub fn serdes(
        item: *Camera,
        comptime mode: util.SerializeDeserialize.Mode,
        sd: *mode.Value(),
        extra: mode.Extra(GameSerializeExtra),
    ) !void {
        _ = extra;
        const scale = try sd.value(f32, "scale", if (comptime mode.in()) item.scale);
        const centered_on_pos = try sd.value(math.vec2f32, "centered_on_pos", if (comptime mode.in()) item.centered_on_pos);
        if (comptime mode.out()) item.* = .{
            .scale = scale,
            .centered_on_pos = centered_on_pos,
        };
    }
};
const Interface = struct {
    camera: Camera = .{},
    overlay: Overlay = .normal,
    const Overlay = enum { normal, wires };
    pub fn serdes(
        item: *Interface,
        comptime mode: util.SerializeDeserialize.Mode,
        sd: *mode.Value(),
        extra: mode.Extra(GameSerializeExtra),
    ) !void {
        try item.camera.serdes(mode, sd, extra);
    }
};

fn getTileImage(material: MaterialTag) Image {
    return switch (material) {
        .unobtanium => .{ .world = .from(@splat(0), @splat(1)), .spritesheet = .from(.{ 64, 0 }, @splat(16)) },
        .stone => .{ .world = .from(@splat(0), @splat(1)), .spritesheet = .from(.{ 16, 0 }, @splat(16)) },
        .dirt => .{ .world = .from(@splat(0), @splat(1)), .spritesheet = .from(.{ 16, 16 }, @splat(16)) },
        .shelf => .{ .world = .from(@splat(0), @splat(1)), .spritesheet = .from(.{ 32, 9 }, @splat(16)) },
        else => .{ .world = .from(@splat(0), @splat(1)), .spritesheet = .from(.{ 48, 0 }, @splat(16)) },
    };
}

const Game = struct {
    map: Map,
    interface: Interface,
    pub fn init(game: *Game, gpa: std.mem.Allocator) void {
        // ser/des validation: TODO
        if (false) {
            var t: Game = undefined;
            t.initUnvalidated(gpa);
            defer t.deinit();

            const serialized = t.serializeAlloc(gpa) catch @panic("oom");
            game.deserialize(gpa, serialized) catch @panic("deserialize failure");
        } else {
            game.initUnvalidated(gpa);
        }
    }
    fn initUnvalidated(game: *Game, gpa: std.mem.Allocator) void {
        game.* = .{ .map = undefined, .interface = .{} };
        game.map.init(gpa);
    }
    pub fn deinit(game: *Game) void {
        game.map.deinit();
    }

    pub fn serdes(
        item: *Game,
        comptime mode: util.SerializeDeserialize.Mode,
        value: *mode.Value(),
        extra: mode.Extra(GameSerializeExtra),
    ) !void {
        try item.interface.serdes(mode, value, extra);
        try item.map.serdes(mode, value, extra);
    }

    pub fn update(this: *Game) !void {
        const t1 = anywhere.tracy.trace(@src());
        defer t1.end();

        defer {
            this.validateSerdes() catch |e| std.debug.panic("invalidSerdes: {s}", .{@errorName(e)});
        }

        // first, we do some things in parallel
        // - agent pathfinding & such
        // - water calculations
        // - power calculations
        // io.async(...)
        // then, we merge and apply the results sequentially

        // update power:
        // 1. we iterate over every power wire and add a node at the start point and end point and a link between the two
        // 2. now we need to do connected component labeling to identify subgraphs

        const gpa = this.map.gpa;

        var resolver: WireNetworkResolver = .{ .intersection_queue = .empty, .intersection_queue_index = 0 };
        defer resolver.intersection_queue.deinit(gpa);

        var segments = this.map.wires.segments.liveHandles();
        while (segments.next()) |segment_handle| {
            const segment: *Wires.Segment = this.map.wires.segments.getColumnPtrAssumeLive(segment_handle, .ptr);
            try resolver.intersection_queue.put(gpa, segment.sides[0], {});
            if (resolver.intersection_queue.count() > resolver.intersection_queue_index) {
                try resolver.exploreAndCalculate(this, gpa);
            }
        }
    }

    pub fn serializeAlloc(this: *Game, gpa: std.mem.Allocator) ![]u8 {
        const count = blk: {
            var sd: util.SerializeDeserialize.Value(.count) = .initCounter();
            try this.serdes(.count, &sd, &.{ .gpa = this.map.gpa });
            break :blk sd.internal.count;
        };
        const serialized = gpa.alloc(u8, count) catch @panic("oom");
        errdefer gpa.free(serialized);
        {
            var sd: util.SerializeDeserialize.Value(.serialize) = .initSerializer(serialized);
            try this.serdes(.serialize, &sd, &.{ .gpa = this.map.gpa });
        }
        return serialized;
    }
    pub fn deserialize(this: *Game, gpa: std.mem.Allocator, src: []u8) !void {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var sd: util.SerializeDeserialize.Value(.deserialize) = .initDeserializer(src, &arena);
        this.serdes(.deserialize, &sd, &.{ .gpa = gpa }) catch @panic("deserfail");
    }
    pub fn validateSerdes(dsr0: *Game) !void {
        const gpa = dsr0.map.gpa;

        const ser1 = try dsr0.serializeAlloc(gpa);
        defer gpa.free(ser1);

        std.log.info("srlz: {s}", .{ser1});

        var dsr1: Game = undefined;
        try dsr1.deserialize(gpa, ser1);
        defer dsr1.deinit();

        const ser2 = try dsr1.serializeAlloc(gpa);
        defer gpa.free(ser2);

        try std.testing.expectEqualStrings(ser1, ser2);
    }

    const WireNetworkResolver = struct {
        intersection_queue: std.AutoArrayHashMapUnmanaged(math.vec2i32, void),
        intersection_queue_index: usize,

        fn exploreAndCalculate(self: *WireNetworkResolver, game: *Game, gpa: std.mem.Allocator) !void {
            const t2 = anywhere.tracy.trace(@src());
            defer t2.end();

            var nodes: std.AutoArrayHashMapUnmanaged(math.vec2i32, power.Node) = .empty;
            defer nodes.deinit(gpa);

            var links: std.MultiArrayList(struct { handle: Wires.SegmentPool.Handle, link: power.Link }) = .empty; // link index -> wire.segment
            defer links.deinit(gpa);

            while (self.intersection_queue_index < self.intersection_queue.count()) : (self.intersection_queue_index += 1) {
                const pos = self.intersection_queue.keys()[self.intersection_queue_index];
                const connections = game.map.wires.getSegments(pos);
                std.debug.assert(connections.len > 0);
                for (connections) |connection_handle| {
                    const connection: *Wires.Segment = game.map.wires.segments.getColumnPtrAssumeLive(connection_handle, .ptr);

                    const s0 = try nodes.getOrPut(gpa, connection.sides[0]);
                    if (!s0.found_existing) s0.value_ptr.* = .{ .intrinsic_value = 0 };

                    const s1 = try nodes.getOrPut(gpa, connection.sides[1]);
                    if (!s1.found_existing) s0.value_ptr.* = .{ .intrinsic_value = 0 };

                    try links.append(gpa, .{
                        .link = .{
                            .src = s0.index,
                            .dst = s1.index,
                            .cost = @floatFromInt(@reduce(.Add, @abs(connection.sides[1] - connection.sides[0]))),
                        },
                        .handle = connection_handle,
                    });

                    try self.intersection_queue.put(gpa, connection.sides[0], {});
                    try self.intersection_queue.put(gpa, connection.sides[1], {});
                }
            }

            // TODO:
            //     - within a subgraph, we sum the maximum power production
            //     - based on this, we sum the power need. when there is more need than production, some items don't get power.
            //       batteries get any excess power if there are any available (up to maximum production level)
            //     - now, we determine power production based on need
            //     - finally, we report results:
            //       - which machines are active
            //       - how much the generators are used
            //       - which wires heat up (wires only heat up if more power is going through them than their capacity)
            //         - where does the energy to heat the wire come from? maybe we increase battery drain or generator production to
            //           get the energy. if we fali then we would have to reduce consumption which would mess with the graph so instead
            //           we can just ignore it. meaning the smallest wire can carry infinite capacity going from a generator to a battery
            //           because production and consumption is exactly matched. no that doesn't quite work. it will come from somewhere.
            // for now let's loop over the nodes and set their intrinsic values

            const Item = struct {
                const Item = @This();
                handle: BuildingPool.Handle,
                building: *Building,
                descriptor: *const buildings.BuildingDescriptor,
                node: *power.Node,
                fn energyPriorityHighestToLowest(map: *Map, lhs: Item, rhs: Item) bool {
                    const lhs_level = map.getPriorityLevel(lhs.building.energy_priority);
                    const rhs_level = map.getPriorityLevel(rhs.building.energy_priority);
                    return @intFromEnum(lhs_level) > @intFromEnum(rhs_level);
                }
            };
            var producers = std.ArrayList(Item).empty;
            defer producers.deinit(gpa);
            var consumers = std.ArrayList(Item).empty;
            defer consumers.deinit(gpa);
            var batteries = std.ArrayList(Item).empty;
            defer batteries.deinit(gpa);

            for (nodes.keys(), nodes.values()) |pos, *node| {
                if (game.map.getFlag(pos, .port) == .power) {
                    const building_handle = game.map.pos_to_building.get(pos) orelse unreachable; // ports are only present on buildings
                    const building: *Building = game.map.building_pool.getColumnPtrAssumeLive(building_handle, .ptr);
                    const building_descriptor = buildings.building_to_descriptor_map.getPtrConst(building.tag);
                    std.debug.assert(building_descriptor.power != null); // if it has a power port it must have a power descriptor
                    const item: Item = .{ .handle = building_handle, .building = building, .descriptor = building_descriptor, .node = node };
                    switch (building_descriptor.power.?.mode) {
                        .producer => try producers.append(gpa, item),
                        .consumer => try consumers.append(gpa, item),
                        .battery => try batteries.append(gpa, item),
                    }
                }
            }
            std.mem.sort(Item, producers.items, &game.map, Item.energyPriorityHighestToLowest);
            std.mem.sort(Item, consumers.items, &game.map, Item.energyPriorityHighestToLowest);
            std.mem.sort(Item, batteries.items, &game.map, Item.energyPriorityHighestToLowest);

            // these units are the amount of energy transmitted in one tick
            var maximum_generation: u64 = 0;
            var actual_consumption: u64 = 0;
            var actual_production: u64 = 0;

            for (producers.items) |item| {
                switch (item.building.tag) {
                    .generator => maximum_generation += 5,
                    else => std.debug.panic("TODO impl power producer: {s}", .{@tagName(item.building.tag)}),
                }
            }

            // TODO: add maximum single-tick discharge capacity from batteries (likely this will be the battery's charge level)

            var committed_consumers_end: usize = 0;
            {
                var uncommitted: u64 = 0;
                var uncommitted_level: PriorityLevel = .min;
                for (consumers.items, 0..) |item, index| {
                    const prio = game.map.getPriorityLevel(item.building.energy_priority);
                    if (prio != uncommitted_level) {
                        actual_consumption += uncommitted;
                        committed_consumers_end = index;

                        uncommitted = 0;
                        uncommitted_level = prio;
                    }

                    switch (item.building.tag) {
                        .power_outlet => uncommitted += 5,
                        else => std.debug.panic("TODO impl power consumer: {s}", .{@tagName(item.building.tag)}),
                    }
                    if (actual_consumption + uncommitted > maximum_generation) {
                        // too much uncommitted consumption, we can't commit this level
                        break;
                    }
                } else {
                    actual_consumption += uncommitted;
                    committed_consumers_end = consumers.items.len;
                }
            }
            if (actual_consumption < maximum_generation) {
                // TODO: if there is excess production capacity, fill batteries
            }

            var committed_producers_end: usize = 0;
            var shared_producers_end: usize = 0;
            var shared_producers_share: u64 = 0; // total amount of energy produced by all shared producers
            {
                var uncommitted: u64 = 0;
                var uncommitted_level: PriorityLevel = .min;
                for (producers.items, 0..) |item, index| {
                    const prio = game.map.getPriorityLevel(item.building.energy_priority);
                    if (prio != uncommitted_level) {
                        actual_production += uncommitted;
                        committed_producers_end = index;
                        shared_producers_end = index;

                        uncommitted = 0;
                        uncommitted_level = prio;
                    }

                    switch (item.building.tag) {
                        .generator => uncommitted += 5,
                        else => std.debug.panic("TODO impl power producer: {s}", .{@tagName(item.building.tag)}),
                    }
                    if (actual_production + uncommitted > actual_consumption) {
                        shared_producers_share = actual_consumption - actual_production;
                        actual_production = actual_consumption;
                        // too much uncommitted generation, we need to finish off this level as shared producers
                        shared_producers_end = index;
                        break;
                    }
                } else {
                    actual_production += uncommitted;
                    committed_producers_end = consumers.items.len;
                    shared_producers_end = consumers.items.len;
                }

                for (producers.items[shared_producers_end..], shared_producers_end..) |item, index| {
                    const prio = game.map.getPriorityLevel(item.building.energy_priority);
                    if (prio != uncommitted_level) break;
                    shared_producers_end = index;
                }
            }

            if (actual_production < actual_consumption) {
                // TODO: if there is not enough production capacity, drain batteries
            }

            if (actual_production != actual_consumption) {
                std.debug.panic("generation and consumption must be matched by now. consumption={d},production={d}", .{ actual_consumption, actual_production });
            }

            // TODO: activate all consumers from 0 to committed_consumers_len
            for (consumers.items[0..committed_consumers_end]) |item| {
                switch (item.building.tag) {
                    .power_outlet => item.node.intrinsic_value -= 5,
                    else => std.debug.panic("TODO impl power consumer: {s}", .{@tagName(item.building.tag)}),
                }
            }
            // TODO: activate all producers at n% capacity based on their share of the shared production share
            for (producers.items[0..committed_producers_end]) |item| {
                switch (item.building.tag) {
                    .generator => item.node.intrinsic_value += 5,
                    else => std.debug.panic("TODO impl power producer: {s}", .{@tagName(item.building.tag)}),
                }
            }
            for (producers.items[committed_producers_end..shared_producers_end]) |item| {
                _ = item;
                @panic("TODO: activate shared producer");
            }

            var balance: f64 = 0;
            for (nodes.values()) |*node| {
                balance += node.intrinsic_value;
            }
            if (@abs(balance) > 0.1) {
                std.debug.panic("generation and consumption are supposed to be balanced. balance is: {d}", .{balance});
            }

            var result: power.PowerNetwork = .{
                .gpa = gpa,
                .links = .fromOwnedSlice(links.items(.link)),
                .nodes = .fromOwnedSlice(nodes.values()),
            };
            try result.calculate();

            for (links.items(.link), links.items(.handle)) |*link, handle| {
                const connection: *Wires.Segment = game.map.wires.segments.getColumnPtrAssumeLive(handle, .ptr);
                connection.user.value = link.value;
            }
        }
    };
};
const GameSerializeExtra = struct {
    pub const Count = *const struct { gpa: std.mem.Allocator };
    pub const Serialize = *const struct { gpa: std.mem.Allocator };
    pub const Deserialize = *const struct { gpa: std.mem.Allocator };
};

// https://en.wikipedia.org/wiki/Connected-component_labeling

// in recipes:
// - conserve energy. input energy = output energy
// - mass is basically conserved even when heat is released. the lost mass is very small.
//   we will probably not make recipes release heat then.

// wire resolution: make a big graph and then simplify it. then send it to wires

const MAP_NLAYERS: usize = @typeInfo(Layers).@"enum".fields.len;

const MaterialTag = enum(u32) {
    none,
    unobtanium,
    dirt,
    stone,
    shelf,
    other,
    _,

    fn canStandOn(mat: MaterialTag) bool {
        return switch (mat) {
            .none => false,
            .unobtanium => true,
            .dirt => true,
            .stone => true,
            .shelf => true,
        };
    }
    fn canStandIn(mat: MaterialTag) bool {
        return switch (mat) {
            .none => true,
            .unobtanium => false,
            .dirt => false,
            .stone => false,
            .shelf => true,
        };
    }
};
pub const milli_per_one = 1000000;
pub const milli_per_kilo = 1000000000;
pub const zero_millicelsius_in_millikelvin = 273150000;
pub const Material = extern struct {
    // TODO: we should store material properties in here rather than a material tag
    // because many tiles will have mixed materials (ie oxygen & water, wire & pipe)
    // and we will approximate that by summing the material properties over their area.
    // that isn't quite right because a mixed water/air tile will transfer heat faster than
    // expected to the air above it. but it's probably fine.
    material: MaterialTag,
    mass_milligrams: u64 align(4),
    temperature_millikelvin: u64 align(4),
    comptime {
        std.debug.assert(@sizeOf(Material) == 20);
        std.debug.assert(std.meta.hasUniqueRepresentation(Material));
    }
    pub const empty: Material = .{
        .material = .none,
        .mass_milligrams = 0,
        .temperature_millikelvin = 0,
    };
    pub const unobtanium: Material = .{
        .material = .unobtanium,
        .mass_milligrams = 2000 * milli_per_kilo,
        .temperature_millikelvin = zero_millicelsius_in_millikelvin,
    };

    pub fn energy(this: *const Material) u128 {
        _ = this;
        // potential energy: mass * gravity * height from y=0
        //    - lifting a tile requires energy, dropping a tile releases energy as heat?
        //    - it doesn't actually end up being that much energy released
        //    - we will ignore the energy required to accelerate mass left/right, we only look at up/down.
        //    - we will eventually need an anti-entropy way to convert heat back into useful energy,
        //      or a method for energy to be added to / removed from the system. that's fine because
        //      we only care about conservation of energy, not entropy increasing.
        // + heat energy = mass * material's specific heat capacity * temperature
        // + chemical energy = mass * material's energy per unit mass
        // something like that
        return 0;
    }
};
const PathTarget = struct {
    pos: vec.by2i32,
    cost_msec: u32,
    pub const none: PathTarget = .{ .pos = @splat(std.math.maxInt(i32)), .cost_msec = std.math.maxInt(u32) };
    pub fn from(pos: vec.by2i32, size: vec.by2i32, msec: u32) PathTarget {
        const min: vec.by2i32 = .{ 0, 0 };
        if (@reduce(.Or, pos < min) or @reduce(.Or, pos >= size)) return .none;
        return .{ .pos = pos, .cost_msec = msec };
    }
    pub fn valid(self: PathTarget) bool {
        return self.cost_msec != std.math.maxInt(i32);
    }
};
const Path = struct {
    // up,left,down,right,
    bidi: [4]PathTarget,
};

fn checkFit(map: *Map, pos: vec.by2i32) bool {
    return true and
        !map.getFlag(pos + vec.by2i32{ 0, 1 }, .cannot_enter) and
        !map.getFlag(pos, .cannot_enter) and
        true;
}
fn checkStand(map: *Map, pos: vec.by2i32) bool {
    return map.getFlag(pos + vec.by2i32{ 0, -1 }, .can_stand);
}
fn checkStandAndFit(map: *Map, pos: vec.by2i32) bool {
    return checkStand(map, pos) and checkFit(map, pos);
}
const LeftRight = enum {
    left,
    right,
    fn get(self: @This()) i32 {
        return switch (self) {
            .left => -1,
            .right => 1,
        };
    }
};
const PathCfg = struct {
    walk_ms: u10 = 100,
    jump_ms: u10 = 400,
    climb_ms: u10 = 200,
    vault_ms: u10 = 700,
};
fn calculatePathfindEdgeLR(map: *Map, pos: vec.by2i32, lr: LeftRight, path_cfg: *const PathCfg) PathTarget {
    // todo: should try for stairs down/up? uses path_cfg.vault_ms
    const pos_one = pos + vec.by2i32{ lr.get(), 0 };
    if (!checkFit(map, pos_one)) return .none;
    if (checkStand(map, pos_one)) return .from(pos_one, map.size_int, path_cfg.walk_ms);
    const pos_two = pos + vec.by2i32{ lr.get() * 2, 0 };
    if (checkStandAndFit(map, pos_two)) return .from(pos_two, map.size_int, path_cfg.jump_ms);
    return .none;
}
fn calculatePathfindEdges(map: *Map, pos: vec.by2i32, path_cfg: *const PathCfg) Path {
    var result: Path = .{
        .bidi = @splat(.none),
    };
    if (!checkStandAndFit(map, pos)) {
        // can't be here
        return result;
    }
    const pos_up = pos + vec.by2i32{ 0, 1 };
    if (checkStandAndFit(map, pos_up)) {
        // down
        result.bidi[0] = .from(pos_up, map.size_int, path_cfg.climb_ms);
    }
    result.bidi[1] = calculatePathfindEdgeLR(map, pos, .left, path_cfg);
    const pos_down = pos + vec.by2i32{ 0, -1 };
    if (checkStandAndFit(map, pos_down)) {
        // down
        result.bidi[2] = .from(pos_down, map.size_int, path_cfg.climb_ms);
    }
    result.bidi[3] = calculatePathfindEdgeLR(map, pos, .right, path_cfg);

    return result;
}
const Pathfind = struct {
    map: *Map,
    cfg: *const PathCfg,
    queue: Queue,
    // TODO: measure, determine if these should be [MAP_SIZE[0] * MAP_SIZE[1]]T instead of AutoArrayHashMap
    came_from: std.AutoArrayHashMap(vec.by2i32, vec.by2i32),
    cost_so_far: std.AutoArrayHashMap(vec.by2i32, u64),

    fn init(map: *Map, src: vec.by2i32, path_cfg: *const PathCfg) !Pathfind {
        var pathfind: Pathfind = .{
            .cfg = path_cfg,
            .map = map,
            .queue = .init(map.gpa, .{}),
            .came_from = .init(map.gpa),
            .cost_so_far = .init(map.gpa),
        };
        errdefer pathfind.deinit();
        try pathfind.queue.add(.{
            .pos = src,
            .source_ms = 0,
        });
        try pathfind.came_from.putNoClobber(src, @splat(std.math.minInt(i32)));
        try pathfind.cost_so_far.putNoClobber(src, 0);

        return pathfind;
    }
    fn deinit(this: *Pathfind) void {
        this.queue.deinit();
        this.came_from.deinit();
        this.cost_so_far.deinit();
    }

    const Context = struct {
        const Child = struct {
            pos: vec.by2i32,
            source_ms: u64,
        };
        fn compare(_: Context, a: Child, b: Child) std.math.Order {
            return std.math.order(a.source_ms, b.source_ms);
        }
    };
    const Queue = std.PriorityQueue(Context.Child, Context, Context.compare);

    fn step(this: *Pathfind) !bool {
        const current = this.queue.removeOrNull() orelse return true;

        if (this.cost_so_far.get(current.pos)) |best_ms| {
            if (current.source_ms > best_ms) return false;
        }

        for (calculatePathfindEdges(this.map, current.pos, this.cfg).bidi) |next| {
            if (!next.valid()) continue;
            const new_cost = current.source_ms + next.cost_msec;
            const existing_cost = this.cost_so_far.get(next.pos);
            if (existing_cost == null or new_cost < existing_cost.?) {
                try this.cost_so_far.put(next.pos, new_cost);
                try this.queue.add(.{
                    .pos = next.pos,
                    .source_ms = new_cost,
                });
                try this.came_from.put(next.pos, current.pos);
            }
        }

        return false;
    }
};
fn pathfindPath(map: *Map, src: vec.by2i32, path_cfg: *const PathCfg) !void {
    var pathfind: Pathfind = try .init(map, src, path_cfg);
    defer pathfind.deinit();
    var steps: usize = 0;
    while (!try pathfind.step()) : (steps += 1) {}
}

const Player = struct {
    energy_millijoules: u64,
    contents: [4]Material,
};
const PlayerPool = zpool.Pool(16, 16, Player, struct { ptr: Player });

const TileFlags = packed struct(u32) {
    comptime {
        std.debug.assert(@sizeOf(TileFlags) * 8 == @bitSizeOf(TileFlags));
        std.debug.assert(std.meta.hasUniqueRepresentation(TileFlags));
    }
    cannot_enter: bool,
    can_stand: bool, // enter=false,stand=true means can climb. enter=false,stand=false = spikes or smth.
    /// indicates that the building on this tile has a power port
    port: enum(u2) { none, power, pipe, _ },
    /// indicates that the building on this tile has a pipe port
    has_building: bool,
    unused: u27 = 0,
    pub const empty: TileFlags = .{
        .cannot_enter = false,
        .can_stand = false,
        .port = .none,
        .has_building = false,
    };
};

const Wires = ConnectionLayer(struct {
    value: f64 = 0,
    pub fn canMergeWith(_: *const @This(), _: *const @This()) bool {
        return true; // TODO: based on wire type
    }
    pub fn serdes(comptime mode: util.SerializeDeserialize.Mode, sd: *mode.Value(), self: mode.In(*@This()), _: mode.Extra(GameSerializeExtra)) !mode.Out(@This()) {
        const value = try sd.value(f64, "value", if (comptime mode.in()) self.value);
        if (comptime mode.out()) return .{ .value = value };
    }
}, struct {
    map: *Map,
    pub fn hasIntrinsic(this: @This(), pos: vec.by2i32) bool {
        return this.map.getFlag(pos, .port) == .power;
    }
});
const Wire = Wires.Segment;

const Building = struct {
    tag: buildings.BuildingTag,
    center: vec.by2i32,
    data: ?*const anyopaque = null,

    // nil or not in pool indicates default priority.
    energy_priority: PriorityPool.Handle = .nil,
};
const BuildingInfo = struct {};
const BuildingPool = zpool.Pool(16, 16, Building, struct { ptr: Building });

const PriorityLevel = enum(u32) {
    min = 0,
    default = std.math.maxInt(i32), // half
    _,
};
const Priority = struct {
    name: []const u8,
};
const PriorityPool = zpool.Pool(16, 16, Priority, struct { ptr: Priority, level: PriorityLevel });

pub fn PoolSerdes(comptime Pool: type, comptime mode: util.SerializeDeserialize.Mode) type {
    return struct {
        const PS = @This();
        index: usize,
        count: usize,
        internal: switch (mode) {
            .count, .serialize => struct {
                handle_to_index_map: std.AutoArrayHashMapUnmanaged(Pool.Handle, void),
            },
            .deserialize => struct {
                index_to_handle_map: std.ArrayListUnmanaged(Pool.Handle),
                pool: Pool,
                ended: bool = false,
            },
        },

        pub fn begin(
            sd: *mode.Value(),
            name: []const u8,
            extra: mode.Extra(GameSerializeExtra),
            out: mode.In(*Pool),
        ) !PS {
            const count = try sd.value(usize, name, if (comptime mode.in()) out.liveHandleCount());
            switch (mode) {
                .count, .serialize => {
                    var result: PS = .{ .count = out.liveHandleCount(), .index = 0, .internal = .{ .handle_to_index_map = .empty } };
                    errdefer result.internal.handle_to_index_map.deinit(extra.gpa);
                    // iterate over pool, add to handle_to_index_map
                    var iter = out.liveHandles();
                    while (iter.next()) |handle| {
                        try result.internal.handle_to_index_map.putNoClobber(extra.gpa, handle, {});
                    }
                    return result;
                },
                .deserialize => {
                    var result: PS = .{ .count = count, .index = 0, .internal = .{ .index_to_handle_map = .empty, .pool = undefined } };
                    errdefer result.internal.index_to_handle_map.deinit(extra.gpa);
                    // initialize pool
                    result.internal.pool = try .initCapacity(extra.gpa, count);
                    errdefer result.internal.pool.deinit();
                    // fill index_to_handle_map
                    for (0..count) |index| {
                        const added_handle = try result.internal.pool.add(undefined);
                        std.debug.assert(result.internal.index_to_handle_map.items.len == index);
                        try result.internal.index_to_handle_map.append(extra.gpa, added_handle);
                    }
                    return result;
                },
            }
        }
        pub fn serdesHandle(
            self: *PS,
            sd: *mode.Value(),
            name: []const u8,
            extra: mode.Extra(GameSerializeExtra),
            v: mode.In(Pool.Handle),
        ) !mode.Out(Pool.Handle) {
            _ = extra;
            const index = try sd.value(u64, name, if (comptime mode.in()) blk: {
                if (self.internal.handle_to_index_map.getIndex(v)) |idx| {
                    break :blk idx + 1;
                } else {
                    break :blk 0;
                }
            });
            if (comptime mode.out()) {
                if (index == 0) return .nil;
                if (self.internal.index_to_handle_map.items.len < index - 1) return error.DeserializeError;
                return self.internal.index_to_handle_map.items[index - 1];
            }
        }
        // TODO: we could have this accept a column and return *Child that you either use or mutate
        pub fn serdesNext(self: *PS) ?Pool.Handle {
            if (self.index >= self.count) return null;
            defer self.index += 1;
            return switch (mode) {
                .count, .serialize => self.internal.handle_to_index_map.keys()[self.index],
                .deserialize => self.internal.index_to_handle_map.items[self.index],
            };
        }
        pub fn set(self: *PS, handle: Pool.Handle, value: Pool.Columns) void {
            comptime std.debug.assert(mode.out());
            self.internal.pool.setColumnsAssumeLive(handle, value);
        }
        pub fn end(self: *PS) !mode.Out(Pool) {
            std.debug.assert(self.index == self.count); // need to loop over serdesNext() before calling end
            if (comptime mode.out()) {
                std.debug.assert(!self.internal.ended);
                self.internal.ended = true;
                return self.internal.pool;
            }
        }
        pub fn deinit(self: *PS, extra: mode.Extra(GameSerializeExtra)) void {
            switch (mode) {
                .count, .serialize => self.internal.handle_to_index_map.deinit(extra.gpa),
                .deserialize => {
                    self.internal.index_to_handle_map.deinit(extra.gpa);
                    if (!self.internal.ended) self.internal.pool.deinit();
                },
            }
        }
    };
}

const Map = struct {
    gpa: std.mem.Allocator,
    size_int: vec.by2i32,
    size_usize: vec.by2usize,
    materials: Grid(3, i32, Material),
    tile_flags: Grid(2, i32, TileFlags),
    building_pool: BuildingPool,
    priority_pool: PriorityPool,
    pos_to_building: std.AutoArrayHashMapUnmanaged(vec.by2i32, BuildingPool.Handle),
    wires: Wires,
    creatures: PlayerPool,

    pub fn init(this: *Map, gpa: std.mem.Allocator) void {
        this.* = .{
            .size_int = @splat(0),
            .size_usize = @splat(0),
            .gpa = gpa,
            .materials = .empty,
            .tile_flags = .empty,
            .wires = .init(gpa),
            .creatures = .init(gpa),
            .pos_to_building = .empty,
            .building_pool = .init(gpa),
            .priority_pool = .init(gpa),
        };
    }
    pub fn deinit(this: *Map) void {
        this.materials.deinit(this.gpa);
        this.tile_flags.deinit(this.gpa);
        this.pos_to_building.deinit(this.gpa);
        this.building_pool.deinit();
        this.priority_pool.deinit();
        this.wires.deinit();
        this.creatures.deinit();
    }
    pub fn serdes(
        item: *Map,
        comptime mode: util.SerializeDeserialize.Mode,
        sd: *mode.Value(),
        extra: mode.Extra(GameSerializeExtra),
    ) !void {
        if (comptime mode.out()) item.gpa = extra.gpa;
        const size_int = try sd.value(math.vec2i32, "size_int", if (comptime mode.in()) item.size_int);
        const size_usize = try sd.value(math.vec2usize, "size_usize", if (comptime mode.in()) item.size_usize);

        var building_pool_handler: PoolSerdes(BuildingPool, mode) = try .begin(sd, "building_pool", extra, if (comptime mode.in()) &item.building_pool);
        defer building_pool_handler.deinit(extra);
        var priority_pool_handler: PoolSerdes(PriorityPool, mode) = try .begin(sd, "building_pool", extra, if (comptime mode.in()) &item.priority_pool);
        defer priority_pool_handler.deinit(extra);

        const materials_size = try sd.value(math.vec3usize, "materials.size", if (comptime mode.in()) item.materials.size);
        const materials_slice = try sd.sliceAutoLen(Material, "materials.items", if (comptime mode.in()) item.materials.items);

        // note that we can recreate tile_flags instead of saving it
        const tile_flags_size = try sd.value(math.vec2usize, "tile_flags.size", if (comptime mode.in()) item.tile_flags.size);
        const tile_flags_slice = try sd.sliceAutoLen(TileFlags, "tile_flags.items", if (comptime mode.in()) item.tile_flags.items);

        try sd.begin("building_pool.data");
        while (building_pool_handler.serdesNext()) |handle| {
            try sd.begin("Building");

            const building = if (comptime mode.in()) item.building_pool.getColumnPtrAssumeLive(handle, .ptr);
            const tag = try sd.value(buildings.BuildingTag, "tag", if (comptime mode.in()) building.tag);
            const center = try sd.value(math.vec2i32, "center", if (comptime mode.in()) building.center);
            const energy_priority = try priority_pool_handler.serdesHandle(sd, "energy_priority", extra, if (comptime mode.in()) building.energy_priority);

            if (comptime mode.out()) building_pool_handler.set(handle, .{ .ptr = .{
                .tag = tag,
                .center = center,
                .data = null,

                .energy_priority = energy_priority,
            } }); // maybe we should call placeBuilding here?
            try sd.end();
        }
        try sd.end();

        const building_pool = try building_pool_handler.end();

        try sd.begin("priority_pool.data");
        while (priority_pool_handler.serdesNext()) |handle| {
            try sd.begin("PriorityLevel");

            const level = try sd.value(PriorityLevel, "level", if (comptime mode.in()) item.getPriorityLevel(handle));
            if (comptime mode.out()) priority_pool_handler.set(handle, .{
                .ptr = .{ .name = "" },
                .level = level,
            });

            try sd.end();
        }
        try sd.end();
        const priority_pool = try priority_pool_handler.end();

        const wires = try Wires.serdes(mode, sd, if (comptime mode.in()) &item.wires, extra.gpa);

        // so for serializing those lists we will have to loop over the lists probably
        // and then for serializing the pools we have to decide:
        // - we can reindex them, by keeping a pool reindexer hashmap
        // - step 1: first, we iterate the pool to assign indices to every pool handle in order. it returns a pool indexer struct.
        // - step 2:
        //   - when we serialize a handle, we take the pool indexer struct. it says handle -> index, or index -> handle
        //   -

        if (comptime mode.out()) item.* = .{
            .gpa = extra.gpa,
            .size_int = size_int,
            .size_usize = size_usize,
            .materials = .fromSizeSlice(materials_size, try dupeMisaligned(extra.gpa, Material, materials_slice)),
            .tile_flags = .fromSizeSlice(tile_flags_size, try dupeMisaligned(extra.gpa, TileFlags, tile_flags_slice)),
            .priority_pool = priority_pool,
            .building_pool = building_pool,
            .wires = wires,

            // TODO: generate this based on building_pool
            .pos_to_building = .empty,
            // TODO
            .creatures = .init(extra.gpa),
        };
    }
    fn dupeMisaligned(allocator: std.mem.Allocator, comptime T: type, m: []align(1) const T) ![]T {
        const res = try allocator.alloc(T, m.len);
        @memcpy(res, m);
        return res;
    }
    pub fn getPriorityLevel(this: *Map, priority: PriorityPool.Handle) PriorityLevel {
        return this.priority_pool.getColumn(priority, .level) catch return .default;
    }
    pub fn generate(this: *Map, size: vec.by2usize) !void {
        this.size_int = @intCast(size);
        this.size_usize = size;
        try this.materials.resize(this.gpa, .{ size[0], size[1], MAP_NLAYERS });
        this.materials.fill(.empty);
        try this.tile_flags.resize(this.gpa, size);
        this.tile_flags.fill(.empty);

        const sizei = this.size_int;

        // fill floor and ceiling
        for (0..size[0]) |x| {
            const xi: i32 = @intCast(x);
            _ = this.materials.set(.{ xi, 0, Layers.tile.int() }, .unobtanium);
            if (this.tile_flags.ptr(.{ xi, 0 })) |f| f.can_stand = true;
            if (this.tile_flags.ptr(.{ xi, 0 })) |f| f.cannot_enter = true;
            _ = this.materials.set(.{ xi, sizei[1] - 1, Layers.tile.int() }, .unobtanium);
            if (this.tile_flags.ptr(.{ xi, sizei[1] - 1 })) |f| f.can_stand = true;
            if (this.tile_flags.ptr(.{ xi, 0 })) |f| f.cannot_enter = true;
        }
    }
    pub fn measureEnergy(this: *Map) u128 {
        // returns the total energy of the system
        _ = this;
        return 0;
    }
    fn recalculatePipeWireMaterialRange(this: *Map, fromPos: vec.by2i32, toPos: vec.by2i32) !void {
        std.debug.assert(@reduce(.And, fromPos <= toPos));
        var y: i32 = fromPos[1];
        while (y <= toPos[1]) : (y += 1) {
            var x: i32 = fromPos[0];
            while (x <= toPos[0]) : (x += 1) {
                try this.recalculatePipeWireMaterial(.{ x, y });
            }
        }
    }
    fn recalculatePipeWireMaterial(this: *Map, pos: vec.by2i32) !void {
        // recomputes the pipe/wire material at the tile
        // TODO: redo this
        const has_wire = this.wires.coordinate_to_segments_map.getPtr(pos) != null;
        _ = this.materials.set(.{ pos[0], pos[1], Layers.wires_and_pipes.int() }, Material{
            .material = if (has_wire) .other else .none,
            .mass_milligrams = if (has_wire) 5_000 else 0, // TODO: sum the mass of the wires. TODO: we need to take the existing mass to determine the new mass, and add any added mass
            .temperature_millikelvin = if (has_wire) 298_150 else 0, // TODO: take the existing temperature from this.materials and remove or add the new wire
        });
    }
    fn generateWireGraph() void {
        // TODO:
        // - for each wire:
        //   - add a vertex at both sides (keep a map of pos -> vertex index, never add the same position twice)
        //   - add an edge from side[0] to side[1]
    }

    pub fn createWire(this: *@This(), wire: Wire) !void {
        try this.wires.createSegment(.{ .map = this }, wire);
        try this.recalculatePipeWireMaterialRange(wire.sides[0], wire.sides[1]);
    }

    fn getFlag(this: *Map, pos: vec.by2i32, comptime flag: std.meta.FieldEnum(TileFlags)) @FieldType(TileFlags, @tagName(flag)) {
        const value = this.tile_flags.get(pos) orelse TileFlags.empty;
        return @field(value, @tagName(flag));
    }
    fn setFlag(this: *Map, pos: vec.by2i32, comptime flag: std.meta.FieldEnum(TileFlags), value: @FieldType(TileFlags, @tagName(flag))) void {
        var ptr = this.tile_flags.ptr(pos) orelse return;
        @field(ptr, @tagName(flag)) = value;
    }

    fn canPlaceBuilding(this: *Map, building: Building) PlaceBuildingStatus {
        const descriptor = buildings.building_to_descriptor_map.getPtrConst(building.tag);
        var range = vec.Iterator(2, i32).size(@intCast(descriptor.grid.size));
        var result: PlaceBuildingStatus = .{ .pos = building.center, .status = .success };
        while (range.next()) |subpos| {
            const index = descriptor.grid.get(subpos).?;
            const expected = descriptor.flags[index];
            const pos = building.center - descriptor.offset + subpos;
            const actual = this.tile_flags.get(pos) orelse return .{ .pos = pos, .status = .error_out_of_bounds };

            if (expected.set_building and actual.has_building) {
                return .{ .pos = pos, .status = .error_has_building };
            }
            if (expected.set_power_port and actual.port != .none) {
                return .{ .pos = pos, .status = .error_overlapping_port };
            }
            if (expected.needs_tile and !actual.cannot_enter) {
                result = .{ .pos = pos, .status = .warning_missing_tile };
            }
        }
        return result; // success
    }
    fn placeBuilding(this: *Map, building: Building) !BuildingPool.Handle {
        const status = this.canPlaceBuilding(building);
        std.debug.assert(status.ok()); // you're supposed to make sure it can be placed first

        const placed_id = try this.building_pool.add(.{ .ptr = building });

        const descriptor = buildings.building_to_descriptor_map.getPtrConst(building.tag);
        var range = vec.Iterator(2, i32).size(@intCast(descriptor.grid.size));
        while (range.next()) |subpos| {
            const index = descriptor.grid.get(subpos).?;
            const expected = descriptor.flags[index];
            const pos = building.center - descriptor.offset + subpos;
            const actual = this.tile_flags.ptr(pos) orelse unreachable;

            if (expected.set_building) {
                std.debug.assert(!actual.has_building);
                actual.has_building = true;
                try this.pos_to_building.putNoClobber(this.gpa, pos, placed_id);
            }
            if (expected.set_power_port) {
                std.debug.assert(actual.port == .none);
                actual.port = .power;
                try this.wires.syncSegments(.{ .map = this }, pos);
            }
        }

        return placed_id;
    }
    fn removeBuilding(this: *Map, building_id: BuildingPool.Handle) !void {
        const building: Building = this.building_pool.getColumnAssumeLive(building_id, .ptr);

        const descriptor = buildings.building_to_descriptor_map.getPtrConst(building.tag);
        var range = vec.Iterator(2, i32).size(@intCast(descriptor.grid.size));
        while (range.next()) |subpos| {
            const index = descriptor.grid.get(subpos).?;
            const expected = descriptor.flags[index];
            const pos = building.center - descriptor.offset + subpos;
            const actual = this.tile_flags.ptr(pos) orelse unreachable;

            if (expected.set_building) {
                std.debug.assert(actual.has_building);
                actual.has_building = false;
                std.debug.assert(this.pos_to_building.swapRemove(pos));
            }
            if (expected.set_power_port) {
                std.debug.assert(actual.port == .power);
                actual.port = .none;
                try this.wires.syncSegments(.{ .map = this }, pos);
            }
        }

        this.building_pool.removeAssumeLive(building_id);
    }
};

const PlaceBuildingStatus = struct {
    pos: @Vector(2, i32),
    status: enum {
        success,
        warning_missing_tile,
        error_has_building,
        error_overlapping_port,
        error_out_of_bounds,
    },
    fn ok(self: PlaceBuildingStatus) bool {
        return switch (self.status) {
            .success, .warning_missing_tile => true,
            else => false,
        };
    }
};
pub const Image = struct {
    world: math.Rect(2, f32),
    spritesheet: math.Rect(2, f32),
};

test Map {
    std.testing.log_level = .info;
    var map_raw: Map = undefined;
    map_raw.init(std.testing.allocator);
    defer map_raw.deinit();
    const map = &map_raw;
    try map.generate(.{ 200, 300 });

    const path = calculatePathfindEdges(map, .{ @divTrunc(map.size_int[0], 2), 1 }, &.{});
    try print.snapshotPrint(&path).snap(@src(),
        \\*: struct:
        \\ bidi: [4]:
        \\  0: struct:
        \\   pos: .{ maxInt(i32), maxInt(i32) }
        \\   cost_msec: maxInt(u32)
        \\  1: struct:
        \\   pos: .{ 99, 1 }
        \\   cost_msec: 100
        \\  2: struct:
        \\   pos: .{ maxInt(i32), maxInt(i32) }
        \\   cost_msec: maxInt(u32)
        \\  3: struct:
        \\   pos: .{ 101, 1 }
        \\   cost_msec: 100
    );

    try pathfindPath(map, .{ 50, 1 }, &.{});

    // add some wires
    try map.createWire(.{
        .sides = .{
            .{ 10, 10 },
            .{ 10, 15 },
        },
        .user = .{},
    });

    try print.snapshotPrint(&map.wires).snap(@src(),
        \\*: ConnectionLayer:
        \\ { 10, 10 } <--> { 10, 15 }: struct: (no fields)
    );

    // extend the wire
    try map.createWire(.{
        .sides = .{
            .{ 10, 15 },
            .{ 10, 20 },
        },
        .user = .{},
    });

    try print.snapshotPrint(&map.wires).snap(@src(),
        \\*: ConnectionLayer:
        \\ { 10, 10 } <--> { 10, 20 }: struct: (no fields)
    );

    // split the wire
    try map.createWire(.{
        .sides = .{
            .{ 10, 15 },
            .{ 30, 15 },
        },
        .user = .{},
    });

    try print.snapshotPrint(&map.wires).snap(@src(),
        \\*: ConnectionLayer:
        \\ { 10, 10 } <--> { 10, 15 }: struct: (no fields)
        \\ { 10, 15 } <--> { 30, 15 }: struct: (no fields)
        \\ { 10, 15 } <--> { 10, 20 }: struct: (no fields)
    );

    // don't merge with power port
    map.setFlag(.{ 30, 15 }, .port, .power);
    try map.createWire(.{
        .sides = .{
            .{ 30, 15 },
            .{ 45, 15 },
        },
        .user = .{},
    });

    try print.snapshotPrint(&map.wires).snap(@src(),
        \\*: ConnectionLayer:
        \\ { 10, 10 } <--> { 10, 15 }: struct: (no fields)
        \\ { 10, 15 } <--> { 30, 15 }: struct: (no fields)
        \\ { 30, 15 } <--> { 45, 15 }: struct: (no fields)
        \\ { 10, 15 } <--> { 10, 20 }: struct: (no fields)
    );

    // merge when the power port is removed
    map.setFlag(.{ 30, 15 }, .port, .none);
    try map.wires.syncSegments(.{ .map = map }, .{ 30, 15 });

    try print.snapshotPrint(&map.wires).snap(@src(),
        \\*: ConnectionLayer:
        \\ { 10, 10 } <--> { 10, 15 }: struct: (no fields)
        \\ { 10, 15 } <--> { 45, 15 }: struct: (no fields)
        \\ { 10, 15 } <--> { 10, 20 }: struct: (no fields)
    );

    // add a wire that goes through the end point of another wire (it should split)
    try map.createWire(.{
        .sides = .{ .{ 45, 10 }, .{ 45, 20 } },
        .user = .{},
    });

    // add a wire that intersects the end point of the left-right wire. it should split in half.
    try print.snapshotPrint(&map.wires).snap(@src(),
        \\*: ConnectionLayer:
        \\ { 10, 10 } <--> { 10, 15 }: struct: (no fields)
        \\ { 45, 10 } <--> { 45, 15 }: struct: (no fields)
        \\ { 10, 15 } <--> { 45, 15 }: struct: (no fields)
        \\ { 10, 15 } <--> { 10, 20 }: struct: (no fields)
        \\ { 45, 15 } <--> { 45, 20 }: struct: (no fields)
    );

    // can place but missing tile
    try print.snapshotPrint(map.canPlaceBuilding(.{
        .tag = .generator,
        .center = .{ 30, 15 },
    })).snap(@src(),
        \\struct:
        \\ pos: .{ 31, 14 }
        \\ status: .warning_missing_tile
    );

    const placed = try map.placeBuilding(.{
        .tag = .generator,
        .center = .{ 30, 15 },
    });

    // can't place again, there's already a building there
    try print.snapshotPrint(map.canPlaceBuilding(.{
        .tag = .generator,
        .center = .{ 30, 15 },
    })).snap(@src(),
        \\struct:
        \\ pos: .{ 29, 15 }
        \\ status: .error_has_building
    );

    // placing the building should have split the layer in half
    try print.snapshotPrint(&map.wires).snap(@src(),
        \\*: ConnectionLayer:
        \\ { 10, 10 } <--> { 10, 15 }: struct: (no fields)
        \\ { 45, 10 } <--> { 45, 15 }: struct: (no fields)
        \\ { 10, 15 } <--> { 31, 15 }: struct: (no fields)
        \\ { 31, 15 } <--> { 45, 15 }: struct: (no fields)
        \\ { 10, 15 } <--> { 10, 20 }: struct: (no fields)
        \\ { 45, 15 } <--> { 45, 20 }: struct: (no fields)
    );

    try map.removeBuilding(placed);

    // un-split
    try print.snapshotPrint(&map.wires).snap(@src(),
        \\*: ConnectionLayer:
        \\ { 10, 10 } <--> { 10, 15 }: struct: (no fields)
        \\ { 45, 10 } <--> { 45, 15 }: struct: (no fields)
        \\ { 10, 15 } <--> { 45, 15 }: struct: (no fields)
        \\ { 10, 15 } <--> { 10, 20 }: struct: (no fields)
        \\ { 45, 15 } <--> { 45, 20 }: struct: (no fields)
    );

    // can place again
    try print.snapshotPrint(map.canPlaceBuilding(.{
        .tag = .generator,
        .center = .{ 30, 15 },
    })).snap(@src(),
        \\struct:
        \\ pos: .{ 31, 14 }
        \\ status: .warning_missing_tile
    );
}

test {
    _ = @import("power.zig");
    _ = @import("pressure.zig");
}
