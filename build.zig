const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the signals library
    const lib = b.addStaticLibrary(.{
        .name = "signals",
        .root_source_file = b.path("src/signal.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(lib);

    // Create an executable demo
    const exe = b.addExecutable(.{
        .name = "signals_demo",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the signals demo");
    run_step.dependOn(&run_cmd.step);

    // Add test step
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/signal.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
