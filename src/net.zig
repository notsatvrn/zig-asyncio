const std = @import("std");

const aio = @import("aio");
const coro = @import("coro");

const posix = std.posix;

// TCP

pub const TCPListener = struct {
    socket: posix.socket_t,

    pub fn init(addr: std.net.Address, backlog: ?u31) !TCPListener {
        var socket: posix.socket_t = undefined;
        try coro.io.single(aio.Socket{
            .domain = @intCast(addr.any.family),
            .flags = posix.SOCK.STREAM | posix.SOCK.CLOEXEC,
            .protocol = posix.IPPROTO.TCP,
            .out_socket = &socket,
        });

        try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        if (@hasDecl(posix.SO, "REUSEPORT")) {
            try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
        }

        try posix.bind(socket, &addr.any, addr.getOsSockLen());
        try posix.listen(socket, backlog orelse 128);

        return .{ .socket = socket };
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
        var socket: posix.socket_t = undefined;
        try coro.io.multi(aio.Socket{
            .domain = @intCast(addr.any.family),
            .flags = posix.SOCK.STREAM | posix.SOCK.CLOEXEC,
            .protocol = posix.IPPROTO.TCP,
            .out_socket = &socket,
            .link = .soft,
        }, aio.Connect{
            .socket = socket,
            .addr = &addr.any,
            .addrlen = addr.getOsSockLen(),
        });

        return .{ .socket = socket };
    }

    pub fn peerAddress(self: *TCPStream) !std.net.Address {
        var sockaddr: posix.sockaddr align(4) = undefined;
        try posix.getpeername(self.socket, &sockaddr, &posix.sockaddr.SS_MAXSIZE);
        return std.net.Address.initPosix(&sockaddr);
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
        var socket: posix.socket_t = undefined;
        try coro.io.single(aio.Socket{
            .domain = @intCast(addr.any.family),
            .flags = posix.SOCK.DGRAM | posix.SOCK.CLOEXEC,
            .protocol = posix.IPPROTO.UDP,
            .out_socket = &socket,
        });

        try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        if (@hasDecl(posix.SO, "REUSEPORT")) {
            try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
        }

        try posix.bind(socket, &addr.any, addr.getOsSockLen());

        return .{ .socket = socket };
    }

    // RECV

    pub inline fn recvFrom(self: UDPStream, buf: []const u8) !struct { usize, std.net.Address } {
        _ = self;
        _ = buf;
        @compileError("unimplemented");
    }

    // SEND

    pub inline fn sendTo(self: UDPStream, addr: std.net.Address, data: []const u8) !usize {
        _ = self;
        _ = addr;
        _ = data;
        @compileError("unimplemented");
    }
};
