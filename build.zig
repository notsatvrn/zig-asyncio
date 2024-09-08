const std = @import("std");

pub fn build(b: *std.Build) void {
    // OPTIONS

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // DEPENDENCIES

    const aio = b.dependency("aio", .{});

    // MODULE

    const options = b.addOptions();
    const options_module = options.createModule();
    const folio = b.addModule("folio", .{
        .root_source_file = b.path("src/root.zig"),
        .imports = &.{
            .{ .name = "options", .module = options_module },
            .{ .name = "aio", .module = aio.module("aio") },
            .{ .name = "coro", .module = aio.module("coro") },
            .{ .name = "minilib", .module = aio.module("minilib") },
        },
    });

    // LIBRARY

    const lib = b.addStaticLibrary(.{
        .name = "zig-folio",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    lib.linkLibC();
    lib.root_module.addImport("aio", aio.module("aio"));
    lib.root_module.addImport("coro", aio.module("coro"));
    lib.root_module.addImport("minilib", aio.module("minilib"));
    b.installArtifact(lib);

    // TESTS

    const tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });

    tests.linkLibC();
    tests.root_module.addImport("folio", folio);

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
