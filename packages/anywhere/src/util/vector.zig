const vec = @This();

// todo: we will create a custom vector type
// we want: reduce,eql,add,sub,mul,div,...etc
pub fn Vector(comptime n: comptime_int, comptime T: type) type {
    return @Vector(n, T);
}

pub const by = Vector;
pub const by2i32 = by(2, i32);
pub const by2usize = by(2, usize);
pub const by3i32 = by(3, i32);
pub const by3usize = by(3, usize);

pub fn Iterator(comptime n: comptime_int, comptime T: type) type {
    return struct {
        const vecXT = by(n, T);
        min: vecXT,
        /// exclusive
        max: vecXT,
        value: vecXT,
        pub fn size(sizeValue: vecXT) @This() {
            return .posSize(@splat(0), sizeValue);
        }
        pub fn posSize(pos: vecXT, sizeValue: vecXT) @This() {
            return .minMax(pos, sizeValue - pos);
        }
        /// max is exclusive
        pub fn minMax(min: vecXT, max: vecXT) @This() {
            return .{ .min = min, .max = max, .value = min };
        }
        pub fn minMaxInclusive(min: vecXT, max: vecXT) @This() {
            return .{ .min = min, .max = max + @as(vecXT, @splat(1)), .value = min };
        }
        pub fn next(self: *@This()) ?vecXT {
            const res = self.value;
            for (0..n) |i| {
                self.value[i] += 1;
                if (self.value[i] < self.max[i]) break;
                self.value[i] = self.min[i];
            } else return null;
            return res;
        }
    };
}
