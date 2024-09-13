const std = @import("std");

pub fn build(b: *std.Build) void {
    // OPTIONS

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // DEPENDENCIES

    const aio = b.dependency("aio", .{});
    const aio_module = aio.module("aio");
    const coro_module = aio.module("coro");
    const minilib_module = aio.module("minilib");

    // MODULE

    const options = b.addOptions();
    const options_module = options.createModule(); // reserved
    const folio = b.addModule("folio", .{
        .root_source_file = b.path("src/root.zig"),
        .imports = &.{
            .{ .name = "aio", .module = aio_module },
            .{ .name = "coro", .module = coro_module },
            .{ .name = "minilib", .module = minilib_module },
            .{ .name = "options", .module = options_module },
        },
    });

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
