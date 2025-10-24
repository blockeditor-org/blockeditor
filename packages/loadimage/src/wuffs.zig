// temporary until https://github.com/ziglang/zig/issues/20649 is fixed
pub const _wuffs_temp_fix = @cImport({
    @cInclude("wuffs-v0.4.c");
});
