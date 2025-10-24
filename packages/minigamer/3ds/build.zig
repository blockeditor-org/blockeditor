const std = @import("std");
const zig3ds = @import("zig3ds");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});

    const swizzleimg = b.addExecutable(.{
        .name = "swizzlearray",
        .root_module = b.createModule(.{
            .target = b.resolveTargetQuery(.{}),
            .optimize = .Debug,
            .root_source_file = b.path("tmp/swizzlearray.zig"),
        }),
    });
    const runswizzle = b.addRunArtifact(swizzleimg);
    runswizzle.addFileArg(b.path("tmp/swizzle.rgba"));
    const swiz_c = runswizzle.addOutputFileArg("swizzle.c");

    const emu_mod = b.dependency("emulator", .{}).module("emu");
    const sponge_mod = b.createModule(.{ .root_source_file = b.dependency("sponge", .{ .optimize = .ReleaseFast }).artifact("sponge.cart").getEmittedBin() });

    const zig3ds_dep = b.dependency("zig3ds", .{ .optimize = optimize });
    const build_helper = zig3ds.T3dsBuildHelper.find(zig3ds_dep, "build_helper");
    const libc_includer = zig3ds.CIncluder.find(zig3ds_dep, "c");
    const libctru_includer = zig3ds.CIncluder.find(zig3ds_dep, "ctru");
    const citro3d_includer = zig3ds.CIncluder.find(zig3ds_dep, "citro3d");
    const citro2d_includer = zig3ds.CIncluder.find(zig3ds_dep, "citro2d");

    const zigpart = b.addObject(.{
        .name = "zigpart",
        .root_module = b.createModule(.{
            .target = build_helper.target,
            .optimize = optimize,
            .root_source_file = b.path("src/zigpart.zig"),
        }),
    });
    zigpart.root_module.addImport("minigamer_emulator", emu_mod);
    zigpart.root_module.addImport("sponge.cart", sponge_mod);
    libc_includer.applyTo(zigpart.root_module);
    zigpart.setLibCFile(zig3ds_dep.namedLazyPath("c"));
    zigpart.libc_file.?.addStepDependencies(&zigpart.step);
    zigpart.linkLibC();
    libctru_includer.applyTo(zigpart.root_module);

    const elf = b.addExecutable(.{
        .name = "sponge_3ds",
        .root_module = b.createModule(.{
            .target = build_helper.target,
            .optimize = optimize,
        }),
    });
    elf.addCSourceFile(.{ .file = b.path("src/entry_3ds.c") });
    elf.addCSourceFile(.{ .file = swiz_c });
    elf.step.dependOn(&runswizzle.step);
    elf.addObject(zigpart);
    elf.root_module.sanitize_c = .off;
    build_helper.link(elf);

    libc_includer.applyTo(elf.root_module);
    elf.linkLibrary(zig3ds_dep.artifact("c"));
    elf.setLibCFile(zig3ds_dep.namedLazyPath("c"));
    elf.libc_file.?.addStepDependencies(&elf.step);
    elf.linkLibC();
    elf.linkLibrary(zig3ds_dep.artifact("m"));
    libctru_includer.applyTo(elf.root_module);
    elf.linkLibrary(zig3ds_dep.artifact("ctru"));
    citro3d_includer.applyTo(elf.root_module);
    elf.linkLibrary(zig3ds_dep.artifact("citro3d"));
    citro2d_includer.applyTo(elf.root_module);
    elf.linkLibrary(zig3ds_dep.artifact("citro2d"));

    // elf -> 3dsx
    const output_3dsx = build_helper.to3dsx(elf);

    b.addNamedLazyPath("minigamer.3dsx", output_3dsx);
    const output_3dsx_install = b.addInstallFileWithDir(output_3dsx, .bin, "minigamer.3dsx");
    const output_3dsx_path = b.getInstallPath(.bin, "minigamer.3dsx");
    b.getInstallStep().dependOn(&output_3dsx_install.step);

    const run_step = std.Build.Step.Run.create(b, b.fmt("citra run", .{}));
    run_step.addArg("citra");
    run_step.addArg(output_3dsx_path);
    run_step.step.dependOn(b.getInstallStep());
    const run_step_cmdl = b.step("run", "Run in citra");
    run_step_cmdl.dependOn(&run_step.step);
}
