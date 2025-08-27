const std = @import("std");
const abi = @import("abi");

const spinner = @import("spinner.zig");

//

const caps = abi.caps;
const log = std.log.scoped(.init);

//

pub fn main() !void {
    try abi.rt.init();
    log.info("hello from init", .{});

    if (abi.conf.SCHED_STRESS_TEST) {
        for (0..100) |_| {
            try abi.thread.spawn(yieldStressTest, .{});
        }
    }

    if (abi.conf.SCHED_STRESS_TEST) {
        const notify = try caps.Notify.create();
        defer notify.close();
        for (0..100) |_| {
            try abi.thread.spawn(notifyStressTest, .{try notify.clone()});
        }
        for (0..100) |_| {
            try abi.thread.spawn(notifyWaitStressTest, .{try notify.clone()});
        }
        for (0..100) |_| {
            try abi.thread.spawn(notifyPollStressTest, .{try notify.clone()});
        }
    }

    if (abi.conf.FUTEX_STRESS_TEST) {
        for (0..100) |i| {
            try abi.thread.spawn(futexStressTest, .{i});
        }
    }

    try spinner.spinnerMain();
}

fn yieldStressTest() noreturn {
    while (true) abi.thread.yield();
}

fn notifyStressTest(notify: caps.Notify) !noreturn {
    defer notify.close();
    while (true) _ = try notify.notify();
}

fn notifyWaitStressTest(notify: caps.Notify) !noreturn {
    defer notify.close();
    while (true) try notify.wait();
}

fn notifyPollStressTest(notify: caps.Notify) !noreturn {
    defer notify.close();
    while (true) _ = try notify.poll();
}

var mutex: abi.lock.Futex = .{};
var check: abi.lock.SpinMutex = .{};

fn futexStressTest(i: usize) noreturn {
    while (true) {
        abi.thread.yield();
        for (0..1_000 * (i + 1)) |_| std.atomic.spinLoopHint();

        mutex.lock();
        defer mutex.unlock();

        for (0..1_000 * (i + 1)) |_| std.atomic.spinLoopHint();

        log.info("lock acquired by {}", .{i});
        if (!check.tryLock()) std.debug.panic("fail", .{});
        check.unlock();
    }
}
