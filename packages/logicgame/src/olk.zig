const Kind = enum {
    fn desc() *KindDesc {}
};
const KindDesc = struct {
    state: enum { solid, liquid, gas },
    heat_capacity: u64,
    heat_transfer_speed: u64,
};

const Tile = struct {
    kind: Kind,
    temperature: u64,
    mass: u64,
    fn energy(self: Tile) u64 {
        const self_desc = self.kind.desc();
        _ = self_desc;
        return self.mass * self.temperature;
    }
};
const Direction = enum {
    up,
    left,
    down,
    right,
};

fn exchange(a: *Tile, b: *Tile, dir: Direction) void {
    const start_energy = a.energy() + b.energy();
    defer std.debug.assert(a.energy() + b.energy() == start_energy);

    if (a.kind != b.kind) return; // maybe swap but don't transfer mass/heat
    const a_desc = a.kind.desc();
    const b_desc = b.kind.desc();
    _ = dir;

    // transfer some heat at heat transfer speed
    _ = a_desc;
    _ = b_desc;
}

const std = @import("std");
