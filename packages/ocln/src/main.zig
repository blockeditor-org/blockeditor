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
const PathTarget = packed struct(u32) {
    x: u11,
    y: u11,
    cost_msec: u10,
    pub const none: PathTarget = .{ .x = std.math.maxInt(u11), .y = std.math.maxInt(u11), .cost_msec = std.math.maxInt(u10) };
    pub fn from(pos: vec2i32, msec: u10) PathTarget {
        const min: vec2i32 = .{ 0, 0 };
        const max: vec2i32 = @intCast(MAP_SIZE);
        if (@reduce(.Or, pos < min) or @reduce(.Or, pos >= max)) return .none;
        return .{ .x = @intCast(pos[0]), .y = @intCast(pos[1]), .cost_msec = msec };
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
    std.log.err("got path: {any}", .{path});
}
