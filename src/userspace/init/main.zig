const std = @import("std");
const abi = @import("abi");

const spinner = @import("spinner.zig");

//

pub const std_options = abi.std_options;
pub const panic = abi.panic;

const caps = abi.caps;
const log = std.log.scoped(.init);

//

pub fn main() !void {
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

    try spinner.spinnerMain();
}

fn yieldStressTest() void {
    while (true) abi.thread.yield();
}

fn notifyStressTest(notify: caps.Notify) !void {
    defer notify.close();
    while (true) _ = try notify.notify();
}

fn notifyWaitStressTest(notify: caps.Notify) !void {
    defer notify.close();
    while (true) try notify.wait();
}

fn notifyPollStressTest(notify: caps.Notify) !void {
    defer notify.close();
    while (true) _ = try notify.poll();
}

comptime {
    abi.rt.installRuntime();
}
