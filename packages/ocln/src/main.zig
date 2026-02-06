const std = @import("std");
const anywhere = @import("anywhere");
const util = anywhere.util;
const math = util.math;
const Grid = anywhere.util.grid.Grid;
const zpool = anywhere.util.zpool;
const printer = @import("print.zig");
const loadimage = @import("loadimage");

const Beui = @import("beui").Beui;
const B2 = Beui.beui_experiment;

const App = @This();
gpa: std.mem.Allocator,
game: Game,
interface: Interface = .{},
art: ?*B2.ImageCache.Image,
pub fn init(self: *App, gpa: std.mem.Allocator) void {
    self.* = .{ .gpa = gpa, .game = undefined, .art = null };
    self.game.init(gpa);
    self.game.map.generate();
}
pub fn deinit(self: *App) void {
    self.game.deinit();
    if (self.art) |art| art.destroy(self.gpa);
}
pub fn render(self: *App, call_id: B2.ID) *B2.RepositionableDrawList {
    const b2 = call_id.b2;
    const rdl = call_id.b2.draw();
    const frame_size = b2.frame.frame_cfg.size;

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
    var vertices = std.ArrayList(B2.render_list.RenderListVertex).empty;
    defer vertices.deinit(self.gpa);
    var indices = std.ArrayList(B2.render_list.RenderListIndex).empty;
    defer indices.deinit(self.gpa);
    for (0..MAP_SIZE[1]) |y| {
        for (0..MAP_SIZE[0]) |x| {
            const posint: @Vector(2, i32) = @intCast(@Vector(2, usize){ x, y });
            const pos: @Vector(2, f32) = @floatFromInt(posint);
            const uv = b2.persistent.image_cache.getImageUVOnRenderFromRdl(self.art.?);
            const tile = self.game.map.tiles.get(posint);

            const rect_pos: math.vec2f32 = pos * @as(math.vec2f32, @splat(self.interface.camera.scale)) + self.interface.camera.offset;
            const rect_size: math.vec2f32 = .{ 14, 14 };
            const uv_pos: math.vec2f32 = uv.pos + (getTileOffset(tile.material) / math.vec2f32{ 256.0, 256.0 }) * uv.size;
            const uv_size: math.vec2f32 = uv.size * (math.vec2f32{ 14.0 / 256.0, 14.0 / 256.0 });

            const ul = rect_pos;
            const ur = rect_pos + math.vec2f32{ rect_size[0], 0 };
            const bl = rect_pos + math.vec2f32{ 0, rect_size[1] };
            const br = rect_pos + rect_size;

            const uv_ul = uv_pos;
            const uv_ur = uv_pos + math.vec2f32{ uv_size[0], 0 };
            const uv_bl = uv_pos + math.vec2f32{ 0, uv_size[1] };
            const uv_br = uv_pos + uv_size;

            if (vertices.items.len + 3 >= std.math.maxInt(B2.render_list.RenderListIndex)) {
                // need to commit
                rdl.addVertices(.rgba, vertices.items, indices.items);
                vertices.clearRetainingCapacity();
                indices.clearRetainingCapacity();
            }
            const ib: B2.render_list.RenderListIndex = @intCast(vertices.items.len);
            vertices.appendSlice(self.gpa, &.{
                .{ .pos = ul, .uv = uv_ul, .tint = Beui.Color.fromHexRgb(0xFFFFFF).value, .circle = .{ 0, 0 } },
                .{ .pos = ur, .uv = uv_ur, .tint = Beui.Color.fromHexRgb(0xFFFFFF).value, .circle = .{ 0, 0 } },
                .{ .pos = bl, .uv = uv_bl, .tint = Beui.Color.fromHexRgb(0xFFFFFF).value, .circle = .{ 0, 0 } },
                .{ .pos = br, .uv = uv_br, .tint = Beui.Color.fromHexRgb(0xFFFFFF).value, .circle = .{ 0, 0 } },
            }) catch @panic("oom");
            indices.appendSlice(self.gpa, &.{
                ib + 0, ib + 1, ib + 3,
                ib + 0, ib + 3, ib + 2,
            }) catch @panic("oom");
        }
    }
    rdl.addVertices(.rgba, vertices.items, indices.items);

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

fn onMouseEvent(self: *App, b2: *B2.Beui2, ev: B2.MouseEvent) ?Beui.Cursor {
    // std.log.info("onMouseEvent: {f}", .{printer.autoPrint(ev)});
    if (ev.action == .move_while_down or ev.action == .up) {
        self.interface.camera.offset += ev.offset;
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

const Interface = struct {
    camera: struct {
        offset: @Vector(2, f32) = @splat(0),
        scale: f32 = 14,
    } = .{},

    pub fn serdes(item: *Interface, comptime mode: util.SerializeDeserialize, value: *util.SerializeDeserialize.Value(mode)) void {
        item.camera.scale = value.unique(f32, &item.camera.scale);
        item.camera.offset[0] = value.unique(f32, &item.camera.offset[0]);
        item.camera.offset[1] = value.unique(f32, &item.camera.offset[1]);
    }
};

fn getTileOffset(material: MaterialTag) @Vector(2, f32) {
    return switch (material) {
        .none => .{ 1, 1 },
        .unobtanium => .{ 65, 1 },
        .stone => .{ 17, 1 },
        .shelf => .{ 33, 1 },
        else => .{ 49, 1 },
    };
}

const Game = struct {
    map: Map,
    pub fn init(game: *Game, gpa: std.mem.Allocator) void {
        game.* = .{ .map = undefined };
        game.map.init(gpa) catch @panic("oom");
    }
    pub fn deinit(game: *Game) void {
        game.map.deinit();
    }
};

// https://en.wikipedia.org/wiki/Connected-component_labeling

// in recipes:
// - conserve energy. input energy = output energy
// - mass is basically conserved even when heat is released. the lost mass is very small.
//   we will probably not make recipes release heat then.

// wire resolution: make a big graph and then simplify it. then send it to wires

const vec2i32 = @Vector(2, i32);
const vec2usize = @Vector(2, usize);

const MAP_SIZE: vec2usize = .{ 200, 300 };

const MaterialTag = enum {
    none,
    unobtanium,
    dirt,
    stone,
    shelf,

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
pub const Material = struct {
    material: MaterialTag,
    mass_milligrams: u64,
    temperature_millikelvin: u64,
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
    pos: vec2i32,
    cost_msec: u32,
    pub const none: PathTarget = .{ .pos = @splat(std.math.maxInt(i32)), .cost_msec = std.math.maxInt(i32) };
    pub fn from(pos: vec2i32, msec: u32) PathTarget {
        const min: vec2i32 = .{ 0, 0 };
        const max: vec2i32 = @intCast(MAP_SIZE);
        if (@reduce(.Or, pos < min) or @reduce(.Or, pos >= max)) return .none;
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

fn checkFit(map: *Map, pos: vec2i32) bool {
    return true and
        map.tiles.get(pos + vec2i32{ 0, 1 }).material.canStandIn() and
        map.tiles.get(pos).material.canStandIn() and
        true;
}
fn checkStand(map: *Map, pos: vec2i32) bool {
    return map.tiles.get(pos + vec2i32{ 0, -1 }).material.canStandOn();
}
fn checkStandAndFit(map: *Map, pos: vec2i32) bool {
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
fn calculatePathfindEdgeLR(map: *Map, pos: vec2i32, lr: LeftRight, path_cfg: *const PathCfg) PathTarget {
    // todo: should try for stairs down/up? uses path_cfg.vault_ms
    const pos_one = pos + vec2i32{ lr.get(), 0 };
    if (!checkFit(map, pos_one)) return .none;
    if (checkStand(map, pos_one)) return .from(pos_one, path_cfg.walk_ms);
    const pos_two = pos + vec2i32{ lr.get() * 2, 0 };
    if (checkStandAndFit(map, pos_two)) return .from(pos_two, path_cfg.jump_ms);
    return .none;
}
fn calculatePathfindEdges(map: *Map, pos: vec2i32, path_cfg: *const PathCfg) Path {
    var result: Path = .{
        .bidi = @splat(.none),
    };
    if (!checkStandAndFit(map, pos)) {
        // can't be here
        return result;
    }
    const pos_up = pos + vec2i32{ 0, 1 };
    if (checkStandAndFit(map, pos_up)) {
        // down
        result.bidi[0] = .from(pos_up, path_cfg.climb_ms);
    }
    result.bidi[1] = calculatePathfindEdgeLR(map, pos, .left, path_cfg);
    const pos_down = pos + vec2i32{ 0, -1 };
    if (checkStandAndFit(map, pos_down)) {
        // down
        result.bidi[2] = .from(pos_down, path_cfg.climb_ms);
    }
    result.bidi[3] = calculatePathfindEdgeLR(map, pos, .right, path_cfg);

    return result;
}
const Pathfind = struct {
    map: *Map,
    cfg: *const PathCfg,
    queue: Queue,
    // TODO: measure, determine if these should be [MAP_SIZE[0] * MAP_SIZE[1]]T instead of AutoArrayHashMap
    came_from: std.AutoArrayHashMap(vec2i32, vec2i32),
    cost_so_far: std.AutoArrayHashMap(vec2i32, u64),

    fn init(map: *Map, src: vec2i32, path_cfg: *const PathCfg) !Pathfind {
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
            pos: vec2i32,
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
fn pathfindPath(map: *Map, src: vec2i32, path_cfg: *const PathCfg) !void {
    var pathfind: Pathfind = try .init(map, src, path_cfg);
    defer pathfind.deinit();
    var steps: usize = 0;
    while (!try pathfind.step()) : (steps += 1) {}
}

const Player = struct {
    energy_millijoules: u64,
    contents: [4]Material,
};
const PlayerPool = zpool.Pool(16, 16, Player, struct {
    ptr: Player,
});
const Map = struct {
    gpa: std.mem.Allocator,
    tiles: Grid(Material),
    players: PlayerPool,

    pub fn init(this: *Map, gpa: std.mem.Allocator) !void {
        const tiles: Grid(Material) = try .init(gpa, MAP_SIZE);
        errdefer tiles.deinit(gpa);
        @memset(tiles.items, .empty);
        this.* = .{
            .gpa = gpa,
            .tiles = tiles,
            .players = .init(gpa),
        };
    }
    pub fn deinit(this: *Map) void {
        this.tiles.deinit(this.gpa);
        this.players.deinit();
    }
    pub fn generate(this: *Map) void {
        // fill floor and ceiling
        for (0..MAP_SIZE[0]) |x| {
            this.tiles.set(.{ @intCast(x), 0 }, .unobtanium);
            this.tiles.set(.{ @intCast(x), @intCast(MAP_SIZE[1] - 1) }, .unobtanium);
        }
    }
    pub fn measureEnergy(this: *Map) u128 {
        // returns the total energy of the system
        _ = this;
        return 0;
    }
};

test Map {
    std.testing.log_level = .info;
    var map_raw: Map = undefined;
    try map_raw.init(std.testing.allocator);
    defer map_raw.deinit();
    const map = &map_raw;
    map.generate();

    const path = calculatePathfindEdges(map, .{ MAP_SIZE[0] / 2, 1 }, &.{});
    try anywhere.util.testing.snap(@src(), printer.snapshotPrint(&path),
        \\*: main.Path:
        \\ bidi: [4]main.PathTarget:
        \\  0: main.PathTarget:
        \\   pos: .{ 2147483647, 2147483647 }
        \\   cost_msec: 2147483647
        \\  1: main.PathTarget:
        \\   pos: .{ 99, 1 }
        \\   cost_msec: 100
        \\  2: main.PathTarget:
        \\   pos: .{ 2147483647, 2147483647 }
        \\   cost_msec: 2147483647
        \\  3: main.PathTarget:
        \\   pos: .{ 101, 1 }
        \\   cost_msec: 100
    );

    try pathfindPath(map, .{ 50, 1 }, &.{});
}

test {
    _ = @import("power.zig");
}
