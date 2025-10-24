const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const profiler_optimize = std.builtin.OptimizeMode.ReleaseSafe;

    const fmt_step = b.addFmt(.{ .paths = &.{ "src", "build.zig", "build.zig.zon" } });
    b.getInstallStep().dependOn(&fmt_step.step);

    const zstd_dep = b.dependency("zstd", .{ .target = target, .optimize = optimize });

    const tracy_dep = b.dependency("tracy", .{});

    const tracy_lib = b.addLibrary(.{
        .name = "tracy_lib",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(tracy_lib);
    tracy_lib.addIncludePath(tracy_dep.path("."));
    tracy_lib.addCSourceFile(.{
        .file = tracy_dep.path("public/TracyClient.cpp"),
        .flags = &.{
            "-DTRACY_ENABLE=1",
            "-fno-sanitize=undefined",
            "-D_WIN32_WINNT=0x601", // https://github.com/ziglang/zig/blob/ac21ade667f0f42b8b1aec5831cbc99cbaed8565/build.zig#L374
        },
    });
    tracy_lib.linkLibC();
    tracy_lib.linkLibCpp();

    // tracy client won't cross-compile to windows because it needs a bunch of libraries
    if (target.result.os.tag == .windows) {
        tracy_lib.linkSystemLibrary("Advapi32");
        tracy_lib.linkSystemLibrary("User32");
        tracy_lib.linkSystemLibrary("Ws2_32");
        tracy_lib.linkSystemLibrary("DbgHelp");
    }

    const tracy_mod = b.addModule("tracy", .{
        .root_source_file = b.path("src/tracy.zig"),
        .target = target,
        .optimize = optimize,
    });
    tracy_mod.addIncludePath(tracy_dep.path("public/tracy"));
    tracy_mod.linkLibrary(tracy_lib);

    //
    // Tracy profiler
    //

    // TODO: support cross-compiling profiler exe

    const zglfw = b.dependency("zglfw", .{ .target = target, .optimize = profiler_optimize });
    const tracy_exe = b.addExecutable(.{
        .name = "tracy",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = profiler_optimize,
        }),
    });
    tracy_exe.linkLibrary(zglfw.artifact("glfw"));
    tracy_exe.addIncludePath(b.path("src"));
    const profiler_flags: []const []const u8 = &[_][]const u8{
        "-fno-sanitize=undefined",
        "-fexperimental-library",
        "-std=c++20",
        //
        // "-Wno-attributes", // error: attribute declaration must precede definition
        // "-Wno-unused-result", // error: ignoring return value of function declared with 'warn_unused_result' attribute
        "-Wno-builtin-macro-redefined", // error: redefining builtin macro (__TIME__, __DATE__)
        "-D__DATE__=\"disabled\"",
        "-D__TIME__=\"disabled\"",
    };
    tracy_exe.addCSourceFiles(.{
        .root = tracy_dep.path("."),
        .files = &[_][]const u8{
            // ls profiler/***.{c} server/***.{c} public/***.{c} imgui/***.{c}
            "profiler/src/ini.c",
        },
        .flags = &.{
            "-fno-sanitize=undefined",
        },
    });
    tracy_exe.addCSourceFiles(.{
        .root = tracy_dep.path("."),
        .files = &[_][]const u8{
            // ls profiler/***.{cpp} server/***.{cpp} public/***.{cpp} imgui/***.{cpp}

            "imgui/imgui.cpp",
            "imgui/imgui_demo.cpp",
            "imgui/imgui_draw.cpp",
            "imgui/imgui_tables.cpp",
            "imgui/imgui_widgets.cpp",
            // "imgui/misc/freetype/imgui_freetype.cpp",
            // "profiler/src/BackendEmscripten.cpp",
            "profiler/src/BackendGlfw.cpp",
            // "profiler/src/BackendWayland.cpp",
            "profiler/src/ConnectionHistory.cpp",
            "profiler/src/Filters.cpp",
            "profiler/src/Fonts.cpp",
            "profiler/src/HttpRequest.cpp",
            "profiler/src/ImGuiContext.cpp",
            "profiler/src/imgui/imgui_impl_glfw.cpp",
            "profiler/src/imgui/imgui_impl_opengl3.cpp",
            "profiler/src/IsElevated.cpp",
            "profiler/src/main.cpp",
            "profiler/src/profiler/TracyAchievementData.cpp",
            "profiler/src/profiler/TracyAchievements.cpp",
            "profiler/src/profiler/TracyBadVersion.cpp",
            "profiler/src/profiler/TracyColor.cpp",
            "profiler/src/profiler/TracyEventDebug.cpp",
            "profiler/src/profiler/TracyFileselector.cpp",
            "profiler/src/profiler/TracyFilesystem.cpp",
            "profiler/src/profiler/TracyImGui.cpp",
            "profiler/src/profiler/TracyMicroArchitecture.cpp",
            "profiler/src/profiler/TracyMouse.cpp",
            "profiler/src/profiler/TracyProtoHistory.cpp",
            "profiler/src/profiler/TracySourceContents.cpp",
            "profiler/src/profiler/TracySourceTokenizer.cpp",
            "profiler/src/profiler/TracySourceView.cpp",
            "profiler/src/profiler/TracyStorage.cpp",
            "profiler/src/profiler/TracyTexture.cpp",
            "profiler/src/profiler/TracyTimelineController.cpp",
            "profiler/src/profiler/TracyTimelineItem.cpp",
            "profiler/src/profiler/TracyTimelineItemCpuData.cpp",
            "profiler/src/profiler/TracyTimelineItemGpu.cpp",
            "profiler/src/profiler/TracyTimelineItemPlot.cpp",
            "profiler/src/profiler/TracyTimelineItemThread.cpp",
            "profiler/src/profiler/TracyUserData.cpp",
            "profiler/src/profiler/TracyUtility.cpp",
            "profiler/src/profiler/TracyView_Annotations.cpp",
            "profiler/src/profiler/TracyView_Callstack.cpp",
            "profiler/src/profiler/TracyView_Compare.cpp",
            "profiler/src/profiler/TracyView_ConnectionState.cpp",
            "profiler/src/profiler/TracyView_ContextSwitch.cpp",
            "profiler/src/profiler/TracyView.cpp",
            "profiler/src/profiler/TracyView_CpuData.cpp",
            "profiler/src/profiler/TracyView_FindZone.cpp",
            "profiler/src/profiler/TracyView_FlameGraph.cpp",
            "profiler/src/profiler/TracyView_FrameOverview.cpp",
            "profiler/src/profiler/TracyView_FrameTimeline.cpp",
            "profiler/src/profiler/TracyView_FrameTree.cpp",
            "profiler/src/profiler/TracyView_GpuTimeline.cpp",
            "profiler/src/profiler/TracyView_Locks.cpp",
            "profiler/src/profiler/TracyView_Memory.cpp",
            "profiler/src/profiler/TracyView_Messages.cpp",
            "profiler/src/profiler/TracyView_Navigation.cpp",
            "profiler/src/profiler/TracyView_NotificationArea.cpp",
            "profiler/src/profiler/TracyView_Options.cpp",
            "profiler/src/profiler/TracyView_Playback.cpp",
            "profiler/src/profiler/TracyView_Plots.cpp",
            "profiler/src/profiler/TracyView_Ranges.cpp",
            "profiler/src/profiler/TracyView_Samples.cpp",
            "profiler/src/profiler/TracyView_Statistics.cpp",
            "profiler/src/profiler/TracyView_Timeline.cpp",
            "profiler/src/profiler/TracyView_TraceInfo.cpp",
            "profiler/src/profiler/TracyView_Utility.cpp",
            "profiler/src/profiler/TracyView_ZoneInfo.cpp",
            "profiler/src/profiler/TracyView_ZoneTimeline.cpp",
            "profiler/src/profiler/TracyWeb.cpp",
            "profiler/src/ResolvService.cpp",
            "profiler/src/RunQueue.cpp",
            "profiler/src/WindowPosition.cpp",
            "profiler/src/winmainArchDiscovery.cpp",
            "profiler/src/winmain.cpp",
            // "public/client/TracyAlloc.cpp",
            // "public/client/TracyCallstack.cpp",
            // "public/client/TracyDxt1.cpp",
            // "public/client/TracyKCore.cpp",
            // "public/client/TracyOverride.cpp",
            // "public/client/TracyProfiler.cpp",
            // "public/client/tracy_rpmalloc.cpp",
            // "public/client/TracySysPower.cpp",
            // "public/client/TracySysTime.cpp",
            // "public/client/TracySysTrace.cpp",
            "public/common/tracy_lz4.cpp",
            "public/common/tracy_lz4hc.cpp",
            "public/common/TracySocket.cpp",
            "public/common/TracyStackFrames.cpp",
            "public/common/TracySystem.cpp",
            "public/libbacktrace/alloc.cpp",
            "public/libbacktrace/dwarf.cpp",
            // "public/libbacktrace/elf.cpp", // conflicts with macho
            "public/libbacktrace/fileline.cpp",
            // "public/libbacktrace/macho.cpp", // conflicts with elf
            "public/libbacktrace/mmapio.cpp",
            "public/libbacktrace/posix.cpp",
            "public/libbacktrace/sort.cpp",
            "public/libbacktrace/state.cpp",
            // "public/TracyClient.cpp",
            "server/TracyMemory.cpp",
            "server/TracyMmap.cpp",
            "server/TracyPrint.cpp",
            "server/TracySysUtil.cpp",
            "server/TracyTaskDispatch.cpp",
            "server/TracyTextureCompression.cpp",
            "server/TracyThreadCompress.cpp",
            "server/TracyWorker.cpp",
        },
        .flags = profiler_flags,
    });
    tracy_exe.linkLibrary(zstd_dep.artifact("zstd"));
    switch (target.result.os.tag) {
        .macos => {
            tracy_exe.linkSystemLibrary("capstone");
            tracy_exe.addCSourceFiles(.{
                .root = tracy_dep.path("."),
                .files = &[_][]const u8{
                    "public/libbacktrace/macho.cpp",
                },
                .flags = profiler_flags,
            });
            tracy_exe.addCSourceFiles(.{
                .root = tracy_dep.path("."),
                .files = &[_][]const u8{
                    "nfd/nfd_cocoa.m",
                },
                .flags = &[_][]const u8{
                    "-fno-sanitize=undefined",
                },
            });
            tracy_exe.linkFramework("AppKit");
            tracy_exe.linkFramework("UniformTypeIdentifiers");
        },
        .linux => {
            tracy_exe.linkSystemLibrary("capstone");
            tracy_exe.linkSystemLibrary("dbus-1");
            tracy_exe.addCSourceFiles(.{
                .root = tracy_dep.path("."),
                .files = &[_][]const u8{
                    "nfd/nfd_portal.cpp",
                    "public/libbacktrace/elf.cpp",
                },
                .flags = profiler_flags,
            });
        },
        .windows => {
            tracy_exe.linkSystemLibrary("capstone");
            tracy_exe.addCSourceFiles(.{
                .root = tracy_dep.path("."),
                .files = &[_][]const u8{
                    "nfd/nfd_win.cpp",
                    "public/libbacktrace/elf.cpp",
                },
                .flags = profiler_flags,
            });

            // need to:
            // - compile capstone ourself
            // - compile zstd ourself
            const fail_step = b.addFail("TODO support compiling tracy profiler for windows");
            tracy_exe.step.dependOn(&fail_step.step);
        },
        else => {
            const fail_step = b.addFail("TODO support compiling tracy profiler for target");
            tracy_exe.step.dependOn(&fail_step.step);
        },
    }
    tracy_exe.addIncludePath(tracy_dep.path("."));
    tracy_exe.addIncludePath(tracy_dep.path("imgui"));
    tracy_exe.addIncludePath(tracy_dep.path("profiler"));
    tracy_exe.addIncludePath(tracy_dep.path("server"));
    tracy_exe.addIncludePath(tracy_dep.path("tracy"));
    tracy_exe.addIncludePath(tracy_dep.path("."));
    tracy_exe.addIncludePath(tracy_dep.path("common"));
    tracy_exe.linkLibC();
    tracy_exe.linkLibCpp();
    b.installArtifact(tracy_exe);

    const run_step = b.addRunArtifact(tracy_exe);
    if (b.args) |a| run_step.addArgs(a);
    run_step.step.dependOn(b.getInstallStep());
    const run = b.step("run", "Run");
    run.dependOn(&run_step.step);
}
