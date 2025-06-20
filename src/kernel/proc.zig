const std = @import("std");
const abi = @import("abi");

const addr = @import("addr.zig");
const apic = @import("apic.zig");
const arch = @import("arch.zig");
const caps = @import("caps.zig");
const main = @import("main.zig");
const spin = @import("spin.zig");
const util = @import("util.zig");

const conf = abi.conf;
const log = std.log.scoped(.proc);
const Error = abi.sys.Error;

//

// TODO: maybe a fastpath ring buffer before the linked list to reduce locking

var active_threads: std.atomic.Value(usize) = .init(1);
var queues: [4]Queue = .{Queue{}} ** 4;
var queue_locks: [4]spin.Mutex = .{spin.Mutex{}} ** 4;
var waiters: [256]Waiter = .{Waiter.init(null)} ** 256;

const Queue = util.Queue(caps.Thread, "next", "prev");
const Waiter = std.atomic.Value(?*main.CpuLocalStorage);

//

pub fn init() void {
    // the number is 1 by default, starting root makes it 2 and this drops it back to the real 1
    _ = active_threads.fetchSub(1, .seq_cst);
}

/// forgets the current thread and jumps into the main syscall loop
pub fn enter() noreturn {
    var trap: arch.TrapRegs = undefined;
    switchNow(&trap, null);
    trap.exitNow();
}

/// conditionally yield if there is a higher priority thread ready
pub fn yield(trap: *arch.TrapRegs) void {
    const prev = arch.cpuLocal().current_thread;

    const priority: u8 = if (prev) |_prev| _prev.priority else @intCast(queues.len);
    const next_thread = tryNextHigherPriority(priority) orelse return;

    // clone the previous thread temporarily, because this function still
    // uses it after another thread can take ownership of it and delete it
    if (prev) |p| _ = p.clone();
    defer if (prev) |p| p.deinit();

    yieldReadyPrev(trap, prev);

    switchTo(trap, next_thread, prev);
}

///mark the previous thread as ready
fn yieldReadyPrev(trap: *arch.TrapRegs, prev: ?*caps.Thread) void {
    if (prev) |prev_thread| {
        arch.cpuLocal().current_thread = null;
        prev_thread.trap = trap.*;

        switch (prev_thread.status) {
            .ready, .running => {
                prev_thread.status = .waiting;
                ready(prev_thread);
            },
            .stopped, .waiting => {},
        }
    }
}

/// switch to another thread without adding the thread back to the ready queue
pub fn switchNow(trap: *arch.TrapRegs, prev: ?*caps.Thread) void {
    switchTo(trap, next(), prev);
}

/// switch to another thread, skipping the scheduler entirely
/// does **NOT** save the previous context or set its status
pub fn switchTo(trap: *arch.TrapRegs, thread: *caps.Thread, prev: ?*caps.Thread) void {
    const local = arch.cpuLocal();
    local.current_thread = thread;
    trap.* = thread.trap;
    thread.status = .running;

    if (thread == prev)
        return;
    thread.proc.vmem.switchTo();

    if (conf.LOG_CTX_SWITCHES)
        log.debug("switch to {*}", .{thread});
}

/// stop the thread and (TODO) interrupt a processor that might be running it
pub fn stop(thread: *caps.Thread) void {
    std.debug.assert(thread.status != .stopped);

    thread.status = .stopped;
    _ = active_threads.fetchSub(1, .release);
    // FIXME: IPI
    // TODO: stop the processor and take the thread
}

/// takes ownership of the given thread pointer
/// start the thread, if its not running
pub fn start(thread: *caps.Thread) void {
    std.debug.assert(thread.status == .stopped);

    _ = active_threads.fetchAdd(1, .acquire);
    ready(thread);
}

pub fn ready(thread: *caps.Thread) void {
    const prio = thread.priority;
    std.debug.assert(thread.status != .ready and thread.status != .running);
    thread.status = .ready;

    queue_locks[prio].lock();
    queues[prio].pushBack(thread);
    queue_locks[prio].unlock();

    // notify a single sleeping processor
    for (&waiters) |*w| {
        const waiter: *const main.CpuLocalStorage = w.swap(null, .acquire) orelse continue;
        if (waiter == arch.cpuLocal()) break;

        // log.info("giving thread to {} ({})", .{ waiter.id, waiter.lapic_id });
        apic.interProcessorInterrupt(waiter.lapic_id, apic.IRQ_IPI);
        break;
    }

    // TODO: else notify the lowest priority processor
    // (if its current priority is lower than this new one)
}

pub fn next() *caps.Thread {
    if (active_threads.load(.monotonic) == 0) {
        log.err("NO ACTIVE THREADS", .{});
        log.err("THIS IS A USER-SPACE ERROR", .{});
        log.err("SYSTEM HALT UNTIL REBOOT", .{});
        // arch.hcf();
    }

    if (tryNext()) |next_thread| return next_thread;

    if (conf.LOG_WAITING)
        log.debug("waiting for next thread", .{});
    defer if (conf.LOG_WAITING)
        log.debug("next thread acquired", .{});

    while (true) {
        const locals = arch.cpuLocal();
        waiters[locals.id].store(locals, .seq_cst);
        arch.ints.wait();

        if (tryNext()) |next_thread| return next_thread;
    }
}

pub fn tryNextHigherPriority(current: u8) ?*caps.Thread {
    for (queue_locks[0..current], queues[0..current]) |*lock, *queue| {
        lock.lock();
        const _next_thread = queue.popFront();
        lock.unlock();

        if (_next_thread) |next_thread| {
            if (next_thread.status == .stopped) {
                continue;
            } else {
                return next_thread;
            }
        }
    }

    return null;
}

pub fn tryNext() ?*caps.Thread {
    return tryNextHigherPriority(@intCast(queues.len));
}
