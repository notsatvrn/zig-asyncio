const std = @import("std");

const aio = @import("aio");
const coro = @import("coro");
const folio = @import("root.zig");

const posix = std.posix;

// TCP

pub const TCPListener = struct {
    socket: posix.socket_t,

    pub fn init(addr: std.net.Address, backlog: ?u31) !TCPListener {
        var err: aio.Socket.Error = aio.Socket.Error.Success;
        var socket: posix.socket_t = undefined;
        try coro.io.single(aio.Socket{
            .domain = @intCast(addr.any.family),
            .flags = posix.SOCK.STREAM | posix.SOCK.CLOEXEC,
            .protocol = posix.IPPROTO.TCP,
            .out_socket = &socket,
            .out_error = &err,
        });

        if (err != aio.Socket.Error.Success) return err;

        try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        if (@hasDecl(posix.SO, "REUSEPORT")) {
            try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
        }

        try posix.bind(socket, &addr.any, addr.getOsSockLen());
        try posix.listen(socket, backlog orelse 128);

        return .{ .socket = socket };
    }

    pub fn deinit(self: TCPListener) !void {
        try coro.io.single(aio.CloseSocket{ .socket = self.socket });
    }

    pub fn accept(self: TCPListener) !TCPStream {
        var client = TCPStream{ .socket = undefined };
        try coro.io.single(aio.Accept{
            .socket = self.socket,
            .out_socket = &client.socket,
        });
        return client;
    }
};

pub const TCPStream = struct {
    socket: posix.socket_t,

    pub fn init(addr: std.net.Address) !TCPStream {
        var err1: aio.Socket.Error = aio.Socket.Error.Success;
        var socket: posix.socket_t = undefined;
        try coro.io.single(aio.Socket{
            .domain = @intCast(addr.any.family),
            .flags = posix.SOCK.STREAM | posix.SOCK.CLOEXEC,
            .protocol = posix.IPPROTO.TCP,
            .out_socket = &socket,
            .out_error = &err1,
        });

        if (err1 != aio.Socket.Error.Success) return err1;

        var err2: aio.Connect.Error = aio.Connect.Error.Success;
        try coro.io.single(aio.Connect{
            .socket = socket,
            .addr = &addr.any,
            .addrlen = addr.getOsSockLen(),
            .out_error = &err2,
        });

        if (err2 != aio.Socket.Error.Success) return err2;

        return .{ .socket = socket };
    }

    pub fn deinit(self: *TCPStream) !void {
        try coro.io.single(aio.CloseSocket{ .socket = self.socket });
    }

    pub fn peerAddress(self: *TCPStream) !std.net.Address {
        var addr: std.net.Address = undefined;
        var socklen: posix.socklen_t = 0;
        try posix.getpeername(self.socket, @ptrCast(&addr.any), &socklen);
        return addr;
    }

    // RECV

    pub inline fn recv(self: TCPStream, buf: []u8) !usize {
        var amt: usize = 0;
        try coro.io.single(aio.Recv{
            .socket = self.socket,
            .buffer = buf,
            .out_read = &amt,
        });
        return amt;
    }

    const ReadT = @typeInfo(@TypeOf(recv)).Fn.return_type.?;
    pub const Reader = std.io.Reader(TCPStream, @typeInfo(ReadT).ErrorUnion.error_set, recv);
    pub fn reader(self: TCPStream) Reader {
        return .{ .context = self };
    }

    // SEND

    pub inline fn send(self: TCPStream, data: []const u8) !usize {
        var amt: usize = 0;
        try coro.io.single(aio.Send{
            .socket = self.socket,
            .buffer = data,
            .out_written = &amt,
        });
        return amt;
    }

    const WriteT = @typeInfo(@TypeOf(send)).Fn.return_type.?;
    pub const Writer = std.io.Writer(TCPStream, @typeInfo(WriteT).ErrorUnion.error_set, send);
    pub fn writer(self: TCPStream) Writer {
        return .{ .context = self };
    }
};

// UDP

pub const UDPStream = struct {
    socket: posix.socket_t,

    pub fn init(addr: std.net.Address) !UDPStream {
        var err: aio.Socket.Error = aio.Socket.Error.Success;
        var socket: posix.socket_t = undefined;
        try coro.io.single(aio.Socket{
            .domain = @intCast(addr.any.family),
            .flags = posix.SOCK.DGRAM | posix.SOCK.CLOEXEC,
            .protocol = posix.IPPROTO.UDP,
            .out_socket = &socket,
            .out_error = &err,
        });

        if (err != aio.Socket.Error.Success) return err;

        return .{ .socket = socket };
    }

    pub fn bind(self: UDPStream, addr: std.net.Address) !void {
        try posix.setsockopt(self.socket, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        if (@hasDecl(posix.SO, "REUSEPORT")) {
            try posix.setsockopt(self.socket, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
        }

        try posix.bind(self.socket, &addr.any, addr.getOsSockLen());
    }

    pub fn connect(self: UDPStream, addr: std.net.Address) !void {
        var err: aio.Connect.Error = aio.Connect.Error.Success;
        try coro.io.single(aio.Connect{
            .socket = self.socket,
            .addr = &addr.any,
            .addrlen = addr.getOsSockLen(),
            .out_error = &err,
        });

        if (err != aio.Socket.Error.Success) return err;
    }

    pub fn deinit(self: UDPStream) !void {
        try coro.io.single(aio.CloseSocket{ .socket = self.socket });
    }

    // RECV

    pub fn recvFrom(self: UDPStream, buf: []u8) !struct { usize, std.net.Address } {
        var addr_buffer: posix.sockaddr.storage = undefined;
        var iovarr = [1]posix.iovec{.{ .base = buf.ptr, .len = buf.len }};
        var amt: usize = 0;

        var msghdr = posix.msghdr{
            .name = @ptrCast(&addr_buffer),
            .namelen = @sizeOf(@TypeOf(addr_buffer)),
            .iov = @ptrCast(@constCast(&iovarr[0..])),
            .iovlen = 1,
            .control = null,
            .controllen = 0,
            .flags = 0,
        };

        try coro.io.single(aio.RecvMsg{
            .socket = self.socket,
            .out_msg = &msghdr,
            .out_read = &amt,
        });

        return .{ amt, std.net.Address.initPosix(@ptrCast(&addr_buffer)) };
    }

    pub inline fn recv(self: UDPStream, buf: []u8) !usize {
        var amt: usize = 0;
        try coro.io.single(aio.Recv{
            .socket = self.socket,
            .buffer = buf,
            .out_read = &amt,
        });
        return amt;
    }

    const ReadT = @typeInfo(@TypeOf(recv)).Fn.return_type.?;
    pub const Reader = std.io.Reader(UDPStream, @typeInfo(ReadT).ErrorUnion.error_set, recv);
    pub fn reader(self: UDPStream) Reader {
        return .{ .context = self };
    }

    // SEND

    pub fn sendTo(self: UDPStream, addr: std.net.Address, data: []const u8) !usize {
        const iovarr = [1]posix.iovec_const{.{ .base = data.ptr, .len = data.len }};
        var amt: usize = 0;

        const msghdr = posix.msghdr_const{
            .name = &addr.any,
            .namelen = addr.getOsSockLen(),
            .iov = @ptrCast(&iovarr[0..]),
            .iovlen = 1,
            .control = null,
            .controllen = 0,
            .flags = 0,
        };

        try coro.io.single(aio.SendMsg{
            .socket = self.socket,
            .msg = &msghdr,
            .out_written = &amt,
        });

        return amt;
    }

    pub inline fn send(self: UDPStream, data: []const u8) !usize {
        var amt: usize = 0;
        try coro.io.single(aio.Send{
            .socket = self.socket,
            .buffer = data,
            .out_written = &amt,
        });
        return amt;
    }

    const WriteT = @typeInfo(@TypeOf(send)).Fn.return_type.?;
    pub const Writer = std.io.Writer(UDPStream, @typeInfo(WriteT).ErrorUnion.error_set, send);
    pub fn writer(self: UDPStream) Writer {
        return .{ .context = self };
    }
};
