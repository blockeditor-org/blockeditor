pub fn by(comptime n: comptime_int, comptime T: type) type {
    return @Vector(n, T);
}

pub const by2i32 = by(2, i32);
pub const by2usize = by(2, usize);
pub const by3i32 = by(3, i32);
pub const by3usize = by(3, usize);
