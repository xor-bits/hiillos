const std = @import("std");
const abi = @import("abi");

const addr = @import("addr.zig");
const apic = @import("apic.zig");
const arch = @import("arch.zig");
const caps = @import("caps.zig");
const main = @import("main.zig");

const conf = abi.conf;
const log = std.log.scoped(.proc);
const Error = abi.sys.Error;

//

// TODO: maybe a fastpath ring buffer before the linked list to reduce locking

var active_threads: std.atomic.Value(usize) = .init(1);
var queues: [4]caps.Thread.Queue = .{caps.Thread.Queue{}} ** 4;
var queue_locks: [4]abi.lock.SpinMutex = .{abi.lock.SpinMutex{}} ** 4;
var waiters: [256]Waiter = .{Waiter.init(null)} ** 256;

const Waiter = std.atomic.Value(?*main.CpuLocalStorage);

//

pub fn init() void {
    // the number is 1 by default, starting root makes it 2 and this drops it back to the real 1
    _ = active_threads.fetchSub(1, .seq_cst);
}

/// forgets the current thread and jumps into the main syscall loop
pub fn enter() noreturn {
    var trap: arch.TrapRegs = undefined;
    switchNow(&trap);
    trap.exitNow();
}

/// TODO: yield that can switch to another thread on the same priority
/// conditionally yield if there is a higher priority thread ready
pub fn yield(trap: *arch.TrapRegs) void {
    const prev = arch.cpuLocal().current_thread orelse {
        switchNow(trap);
        return;
    };

    prev.lock.lock();
    const priority = prev.priority;
    prev.checkRunning() catch {
        // previous thread was cancelled
        prev.lock.unlock();
        switchFrom(trap, prev);
        prev.deinit();
        switchNow(trap);
        return;
    };
    prev.lock.unlock();

    const next_thread = tryNextHigherPriority(priority) orelse return;

    yieldReadyPrev(trap, prev);
    switchTo(trap, next_thread);
}

///mark the previous thread as ready
fn yieldReadyPrev(trap: *arch.TrapRegs, prev: ?*caps.Thread) void {
    if (prev) |prev_thread| {
        switchFrom(trap, prev_thread);
        ready(prev_thread);
    }
}

/// switch to another thread without adding the thread back to the ready queue
pub fn switchNow(trap: *arch.TrapRegs) void {
    switchTo(trap, next());
}

/// switch to another thread, skipping the scheduler entirely
/// does **NOT** save the previous context or set its status
pub fn switchTo(trap: *arch.TrapRegs, thread: *caps.Thread) void {
    const local = arch.cpuLocal();
    std.debug.assert(local.current_thread == null);
    local.current_thread = thread;

    thread.switchTo(trap);
}

/// switches away from a thread, but not to another thread
pub fn switchFrom(trap: *const arch.TrapRegs, thread: *caps.Thread) void {
    const local = arch.cpuLocal();
    std.debug.assert(local.current_thread != null);
    local.current_thread = null;

    thread.switchFrom(trap);
}

pub fn switchUndo(thread: *caps.Thread) void {
    const local = arch.cpuLocal();
    std.debug.assert(local.current_thread == null);
    local.current_thread = thread;

    thread.exec_lock.lock();
}

/// stop the thread and (TODO) interrupt a processor that might be running it
pub fn stop(thread: *caps.Thread) void {
    _ = active_threads.fetchSub(1, .release);

    thread.lock.lock();
    std.debug.assert(thread.status != .stopped);
    thread.status = .stopped;
    thread.lock.unlock();

    // FIXME: IPI
    // TODO: stop the processor and take the thread
}

/// takes ownership of the given thread pointer
/// start the thread, if its not running
pub fn start(thread: *caps.Thread) void {
    _ = active_threads.fetchAdd(1, .acquire);
    ready(thread);
}

pub fn ready(thread: *caps.Thread) void {
    thread.lock.lock();
    const prio = thread.priority;
    thread.lock.unlock();

    push(thread, prio);
}

fn push(thread: *caps.Thread, prio: u2) void {
    queues[prio].push(
        &queue_locks[prio],
        thread,
        .{
            .new_status = .ready,
            .new_cause = .none,
        },
    );

    // notify a single sleeping processor
    for (&waiters) |*w| {
        const waiter: *const main.CpuLocalStorage = w.swap(
            null,
            .acquire,
        ) orelse continue;
        if (waiter == arch.cpuLocal()) break;

        // log.info("giving thread to {} ({})", .{ waiter.id, waiter.lapic_id });
        apic.interProcessorInterrupt(
            waiter.lapic_id,
            apic.IRQ_IPI_PREEMPT,
        );
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
        return queue.pop(lock) orelse continue;
    }

    return null;
}

pub fn tryNext() ?*caps.Thread {
    return tryNextHigherPriority(@intCast(queues.len));
}
