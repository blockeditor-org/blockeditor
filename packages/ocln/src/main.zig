const std = @import("std");

const vec2i32 = @Vector(2, i32);
const vec2usize = @Vector(2, usize);

const MAP_SIZE: vec2usize = .{ 200, 300 };

const TileMaterial = enum {
    none,
    unobtanium,
    dirt,
    stone,
    shelf,

    fn canStandOn(mat: TileMaterial) bool {
        return switch (mat) {
            .none => false,
            .unobtanium => true,
            .dirt => true,
            .stone => true,
            .shelf => true,
        };
    }
    fn canStandIn(mat: TileMaterial) bool {
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
pub const zero_mc_in_mk = 273150000;
pub const Tile = struct {
    material: TileMaterial,
    mass_mg: u64,
    temperature_mk: u64,
    pub const empty: Tile = .{
        .material = .none,
        .mass_mg = 0,
        .temperature_mk = 0,
    };
    pub const unobtanium: Tile = .{
        .material = .unobtanium,
        .mass_mg = 2000 * milli_per_kilo,
        .temperature_mk = zero_mc_in_mk,
    };

    pub fn energy(this: *const Tile) u128 {
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
        map.get(pos + vec2i32{ 0, 1 }).material.canStandIn() and
        map.get(pos).material.canStandIn() and
        true;
}
fn checkStand(map: *Map, pos: vec2i32) bool {
    return map.get(pos + vec2i32{ 0, -1 }).material.canStandOn();
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
    jump_ms: u10 = 300,
    climb_ms: u10 = 200,
    vault_ms: u10 = 700,
};
fn calculatePathLR(map: *Map, pos: vec2i32, lr: LeftRight, path_cfg: *const PathCfg) PathTarget {
    // todo: should try for stairs down/up? uses path_cfg.vault_ms
    const pos_one = pos + vec2i32{ lr.get(), 0 };
    if (!checkFit(map, pos_one)) return .none;
    if (checkStand(map, pos_one)) return .from(pos_one, path_cfg.walk_ms);
    const pos_two = pos + vec2i32{ lr.get() * 2, 0 };
    if (checkStandAndFit(map, pos_two)) return .from(pos_two, path_cfg.jump_ms);
    return .none;
}
fn calculatePath(map: *Map, pos: vec2i32, path_cfg: *const PathCfg) Path {
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
    result.bidi[1] = calculatePathLR(map, pos, .left, path_cfg);
    const pos_down = pos + vec2i32{ 0, -1 };
    if (checkStandAndFit(map, pos_down)) {
        // down
        result.bidi[2] = .from(pos_down, path_cfg.climb_ms);
    }
    result.bidi[3] = calculatePathLR(map, pos, .right, path_cfg);

    return result;
}
const Pathfind = struct {
    map: *Map,
    cfg: *const PathCfg,
    queue: Queue,
    // these should probably be [MAP_SIZE[0] * MAP_SIZE[1]]T instead of AutoArrayHashMap
    came_from: std.AutoArrayHashMap(vec2i32, vec2i32),
    cost_so_far: std.AutoArrayHashMap(vec2i32, u64),
    steps: usize,

    fn init(map: *Map, src: vec2i32, dst: vec2i32, path_cfg: *const PathCfg) !Pathfind {
        var pathfind: Pathfind = .{
            .cfg = path_cfg,
            .map = map,
            .queue = .init(map.gpa, .{ .dst = dst }),
            .came_from = .init(map.gpa),
            .cost_so_far = .init(map.gpa),
            .steps = 0,
        };
        errdefer pathfind.deinit();
        try pathfind.queue.add(src);
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
        // TODO: this is wrong. child needs to be struct {pos: vec2i32, heuristic: usize}
        const Child = vec2i32;
        dst: vec2i32,
        fn heuristic(ctx: Context, a: Child) i32 {
            return @reduce(.Add, @as(vec2i32, @intCast(@abs(ctx.dst - a))));
        }
        fn compare(ctx: Context, a: Child, b: Child) std.math.Order {
            return std.math.order(ctx.heuristic(a), ctx.heuristic(b));
        }
    };
    const Queue = std.PriorityQueue(Context.Child, Context, Context.compare);

    fn step(this: *Pathfind) !bool {
        while (this.queue.removeOrNull()) |current| {
            this.steps += 1;
            if (@reduce(.And, current == this.queue.context.dst)) return false;

            for (calculatePath(this.map, current, this.cfg).bidi) |next| {
                if (!next.valid()) continue;
                const new_cost = this.cost_so_far.get(current).? + next.cost_msec;
                const next_cost = this.cost_so_far.get(next.pos);
                if (next_cost == null or new_cost < next_cost.?) {
                    try this.cost_so_far.put(next.pos, new_cost);
                    try this.queue.add(next.pos); // TODO: this is wrong, priority should be new_cost + heuristicMs(next, goal)
                    try this.came_from.put(next.pos, current);
                }
            }
        }
        return false;
    }
};
fn pathfindPath(map: *Map, src: vec2i32, dst: vec2i32, path_cfg: *const PathCfg) !void {
    // for no-path detection we ought to do https://en.wikipedia.org/wiki/Connected-component_labeling
    // ideally, updating when a tile updates rather than every frame if that's something that can be done.
    var pathfind: Pathfind = try .init(map, src, dst, path_cfg);
    defer pathfind.deinit();
    while (try pathfind.step()) {}
    std.log.err("found path in {d} steps", .{pathfind.steps});
}

const Map = struct {
    gpa: std.mem.Allocator,
    tiles: []Tile,

    pub fn init(this: *Map, gpa: std.mem.Allocator) !void {
        const tiles = try gpa.alloc(Tile, MAP_SIZE[0] * MAP_SIZE[1]);
        @memset(tiles, .empty);
        this.* = .{
            .gpa = gpa,
            .tiles = tiles,
        };
    }
    pub fn deinit(this: *Map) void {
        this.gpa.free(this.tiles);
    }
    pub fn get(this: *Map, pos: vec2i32) Tile {
        const min: vec2i32 = .{ 0, 0 };
        const max: vec2i32 = @intCast(MAP_SIZE);
        if (@reduce(.Or, pos < min) or @reduce(.Or, pos >= max)) return .empty;
        const cast: vec2usize = @intCast(pos);
        return this.tiles[cast[1] * MAP_SIZE[0] + cast[0]];
    }
    pub fn set(this: *Map, pos: vec2i32, value: Tile) void {
        const min: vec2i32 = .{ 0, 0 };
        const max: vec2i32 = @intCast(MAP_SIZE);
        if (@reduce(.Or, pos < min) or @reduce(.Or, pos >= max)) return;
        const cast: vec2usize = @intCast(pos);
        this.tiles[cast[1] * MAP_SIZE[0] + cast[0]] = value;
    }
    pub fn generate(this: *Map) void {
        // fill floor and ceiling
        for (0..MAP_SIZE[0]) |x| {
            this.set(.{ @intCast(x), 0 }, .unobtanium);
            this.set(.{ @intCast(x), @intCast(MAP_SIZE[1] - 1) }, .unobtanium);
        }
    }
    pub fn measureEnergy(this: *Map) u128 {
        // returns the total energy of the system
        _ = this;
        return 0;
    }
};

test Map {
    var map_raw: Map = undefined;
    try map_raw.init(std.testing.allocator);
    defer map_raw.deinit();
    const map = &map_raw;
    map.generate();

    const path = calculatePath(map, .{ MAP_SIZE[0] / 2, 1 }, &.{});
    std.log.err("got path:", .{});
    {
        var buffer: [64]u8 = undefined;
        const stderr = std.debug.lockStderrWriter(&buffer);
        defer std.debug.unlockStderrWriter();
        @import("print.zig").print(stderr, path, &.{ .tty = .detect(std.fs.File.stderr()) }) catch {};
        stderr.writeByte('\n') catch {};
    }

    try pathfindPath(map, .{ 50, 1 }, .{ 25, 2 }, &.{});
}
