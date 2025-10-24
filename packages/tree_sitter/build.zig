const std = @import("std");

pub fn addLanguage(b: *std.Build, language_name: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, src_path: std.Build.LazyPath, source_files: []const []const u8) *std.Build.Step.Compile {
    const language_support_obj = b.addLibrary(.{
        .name = b.fmt("tree_sitter_{s}", .{language_name}),
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    language_support_obj.linkLibC();
    language_support_obj.addCSourceFiles(.{ .root = src_path, .files = source_files });
    language_support_obj.addIncludePath(src_path);
    return language_support_obj;
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fmt_step = b.addFmt(.{ .paths = &.{ "src", "build.zig", "build.zig.zon" } });
    b.getInstallStep().dependOn(&fmt_step.step);

    const tree_sitter_dep = b.dependency("tree_sitter", .{ .target = target, .optimize = optimize });

    b.installArtifact(tree_sitter_dep.artifact("tree-sitter"));

    const tree_sitter_translatec_module = if (target.result.abi.isAndroid()) blk: {
        // use addModule so building android works (no way to set a libc file on addTranslateC)
        const mod = b.addModule("tree_sitter_translatec", .{
            .root_source_file = b.path("src/workaround.zig"),
            .target = target,
            .optimize = optimize,
        });
        mod.addIncludePath(tree_sitter_dep.path("lib/include/tree_sitter"));
        break :blk mod;
    } else blk: {
        // use addTranslateC so building docs works
        const tree_sitter_translatec = b.addTranslateC(.{
            .root_source_file = tree_sitter_dep.path("lib/include/tree_sitter/api.h"),
            .target = target,
            .optimize = optimize,
        });
        tree_sitter_translatec.addIncludePath(tree_sitter_dep.path("lib/include/tree_sitter"));
        break :blk b.addModule("tree_sitter_translatec", .{
            .root_source_file = b.path("src/noworkaround.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nwh", .module = tree_sitter_translatec.createModule() },
            },
        });
    };
    tree_sitter_translatec_module.linkLibrary(tree_sitter_dep.artifact("tree-sitter"));

    const tree_sitter_bindings_module = b.addModule("tree_sitter", .{
        .root_source_file = b.path("src/tree_sitter_bindings.zig"),
    });
    tree_sitter_bindings_module.addImport("tree_sitter_translatec", tree_sitter_translatec_module);
}
