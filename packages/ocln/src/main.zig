const std = @import("std");

const vec2i32 = @Vector(2, i32);
const vec2usize = @Vector(2, usize);

const MAP_SIZE: vec2usize = .{ 200, 300 };

const TileMaterial = enum {
    none,
    unobtanium,
    dirt,
    stone,
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
        // fill walls
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
    var map: Map = undefined;
    try map.init(std.testing.allocator);
    defer map.deinit();
    map.generate();
}
