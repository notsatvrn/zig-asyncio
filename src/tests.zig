const std = @import("std");
const asyncio = @import("asyncio");

test "basics" {
    const rt = try asyncio.Runtime.init(std.testing.allocator, null);

    const thread = try rt.spawnThread(basicThread, .{});

    thread.join();
    rt.deinit();
}

fn basicThread(ctx: *asyncio.ThreadContext) void {
    _ = ctx;
}
