const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fmt = b.addFmt(.{
        .paths = &.{ "src", "build.zig", "build.zig.zon" },
    });
    b.getInstallStep().dependOn(&fmt.step);

    const sheen_bidi_dep = b.dependency("sheen_bidi", .{});
    const sheen_bidi_lib = b.addLibrary(.{
        .name = "sheen_bidi",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    sheen_bidi_lib.addCSourceFiles(.{
        .root = sheen_bidi_dep.path("."),
        .files = &.{
            "Source/BidiChain.c",
            "Source/BidiTypeLookup.c",
            "Source/BracketQueue.c",
            "Source/GeneralCategoryLookup.c",
            "Source/IsolatingRun.c",
            "Source/LevelRun.c",
            "Source/PairingLookup.c",
            "Source/RunQueue.c",
            "Source/SBAlgorithm.c",
            "Source/SBBase.c",
            "Source/SBCodepointSequence.c",
            "Source/SBLine.c",
            "Source/SBLog.c",
            "Source/SBMirrorLocator.c",
            "Source/SBParagraph.c",
            "Source/SBScriptLocator.c",
            "Source/ScriptLookup.c",
            "Source/ScriptStack.c",
            "Source/SheenBidi.c",
            "Source/StatusStack.c",
        },
    });
    b.installArtifact(sheen_bidi_lib);
    sheen_bidi_lib.addIncludePath(sheen_bidi_dep.path("Headers"));
    sheen_bidi_lib.installHeadersDirectory(sheen_bidi_dep.path("Headers"), "", .{});
    sheen_bidi_lib.linkLibC();

    const sheen_bidi_translatec = b.addTranslateC(.{
        .root_source_file = sheen_bidi_dep.path("Headers/SheenBidi.h"),
        .target = target,
        .optimize = optimize,
    });
    const sheen_bidi_mod = sheen_bidi_translatec.addModule("sheen_bidi");
    sheen_bidi_mod.addIncludePath(sheen_bidi_dep.path("Include"));
    sheen_bidi_mod.linkLibrary(sheen_bidi_lib);

    const sheen_bidi_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sheen_bidi_tests.root_module.addImport("sheen_bidi", sheen_bidi_mod);
    b.installArtifact(sheen_bidi_tests);

    const run_tests = b.addRunArtifact(sheen_bidi_tests);
    run_tests.step.dependOn(b.getInstallStep());
    const run_step = b.step("test", "run tests");
    run_step.dependOn(&run_tests.step);
}
