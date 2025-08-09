const abi = @import("abi");
const std = @import("std");

const addr = @import("../addr.zig");
const arch = @import("../arch.zig");
const caps = @import("../caps.zig");
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

    const futex_queue = &futex_queues[addressHash(futex)];
    futex_queue.lock.lock();

    if (futex.load(.acquire) != value) {
        // late fail
        futex_queue.lock.unlock();
        proc.switchUndo(thread);
        return;
    }

    // sleep the thread
    const queue = futex_queue.real_queues.getOrPut(caps.slab_allocator.allocator(), futex) catch {
        futex_queue.lock.unlock();
        proc.switchUndo(thread);
        return Error.OutOfMemory;
    };
    if (!queue.found_existing) queue.value_ptr.* = .{};
    thread.status = .waiting;
    thread.waiting_cause = .futex;
    if (conf.LOG_FUTEX)
        std.log.debug("futex wait {*}", .{thread});
    queue.value_ptr.pushBack(thread);

    // switch to a new thread
    futex_queue.lock.unlock();
    proc.switchNow(trap);
}

pub fn wake(
    trap: *arch.TrapRegs,
    thread: *caps.Thread,
) Error!void {
    const futex_ptr = try addr.Virt.fromUser(trap.arg0);
    var count = trap.arg1;
    const flags = abi.sys.FutexFlags.fromInt(@truncate(trap.arg2));

    // TODO: private mode
    if (flags.private) {
        return Error.Unimplemented;
    }

    const futex = try physAddr(*std.atomic.Value(u8), thread, futex_ptr);

    const futex_queue = &futex_queues[addressHash(futex)];
    futex_queue.lock.lock();

    const queue = futex_queue.real_queues.getPtr(futex) orelse {
        // nothing to wake up
        futex_queue.lock.unlock();
        return;
    };

    while (count != 0) : (count -= 1) {
        const thread_to_wake_up = queue.popFront() orelse {
            // nothing queued on that address anymore, remove the specific queue
            std.debug.assert(futex_queue.real_queues.remove(futex));
            break;
        };
        if (conf.LOG_FUTEX)
            std.log.debug("futex wake {*}", .{thread_to_wake_up});
        proc.ready(thread_to_wake_up);
    }

    // preempt if a high priority thread was awakened
    futex_queue.lock.unlock();
    // proc.yield(trap);
}

pub fn requeue(
    trap: *arch.TrapRegs,
    thread: *caps.Thread,
) Error!void {
    _ = .{ trap, thread };
    return Error.Unimplemented;
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
    real_queues: std.AutoHashMapUnmanaged(*anyopaque, RealQueue) = .{},
};

const RealQueue = util.Queue(caps.Thread, "prev", "next");
