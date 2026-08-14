const UnitScale = enum {
    milli,
    one,
    kilo,
    mega,
};
const UnitTag = enum {
    meter,
    joule,
    kelvin,
    gram,
};

fn Unit(comptime Int: type, scale: UnitScale, tag: UnitTag) type {
    return enum(Int) {
        _,
        pub const unit_scale = scale;
        pub const unit_tag = tag;
        const Self = @This();

        pub fn from(value: Int) Self {
            return @intFromEnum(value);
        }
        pub fn to(self: Self) Int {
            return @enumFromInt(self);
        }
    };
}
