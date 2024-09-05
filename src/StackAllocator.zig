//! A very simple allocator optimized for handling coroutine stacks.
//! This structure is NOT thread-safe and should ONLY be accessed by the worker thread which owns it.

const std = @import("std");
const coro = @import("coro");

const page_allocator = std.heap.page_allocator;
const page_size = std.mem.page_size;
const page_capacity = page_size / @sizeOf(StackState);

const zero = std.crypto.utils.secureZero;

const Stack = coro.StackT;
const Stacks = std.ArrayList(StackState);
const StackState = struct {
    stack: Stack,
    used: bool = true,
};

const Self = @This();

stacks: Stacks,
// 4kB is common page size and likely sane default
size: usize = 4 * 1024,

pub fn init() !Self {
    return .{ .stacks = try Stacks.initCapacity(page_allocator, page_capacity) };
}

pub fn get(self: *Self) !Stack {
    for (self.stacks.items) |stack| if (!stack.used) return stack.stack;

    // no unused stacks found, allocate a new one
    // adjust stack state list capacity if needed
    if (self.stacks.items.len == self.stacks.capacity) {
        // recalculate capacity for multiple pages to account for page_capacity inaccuracy
        // this will only be inaccurate again after thousands of stacks (unlikely)
        const pages = (self.stacks.capacity / page_capacity) + 1;
        const capacity = (pages * page_size) / @sizeOf(StackState);
        try self.stacks.ensureTotalCapacityPrecise(capacity);
    }

    const stack = try page_allocator.alignedAlloc(u8, coro.stack_alignment, self.size);
    self.stacks.appendAssumeCapacity(.{ .stack = stack });
    return stack;
}

pub fn free(self: Self, freed: Stack) void {
    for (self.stacks.items) |*stack| if (stack.stack.ptr == freed.ptr) {
        stack.used = false;
        zero(u8, stack.stack);
        return;
    };
}
