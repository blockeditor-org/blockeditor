const std = @import("std");
const tree_sitter = @import("tree_sitter");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const treesitter_optimize: std.builtin.OptimizeMode = .ReleaseFast;

    const fmt_step = b.addFmt(.{ .paths = &.{ "src", "build.zig", "build.zig.zon" } });
    b.getInstallStep().dependOn(&fmt_step.step);

    // disabled because zls doesn't build yet
    // const zls_dep = b.dependency("zls", .{
    //     .target = target,
    //     .optimize = .ReleaseSafe,
    //     .@"version-string" = @as([]const u8, "0.15.0-dev"),
    // });
    // b.installArtifact(zls_dep.artifact("zls"));

    const diffz_dep = b.dependency("diffz", .{ .target = target, .optimize = optimize });

    const blocks_dep = b.dependency("blocks", .{ .target = target, .optimize = optimize });
    const seg_dep = b.dependency("unicode_segmentation_2", .{ .target = target, .optimize = optimize });
    const anywhere_mod = b.dependency("anywhere", .{}).module("anywhere");
    const tree_sitter_dep = b.dependency("tree_sitter", .{ .target = target, .optimize = treesitter_optimize });

    const tree_sitter_zig_obj = tree_sitter.addLanguage(b, "zig", target, treesitter_optimize, b.dependency("tree_sitter_zig", .{}).path("src"), &.{"parser.c"});
    b.installArtifact(tree_sitter_zig_obj);
    const tree_sitter_markdown_obj = tree_sitter.addLanguage(b, "markdown", target, treesitter_optimize, b.dependency("tree_sitter_markdown", .{}).path("tree-sitter-markdown/src"), &.{ "parser.c", "scanner.c" });
    b.installArtifact(tree_sitter_markdown_obj);

    const texteditor_mod = b.addModule("texteditor", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    texteditor_mod.addImport("diffz", diffz_dep.module("diffz"));
    texteditor_mod.addImport("blocks", blocks_dep.module("blocks"));
    texteditor_mod.addImport("grapheme_cursor", seg_dep.module("unicode_segmentation_2"));
    texteditor_mod.addImport("anywhere", anywhere_mod);
    texteditor_mod.addImport("tree_sitter", tree_sitter_dep.module("tree_sitter"));
    texteditor_mod.linkLibrary(tree_sitter_zig_obj);
    texteditor_mod.linkLibrary(tree_sitter_markdown_obj);

    const texteditor_test = b.addTest(.{
        .root_module = texteditor_mod,
    });

    b.installArtifact(texteditor_test);
    const run_texteditor_tests = b.addRunArtifact(texteditor_test);

    const test_step = b.step("test", "Test");
    test_step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_texteditor_tests.step);
}
