const std = @import("std");
const folio = @import("folio");

test "basics" {
    const rt = try folio.Runtime.init(std.testing.allocator);

    const worker = try rt.spawnWorker(basicWorker, .{});

    worker.join();
    rt.deinit();
}

fn basicWorker() void {}
