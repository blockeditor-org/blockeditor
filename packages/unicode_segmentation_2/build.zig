const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zg = b.dependency("zg", .{ .target = target, .optimize = optimize });
    const grapheme_break_test = b.dependency("grapheme_break_test", .{});

    const mod = b.addModule("unicode_segmentation_2", .{
        .root_source_file = b.path("src/zig_cluster.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("Graphemes", zg.module("Graphemes"));
    mod.addImport("grapheme_break_test", b.createModule(.{ .root_source_file = grapheme_break_test.path("GraphemeBreakTest.txt") }));

    const tests = b.addTest(.{ .root_module = mod });
    b.installArtifact(tests);

    const run_tests = b.addRunArtifact(tests);
    run_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
