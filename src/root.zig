const std = @import("std");

const aio = @import("aio");
const coro = @import("coro");
const minilib = @import("minilib");

const Thread = std.Thread;
const ThreadPool = coro.ThreadPool;

pub const net = @import("net.zig");

pub const Task = coro.Task;
pub const SpawnError = coro.Scheduler.SpawnError;

// RUNTIME

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    pool: ThreadPool,
    stack_size: usize,

    // INIT / DEINIT

    // Initialize a Runtime with an allocator.
    // The provided allocator is assumed to be thread-safe!
    // Allocates on the heap and returns a pointer to ensure pointer stability.
    //
    // The default stack size is reduced from Zig's default 16 MiB to 4 MiB.
    pub inline fn init(allocator: std.mem.Allocator) !*Runtime {
        return Runtime.withStackSize(allocator, 4 * 1024 * 1024);
    }

    // Initialize a Runtime with an allocator and thread/task stack size.
    // The provided allocator is assumed to be thread-safe!
    // Allocates on the heap and returns a pointer to ensure pointer stability.
    pub fn withStackSize(allocator: std.mem.Allocator, stack_size: usize) !*Runtime {
        const runtime = try allocator.create(Runtime);
        runtime.* = .{
            .allocator = allocator,
            .pool = try ThreadPool.init(allocator, .{}),
            .stack_size = stack_size,
        };
        return runtime;
    }

    pub inline fn deinit(self: *Runtime) void {
        self.pool.deinit();
        self.allocator.destroy(self);
    }

    // WORKERS

    fn wrapWorker(comptime func: anytype) fn (*WorkerContext, anytype) (@typeInfo(@TypeOf(func)).Fn.return_type.?) {
        const typ = @typeInfo(@TypeOf(func));
        if (typ != .Fn) @compileError("worker function is not a function");
        if (typ.Fn.return_type == null) @compileError("worker function does not have a return type");

        return struct {
            pub fn call(ctx: *WorkerContext, args: anytype) typ.Fn.return_type.? {
                defer if (WorkerContext.current) |self| {
                    WorkerContext.current = null;
                    self.sched.deinit();
                    self.rt.allocator.destroy(self);
                };
                WorkerContext.current = ctx;
                return @call(.always_inline, func, args);
            }
        }.call;
    }

    // Spawn a thread and set up a WorkerContext so it can execute coroutines.
    // This function is not thread-safe. Only call from the thread the Runtime was created in.
    pub fn spawnWorker(self: *Runtime, comptime function: anytype, args: anytype) !Thread {
        const config = .{ .allocator = self.allocator, .stack_size = self.stack_size };
        const ctx = try self.allocator.create(WorkerContext);
        ctx.* = .{ .rt = self, .sched = try coro.Scheduler.init(self.allocator, .{}) };
        return Thread.spawn(config, wrapWorker(function), .{ ctx, args });
    }

    // TASKS

    pub inline fn yieldWhileBlocking(self: *Runtime, func: anytype, args: anytype) !void {
        const config = .{ .allocator = self.allocator, .stack_size = self.stack_size };
        return self.pool.spawnForCompletition(self.sched, func, args, config);
    }
};

// WORKER CONTEXT

pub const WorkerContext = struct {
    rt: *Runtime,
    sched: coro.Scheduler,

    pub threadlocal var current: ?*WorkerContext = null;

    // TASKS

    pub inline fn spawn(self: *WorkerContext, comptime func: anytype, args: anytype) SpawnError!Task.Generic(minilib.ReturnType(func)) {
        return self.sched.spawn(func, args, .{});
    }

    pub inline fn spawnBlocking(self: *WorkerContext, func: anytype, args: anytype) !void {
        const config = .{ .allocator = self.rt.allocator, .stack_size = self.rt.stack_size };
        return self.rt.pool.spawnForCompletition(self.sched, func, args, config);
    }
};

// ADDITIONAL HELPERS

pub inline fn yieldWhileBlocking(func: anytype, args: anytype) !void {
    const ctx = WorkerContext.current orelse return error.ContextUnavailable;
    return ctx.rt.yieldWhileBlocking(func, args);
}

pub inline fn spawn(comptime func: anytype, args: anytype) !Task.Generic(minilib.ReturnType(func)) {
    const ctx = WorkerContext.current orelse return error.ContextUnavailable;
    return ctx.spawn(func, args);
}

pub inline fn spawnBlocking(func: anytype, args: anytype) !void {
    const ctx = WorkerContext.current orelse return error.ContextUnavailable;
    return ctx.spawnBlocking(func, args);
}

pub inline fn sleep(nanoseconds: u64) !void {
    try coro.io.single(aio.Timeout{ .ns = @intCast(nanoseconds) });
}

const signal = @import("signal.zig");
pub const ctrlC = signal.ctrlC;
