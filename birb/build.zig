const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mach_glfw = b.dependency("mach_glfw", .{ .target = target, .optimize = optimize });
    _ = b.addModule("birb", .{ .source_file = .{ .path = "src/birb.zig" }, .dependencies = &.{.{ .name = "mach-glfw", .module = mach_glfw.module("mach-glfw") }} });

    const test_step = b.step("test", "Run library tests");
    const main_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/birb.zig" },
        .target = target,
        .optimize = optimize,
    });
    const run_main_tests = b.addRunArtifact(main_tests);
    test_step.dependOn(&run_main_tests.step);
}

pub fn link(b: *std.Build, step: *std.build.CompileStep) void {
    const glfw_dep = b.dependency("mach_glfw", .{ .target = step.target, .optimize = step.optimize });
    @import("mach_glfw").link(glfw_dep.builder, step);
}
