const std = @import("std");
const coro = @import("coro");
const aio = coro.asyncio;
const xev = @import("xev");

const Thread = std.Thread;
const posix = std.posix;

pub const FrameT = coro.FrameT;

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    lock: Thread.Mutex = .{},
    pool: ?*xev.ThreadPool,
    stack_size: usize = 4 * 1024 * 1024,

    // INIT / DEINIT

    // Initialize a Runtime with an allocator and optional thread stack size.
    // Allocates on the heap and returns a pointer to ensure pointer stability.
    //
    // The default stack size is reduced from Zig's default 16 MiB to 4 MiB.
    pub fn init(allocator: std.mem.Allocator, stack_size: ?usize) !*Runtime {
        var pool: ?*xev.ThreadPool = null;
        if (xev.backend == .epoll or xev.backend == .kqueue) {
            pool = try allocator.create(xev.ThreadPool);
            pool.?.* = xev.ThreadPool.init(.{});
        }

        const runtime = try allocator.create(Runtime);
        runtime.* = .{ .allocator = allocator, .pool = pool };
        if (stack_size) |size| runtime.stack_size = size;
        return runtime;
    }

    pub fn deinit(self: *Runtime) void {
        if (self.pool) |pool| {
            pool.deinit();
            self.allocator.destroy(pool);
        }
        self.allocator.destroy(self);
    }

    // HANDLING THREADS

    fn wrapThread(comptime function: anytype) fn (*ThreadContext, anytype) (@typeInfo(@TypeOf(function)).Fn.return_type orelse @compileError("thread function does not have a return type")) {
        const typ = @typeInfo(@TypeOf(function));
        if (typ != .Fn) @compileError("thread function is not a function");
        if (typ.Fn.params.len == 0) @compileError("thread function must take at least *ThreadContext");
        const arg0 = typ.Fn.params[0].type;
        if (arg0 == null or arg0.? != *ThreadContext) @compileError("thread function first argument type is not *ThreadContext");

        return struct {
            pub fn call(ctx: *ThreadContext, args: anytype) typ.Fn.return_type.? {
                ThreadContext.current = ctx;
                const res = @call(.always_inline, function, .{ctx} ++ args);
                ThreadContext.current = null;
                ctx.deinit();
                return res;
            }
        }.call;
    }

    // Spawn a thread with a ThreadContext so it can execute coroutines.
    // This function is not thread-safe. Only call from the thread the Runtime was created in.
    pub fn spawnThread(self: *Runtime, comptime function: anytype, args: anytype) !Thread {
        return try Thread.spawn(
            .{ .allocator = self.allocator, .stack_size = self.stack_size },
            wrapThread(function),
            .{ try ThreadContext.init(self), args },
        );
    }
};

pub const ThreadContext = struct {
    const Self = @This();
    const StackAllocator = @import("StackAllocator.zig");

    rt: *Runtime,
    exec: *aio.Executor,
    stack_alloc: StackAllocator,

    pub threadlocal var current: ?*ThreadContext = null;

    // INIT / DEINIT

    // Initialize a ThreadContext with a pointer to a Runtime.
    // Allocates on the heap and returns a pointer to ensure pointer stability.
    //
    // Avoid calling this directly. This function is not thread-safe because it assumes it will be called by the same thread the Runtime was made in, usually by Runtime.spawnThread.
    pub fn init(rt: *Runtime) !*Self {
        const loop = try rt.allocator.create(xev.Loop);
        const exec = try rt.allocator.create(aio.Executor);
        loop.* = try xev.Loop.init(.{ .thread_pool = rt.pool });
        exec.* = aio.Executor.init(loop);
        const stack_alloc = try StackAllocator.init();
        const context = try rt.allocator.create(ThreadContext);
        context.* = .{ .rt = rt, .exec = exec, .stack_alloc = stack_alloc };
        return context;
    }

    pub fn deinit(self: *Self) void {
        self.exec.loop.deinit();
        const rt = self.rt;
        rt.lock.lock();
        rt.allocator.destroy(self.exec.loop);
        rt.allocator.destroy(self.exec);
        rt.allocator.destroy(self);
        rt.lock.unlock();
    }

    // MISC

    pub inline fn sleep(self: *Self, ms: u64) !void {
        try aio.sleep(self.exec, ms);
    }

    pub fn xasync(self: *Self, func: anytype, args: anytype) !coro.FrameT(func, .{ .ArgsT = @TypeOf(args) }) {
        const stack = try self.stack_alloc.get();
        return coro.xasync(func, args, stack);
    }

    pub fn xawait(self: *Self, frame: anytype) @TypeOf(frame).Signature.ReturnT() {
        defer self.stack_alloc.free(frame.frame().stack);
        return coro.xawait(frame);
    }
};

// NETWORKING - TCP

pub const TCPListener = struct {
    const Self = @This();

    raw: aio.TCP,

    // Initialize a TCPListener with the current ThreadContext.
    // Must be called from a thread spawned by a runtime or a child coroutine.
    pub fn init(addr: std.net.Address, backlog: ?u31) !Self {
        const ctx = ThreadContext.current orelse return error.ContextUnavailable;

        const xev_tcp = try xev.TCP.init(addr);
        if (xev.backend != .iocp) try posix.setsockopt(xev_tcp.fd, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));

        try xev_tcp.bind(addr);
        try xev_tcp.listen(backlog orelse 128);

        return .{ .raw = aio.TCP.init(ctx.exec, xev_tcp), .addr = addr };
    }

    pub fn accept(self: Self) !TCPStream {
        return .{ .raw = try self.raw.accept() };
    }
};

pub const TCPStream = struct {
    const Self = @This();

    raw: aio.TCP,

    // Initialize a TCPListener with the current ThreadContext.
    // Must be called from a thread spawned by a runtime or a child coroutine.
    pub fn init(addr: std.net.Address) !Self {
        const ctx = ThreadContext.current orelse return error.ContextUnavailable;

        const xev_tcp = try xev.TCP.init(addr);
        if (xev.backend != .iocp) try posix.setsockopt(xev_tcp.fd, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));

        const raw = aio.TCP.init(ctx.exec, xev_tcp);
        try raw.connect(addr);

        return .{ .raw = raw };
    }

    pub fn peerAddress(self: *Self) !std.net.Address {
        var sockaddr: posix.sockaddr align(4) = undefined;
        try posix.getpeername(self.raw.tcp.fd, &sockaddr, &posix.sockaddr.SS_MAXSIZE);
        return std.net.Address.initPosix(&sockaddr);
    }

    // READ

    pub fn read(self: Self, buffer: []u8) !usize {
        return self.raw.read(.{ .slice = buffer });
    }

    const ReadT = @typeInfo(@TypeOf(read)).Fn.return_type.?;
    pub const Reader = std.io.Reader(Self, @typeInfo(ReadT).ErrorUnion.error_set, read);
    pub fn reader(self: Self) Reader {
        return .{ .context = self };
    }

    // WRITE

    pub fn write(self: Self, bytes: []const u8) !usize {
        return self.raw.write(.{ .slice = bytes });
    }

    const WriteT = @typeInfo(@TypeOf(write)).Fn.return_type.?;
    pub const Writer = std.io.Writer(Self, @typeInfo(WriteT).ErrorUnion.error_set, write);
    pub fn writer(self: Self) Writer {
        return .{ .context = self };
    }
};

// NETWORKING - UDP

pub const UDPStream = struct {
    const Self = @This();

    raw: aio.UDP,

    pub fn init(addr: std.net.Address) !Self {
        const ctx = ThreadContext.current orelse return error.ContextUnavailable;
        return .{ .raw = aio.UDP.init(ctx.exec, try xev.UDP.init(addr)) };
    }

    // CONNECTION

    pub const Connected = struct {
        stream: Self,
        addr: std.net.Address,

        pub inline fn write(self: Connected, bytes: []const u8) !usize {
            return self.stream.raw.write(self.addr, .{ .slice = bytes });
        }

        pub inline fn read(self: Connected, buffer: []const u8) !usize {
            return self.stream.raw.read(self.addr, .{ .slice = buffer });
        }
    };

    pub inline fn connect(self: Self, addr: std.net.Address) Connected {
        return .{ .stream = self, .addr = addr };
    }

    // READ

    pub inline fn readFrom(self: Self, buffer: []const u8) !struct { usize, std.net.Address } {
        return self.raw.read(null, .{ .slice = buffer });
    }

    const ReadT = @typeInfo(@TypeOf(Connected.read)).Fn.return_type.?;
    pub const Reader = std.io.Reader(Connected, @typeInfo(ReadT).ErrorUnion.error_set, Connected.read);
    pub inline fn reader(self: Self, addr: std.net.Address) Reader {
        return .{ .context = .{ .stream = self, .addr = addr } };
    }

    // WRITE

    pub inline fn writeTo(self: Self, addr: std.net.Address, bytes: []const u8) !usize {
        return self.raw.write(addr, .{ .slice = bytes });
    }

    const WriteT = @typeInfo(@TypeOf(Connected.write)).Fn.return_type.?;
    pub const Writer = std.io.Writer(Connected, @typeInfo(WriteT).ErrorUnion.error_set, Connected.write);
    pub inline fn writer(self: Self, addr: std.net.Address) Writer {
        return .{ .context = .{ .stream = self, .addr = addr } };
    }
};
