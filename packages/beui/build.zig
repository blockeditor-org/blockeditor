const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tool_target = b.resolveTargetQuery(.{});
    const tool_optimize: std.builtin.OptimizeMode = .Debug;

    const run_zig_fmt = b.addFmt(.{
        .paths = &.{ "src", "build.zig", "build.zig.zon" },
    });
    b.getInstallStep().dependOn(&run_zig_fmt.step);

    const loadimage_mod = b.dependency("loadimage", .{ .target = tool_target, .optimize = tool_optimize });
    const genfont_tool = b.addExecutable(.{
        .name = "genfont_tool",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/genfont.zig"),
            .target = tool_target,
            .optimize = tool_optimize,
            .imports = &.{
                .{ .name = "loadimage", .module = loadimage_mod.module("loadimage") },
            },
        }),
    });
    const genfont_run = b.addRunArtifact(genfont_tool);
    genfont_run.addFileArg(b.path("src/base_texture.png"));
    const font_rgba = genfont_run.addOutputFileArg("font.rgba");
    const font_rgba_mod = b.createModule(.{
        .root_source_file = font_rgba,
    });

    const sheen_bidi_dep = b.dependency("sheen_bidi", .{ .target = target, .optimize = optimize });
    const sheen_bidi_mod = sheen_bidi_dep.module("sheen_bidi");

    const anywhere_mod = b.dependency("anywhere", .{}).module("anywhere");

    const texteditor_dep = b.dependency("texteditor", .{ .target = target, .optimize = optimize });
    const texteditor_mod = texteditor_dep.module("texteditor");

    const blocks_dep = b.dependency("blocks", .{ .target = target, .optimize = optimize });
    const blocks_mod = blocks_dep.module("blocks");

    const fonts_mod = b.dependency("fonts", .{});
    const notosans_wght_mod = b.createModule(.{
        .root_source_file = fonts_mod.path("NotoSans[wght].ttf"),
    });
    const notosansmono_wght_mod = b.createModule(.{
        .root_source_file = fonts_mod.path("NotoSansMono[wght].ttf"),
    });

    const mach_freetype_dep = b.dependency("mach_freetype", .{
        .target = target,
        .optimize = optimize,
    });
    const freetype_mod = mach_freetype_dep.module("mach-freetype");
    const harfbuzz_mod = mach_freetype_dep.module("mach-harfbuzz");
    // wasm patches
    if (target.result.os.tag == .wasi) {
        freetype_mod.addCMacro("__wasm_exception_handling__", "");
        harfbuzz_mod.addCMacro("__wasm_exception_handling__", "");
        if (mach_freetype_dep.builder.lazyDependency("freetype", .{
            .target = target,
            .optimize = optimize,
            .use_system_zlib = false,
            .enable_brotli = true,
        })) |ft_dep| {
            ft_dep.artifact("freetype").root_module.addCMacro("__wasm_exception_handling__", "");
        }
        if (mach_freetype_dep.builder.lazyDependency("harfbuzz", .{
            .target = target,
            .optimize = optimize,
            .enable_freetype = true,
            .freetype_use_system_zlib = false,
            .freetype_enable_brotli = true,
        })) |hb_dep| {
            hb_dep.artifact("harfbuzz").root_module.addCMacro("__wasm_exception_handling__", "");
            hb_dep.artifact("harfbuzz").root_module.addCMacro("HB_NO_MT", "");
            for (hb_dep.artifact("harfbuzz").root_module.link_objects.items) |*lobj| {
                switch (lobj.*) {
                    inline .c_source_file, .c_source_files => |csf| {
                        var flags_clone = std.ArrayList([]const u8).initCapacity(b.allocator, csf.flags.len) catch unreachable;
                        flags_clone.appendSliceAssumeCapacity(csf.flags);
                        flags_clone.append(b.allocator, "-Wno-nontrivial-memaccess") catch unreachable;
                        csf.flags = flags_clone.toOwnedSlice(b.allocator) catch unreachable;
                    },
                    else => {},
                }
            }
        }
    }

    const beui_mod = b.addModule("beui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    beui_mod.addImport("font.rgba", font_rgba_mod);
    beui_mod.addImport("freetype", freetype_mod);
    beui_mod.addImport("harfbuzz", harfbuzz_mod);
    beui_mod.addImport("sheen_bidi", sheen_bidi_mod);
    beui_mod.addImport("anywhere", anywhere_mod);
    beui_mod.addImport("texteditor", texteditor_mod);
    beui_mod.addImport("blocks", blocks_mod);
    beui_mod.addImport("NotoSans[wght].ttf", notosans_wght_mod);
    beui_mod.addImport("NotoSansMono[wght].ttf", notosansmono_wght_mod);

    const beui_test = b.addTest(.{ .root_module = beui_mod });

    b.installArtifact(beui_test);
    const run_beui_tests = b.addRunArtifact(beui_test);

    const test_step = b.step("test", "Test");
    test_step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_beui_tests.step);

    // wasm fix
    if (target.result.os.tag == .wasi) {
        if (mach_freetype_dep.builder.lazyDependency("harfbuzz", .{
            .target = target,
            .optimize = optimize,
            .enable_freetype = true,
        })) |dep| {
            dep.artifact("harfbuzz").root_module.addCMacro("HB_NO_MT", "");
        }
        if (mach_freetype_dep.builder.lazyDependency("freetype", .{
            .target = target,
            .optimize = optimize,
            .use_system_zlib = false,
            .enable_brotli = true,
        })) |dep| {
            //
            _ = dep;
        }
    }
}
