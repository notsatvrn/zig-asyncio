const std = @import("std");

const aio = @import("aio");
const coro = @import("coro");

pub var event: ?aio.EventSource = null;

pub fn handler() void {
    aio.single(aio.NotifyEventSource{ .source = &event.? }) catch {};
    // wait 10ms for notification to send out
    aio.single(aio.Timeout{ .ns = std.time.ns_per_ms * 10 }) catch {};
    aio.single(aio.CloseEventSource{ .source = &event.? }) catch {};
    event = null;
}

pub fn ctrlC() !void {
    if (event == null) {
        event = try aio.EventSource.init();
        try Impl.setupHandler();
    }

    try coro.io.single(aio.WaitEventSource{ .source = &event.? });
}

// LISTENER IMPLEMENTATION

const Impl = if (@import("builtin").os.tag == .windows) Windows else Posix;

const Windows = struct {
    const windows = std.os.windows;

    fn wrappedHandler(dwCtrlType: windows.DWORD) callconv(windows.WINAPI) windows.BOOL {
        if (dwCtrlType == windows.CTRL_C_EVENT) {
            handler();
            return windows.TRUE;
        } else {
            return windows.FALSE;
        }
    }

    pub inline fn setupHandler() !void {
        return windows.SetConsoleCtrlHandler(wrappedHandler, true);
    }
};

const Posix = struct {
    const posix = std.posix;

    fn wrappedHandler(sig: c_int) callconv(.C) void {
        std.debug.assert(sig == posix.SIG.INT);
        handler();
    }

    pub inline fn setupHandler() !void {
        const act = posix.Sigaction{
            .handler = .{ .handler = wrappedHandler },
            .mask = posix.empty_sigset,
            .flags = 0,
        };
        posix.sigaction(posix.SIG.INT, &act, null);
    }
};
