const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
    });

    const raylib = raylib_dep.module("raylib");
    const raylib_artifact = raylib_dep.artifact("raylib");

    const app_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "raytracer",
        .root_module = app_module,
    });

    exe.root_module.addImport("raylib", raylib);
    exe.root_module.linkLibrary(raylib_artifact);

    b.installArtifact(exe);

    const run_command = b.addRunArtifact(exe);
    run_command.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Ejecutar el raytracer");
    run_step.dependOn(&run_command.step);

    // Las pruebas necesitan el módulo raylib y enlazar la librería,
    // porque las operaciones de rl.Vector3 llaman a funciones de C.
    const tests = b.addTest(.{
        .root_module = app_module,
    });

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Ejecutar las pruebas unitarias");
    test_step.dependOn(&run_tests.step);
}
