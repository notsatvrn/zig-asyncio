const std = @import("std");

pub fn build(b: *std.Build) void {
    // OPTIONS

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // DEPENDENCIES

    const coro = b.dependency("zigcoro", .{});
    const xev = b.dependency("libxev", .{});

    // MODULE

    const options = b.addOptions();
    const options_module = options.createModule();
    const asyncio = b.addModule("asyncio", .{
        .root_source_file = b.path("src/root.zig"),
        .imports = &.{
            .{ .name = "options", .module = options_module },
            .{ .name = "coro", .module = coro.module("libcoro") },
            .{ .name = "xev", .module = xev.module("xev") },
        },
    });

    // LIBRARY

    const lib = b.addStaticLibrary(.{
        .name = "zig-asyncio",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    lib.linkLibC();
    lib.root_module.addImport("coro", coro.module("libcoro"));
    lib.root_module.addImport("xev", xev.module("xev"));
    b.installArtifact(lib);

    // TESTS

    const tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });

    tests.linkLibC();
    tests.root_module.addImport("asyncio", asyncio);

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
