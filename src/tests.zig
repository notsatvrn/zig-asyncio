const std = @import("std");
const asyncio = @import("asyncio");

test "basics" {
    const rt = try asyncio.Runtime.init(std.testing.allocator);

    const thread = try rt.spawnThread(null, basicThread, .{});

    thread.join();
    rt.deinit();
}

fn basicThread(ctx: *asyncio.ThreadContext) void {
    _ = ctx;
}
