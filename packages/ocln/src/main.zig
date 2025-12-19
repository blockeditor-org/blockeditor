const SIZE = 512 * 512; // have to loop over every tile every tick

const TileMaterial = enum {
    dirt,
    stone,
};
const Tile = struct {
    material: TileMaterial,
    mass: u64,
    temperature: u64,
};
const Map = struct {
    tiles: []Tile,
};
