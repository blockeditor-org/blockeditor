const std = @import("std");

// https://en.wikipedia.org/wiki/Connected-component_labeling

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
    // note: fast-travel methods may end up getting skipped if these values are set too high. should be rare though.
    // for perfect pathfinding, these values must always be the fastest possible speed the entity can travel at, including
    // using a fast-travel method
    min_horiz_ms: u10 = 100,
    min_vert_ms: u10 = 200,

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
    dst: vec2i32,
    // wonder if this could support pathfinding to the nearest item of N by having the heuristic select the nearest one
    // rather than having to re-pathfind N times

    fn init(map: *Map, src: vec2i32, dst: vec2i32, path_cfg: *const PathCfg) !Pathfind {
        var pathfind: Pathfind = .{
            .cfg = path_cfg,
            .map = map,
            .queue = .init(map.gpa, .{}),
            .came_from = .init(map.gpa),
            .cost_so_far = .init(map.gpa),
            .dst = dst,
        };
        errdefer pathfind.deinit();
        try pathfind.queue.add(.{
            .pos = src,
            .source_plus_heuristic_ms = pathfind.heuristicMs(src),
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
            source_plus_heuristic_ms: u64,
            source_ms: u64,
        };
        fn compare(_: Context, a: Child, b: Child) std.math.Order {
            return std.math.order(a.source_plus_heuristic_ms, b.source_plus_heuristic_ms);
        }
    };
    const Queue = std.PriorityQueue(Context.Child, Context, Context.compare);

    fn heuristicMs(this: *Pathfind, a: vec2i32) u64 {
        const x_diff: u64 = @abs(a[0] - this.dst[0]);
        const y_diff: u64 = @abs(a[1] - this.dst[1]);
        return x_diff * this.cfg.min_horiz_ms + y_diff * this.cfg.min_vert_ms;
    }

    fn step(this: *Pathfind) !bool {
        const current = this.queue.removeOrNull() orelse return false;
        if (@reduce(.And, current.pos == this.dst)) return false;

        if (this.cost_so_far.get(current.pos)) |best_ms| {
            if (current.source_ms > best_ms) return true;
        }

        for (calculatePathfindEdges(this.map, current.pos, this.cfg).bidi) |next| {
            if (!next.valid()) continue;
            const new_cost = this.cost_so_far.get(current.pos).? + next.cost_msec;
            const existing_cost = this.cost_so_far.get(next.pos);
            if (existing_cost == null or new_cost < existing_cost.?) {
                try this.cost_so_far.put(next.pos, new_cost);
                try this.queue.add(.{
                    .pos = next.pos,
                    .source_plus_heuristic_ms = new_cost + this.heuristicMs(next.pos),
                    .source_ms = new_cost,
                });
                try this.came_from.put(next.pos, current.pos);
            }
        }

        return true;
    }
};
fn pathfindPath(map: *Map, src: vec2i32, dst: vec2i32, path_cfg: *const PathCfg) !void {
    var pathfind: Pathfind = try .init(map, src, dst, path_cfg);
    defer pathfind.deinit();
    var steps: usize = 0;
    while (try pathfind.step()) : (steps += 1) {}
    std.log.err("{d} steps; cost_ms: {?d}", .{ steps, pathfind.cost_so_far.get(dst) });
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

    const path = calculatePathfindEdges(map, .{ MAP_SIZE[0] / 2, 1 }, &.{});
    std.log.err("got path:", .{});
    {
        var buffer: [64]u8 = undefined;
        const stderr = std.debug.lockStderrWriter(&buffer);
        defer std.debug.unlockStderrWriter();
        @import("print.zig").print(stderr, path, &.{ .tty = .detect(std.fs.File.stderr()) }) catch {};
        stderr.writeByte('\n') catch {};
    }

    try pathfindPath(map, .{ 50, 1 }, .{ 25, 1 }, &.{});
    try pathfindPath(map, .{ 50, 1 }, .{ 25, 2 }, &.{});
}
