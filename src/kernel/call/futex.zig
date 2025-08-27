const abi = @import("abi");
const std = @import("std");

const addr = @import("../addr.zig");
const arch = @import("../arch.zig");
const caps = @import("../caps.zig");
const pmem = @import("../pmem.zig");
const proc = @import("../proc.zig");

const util = abi.util;
const conf = abi.conf;
const Error = abi.sys.Error;

//

pub fn wait(
    trap: *arch.TrapRegs,
    thread: *caps.Thread,
) Error!void {
    const futex_ptr = try addr.Virt.fromUser(trap.arg0);
    const value = trap.arg1;
    const flags = abi.sys.FutexFlags.fromInt(@truncate(trap.arg2));

    // TODO: sizes other than u32 and private mode
    if (flags.private or flags.size != .bits32) {
        return Error.Unimplemented;
    }

    const futex = try physAddr(*std.atomic.Value(u32), thread, futex_ptr);
    if (futex.load(.acquire) != value) {
        // early fail
        return;
    }

    proc.switchFrom(trap, thread); // switch away before locking, to hold the lock less
    try waitValidated(u32, futex, @truncate(value), thread);
    proc.switchNow(trap);
}

pub fn wake(
    trap: *arch.TrapRegs,
    thread: *caps.Thread,
) Error!void {
    const futex_ptr = try addr.Virt.fromUser(trap.arg0);
    const count = trap.arg1;
    const flags = abi.sys.FutexFlags.fromInt(@truncate(trap.arg2));

    // TODO: private mode
    if (flags.private) {
        return Error.Unimplemented;
    }

    const futex = try physAddr(*std.atomic.Value(u32), thread, futex_ptr);
    wakeValidated(u32, futex, count);

    // preempt if a high priority thread was awakened
    proc.yield(trap);
}

pub fn requeue(
    trap: *arch.TrapRegs,
    thread: *caps.Thread,
) Error!void {
    _ = .{ trap, thread };
    return Error.Unimplemented;
}

fn waitValidated(
    comptime T: type,
    futex: *std.atomic.Value(T),
    value: T,
    thread: *caps.Thread,
) Error!void {
    const futex_queue = &futex_queues[addressHash(futex)];
    futex_queue.lock.lock();

    if (futex.load(.acquire) != value) {
        // late fail
        futex_queue.lock.unlock();
        proc.switchUndo(thread);
        return;
    }

    const queue = futex_queue.getRealQueue(futex) catch |err| {
        futex_queue.lock.unlock();
        proc.switchUndo(thread);
        return err;
    };

    // sleep the thread
    thread.lock.lock();
    thread.status = .waiting;
    thread.waiting_cause = .futex;
    if (conf.LOG_FUTEX)
        std.log.debug("futex wait {*}", .{thread});
    thread.lock.unlock();
    thread.pushToQueue(&queue.queue, &queue.lock);

    // switch to a new thread
    futex_queue.lock.unlock();
}

fn wakeValidated(
    comptime T: type,
    futex: *std.atomic.Value(T),
    count: usize,
) void {
    const futex_queue = &futex_queues[addressHash(futex)];
    futex_queue.lock.lock();
    defer futex_queue.lock.unlock();

    const queue = futex_queue.real_queues.get(futex) orelse {
        // nothing to wake up
        return;
    };

    for (0..count) |_| {
        const thread_to_wake_up = caps.Thread.popFromQueue(
            &queue.queue,
            &queue.lock,
        ) orelse {
            // nothing queued on that address anymore, remove the specific queue
            std.debug.assert(futex_queue.real_queues.remove(futex));

            real_queue_allocator_lock.lock();
            defer real_queue_allocator_lock.unlock();
            real_queue_allocator.destroy(queue);

            break;
        };

        if (conf.LOG_FUTEX)
            std.log.debug("futex wake {*}", .{thread_to_wake_up});
        proc.ready(thread_to_wake_up);
    }
}

// find the hhdm address of a futex
fn physAddr(
    comptime T: type,
    thread: *caps.Thread,
    futex_ptr: addr.Virt,
) error{ InvalidAddress, Retry }!T {
    const pointer = @typeInfo(T).pointer;
    const is_write = !pointer.is_const;
    const size = @sizeOf(pointer.child);
    comptime std.debug.assert(size == @alignOf(pointer.child));

    if (!std.mem.isAligned(futex_ptr.raw, size)) {
        return Error.InvalidAddress;
    }

    var data_iter = thread.proc.vmem.data(futex_ptr, is_write);
    defer data_iter.deinit();
    // can fail with Error.Retry or Error.InvalidAddress
    const futex_phys_ptr = try data_iter.next() orelse
        return Error.InvalidAddress;

    // the chunk always ends at page boundry and the address is aligned
    // so the acquired chunk should always be long enough and aligned
    std.debug.assert(futex_phys_ptr.len >= size);

    return @alignCast(@volatileCast(@ptrCast(futex_phys_ptr.ptr)));
}

// just some load balancing, no dos resistance
fn addressHash(paddr: *anyopaque) u8 {
    const input: usize = @intFromPtr(paddr);
    // TODO: get the seed from RDSEED or something
    return @truncate(std.hash.Wyhash.hash(0, std.mem.asBytes(&input)));
}

var futex_queues: [256]FutexQueue = [1]FutexQueue{.{}} ** 256;

const FutexQueue = struct {
    lock: abi.lock.SpinMutex = .{},
    // `RealQueue` needs to be a pointer, because Thread
    // expects pointer stability from the queue it is in
    real_queues: std.AutoHashMapUnmanaged(*anyopaque, *RealQueue) = .{},

    fn getRealQueue(
        self: *@This(),
        futex: *anyopaque,
    ) Error!*RealQueue {
        const queue = self.real_queues.getOrPut(caps.slab_allocator.allocator(), futex) catch {
            return Error.OutOfMemory;
        };
        if (!queue.found_existing) {
            real_queue_allocator_lock.lock();
            defer real_queue_allocator_lock.unlock();
            errdefer std.debug.assert(self.real_queues.remove(futex));
            queue.value_ptr.* = try real_queue_allocator.create();
            queue.value_ptr.*.* = .{};
            queue.value_ptr.*.lock.unlock();
        }

        return queue.value_ptr.*;
    }
};

const RealQueue = struct {
    // this lock doesnt really do anything because to access it,
    // another lock has to be held exclusively
    lock: abi.lock.SpinMutex = .locked(),
    queue: caps.Thread.Queue = .{},
};

var real_queue_allocator: std.heap.MemoryPool(RealQueue) = .init(pmem.page_allocator);
var real_queue_allocator_lock: abi.lock.SpinMutex = .{};
