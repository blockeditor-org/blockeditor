pub fn x(comptime n: comptime_int, comptime T: type) type {
    return @Vector(n, T);
}

pub const x2i32 = x(2, i32);
pub const x2usize = x(2, usize);
