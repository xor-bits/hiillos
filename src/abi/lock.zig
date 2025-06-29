const std = @import("std");
const builtin = @import("builtin");

const caps = @import("caps.zig");
const conf = @import("conf.zig");
const sys = @import("sys.zig");

const log = std.log.scoped(.lock);
const Error = sys.Error;

//

pub const CapMutex = struct {
    inner: SpinMutex = .{},
    notify: caps.Notify,
    sleepers: std.atomic.Value(bool) = .init(false),

    const Self = @This();

    pub fn new() Error!Self {
        return .{ .inner = .new(), .notify = try caps.Notify.create() };
    }

    pub fn newLocked() Error!Self {
        return .{ .inner = .newLocked(), .notify = try caps.Notify.create() };
    }

    pub fn deinit(self: Self) void {
        self.notify.close();
    }

    pub fn tryLock(self: *Self) bool {
        return self.inner.tryLock();
    }

    pub fn lock(self: *Self) void {
        if (self.tryLock()) {
            return;
        } else {
            @branchHint(.cold);
        }

        var counter = if (conf.IS_DEBUG) @as(usize, 0) else {};
        while (true) {
            if (conf.IS_DEBUG) {
                counter += 1;
                if (counter % 2_000 == 0) {
                    log.warn("possible deadlock", .{});
                }
            }

            self.sleepers.store(true, .seq_cst);
            self.notify.wait() catch unreachable; // notify cap shouldnt be invalid
            if (self.tryLock()) return;
        }
    }

    pub fn isLocked(self: *Self) bool {
        return self.inner.isLocked();
    }

    pub fn unlock(self: *Self) void {
        self.inner.unlock();
        _ = self.notify.notify() catch unreachable;
    }
};

pub const YieldMutex = struct {
    inner: SpinMutex = .{},

    const Self = @This();

    pub fn new() Self {
        return .{ .inner = .new() };
    }

    pub fn newLocked() Self {
        return .{ .inner = .newLocked() };
    }

    pub fn tryLock(self: *Self) bool {
        return self.inner.tryLock();
    }

    pub fn lock(self: *Self) void {
        if (self.tryLock()) return;

        var counter = if (conf.IS_DEBUG) @as(usize, 0) else {};
        while (true) {
            if (conf.IS_DEBUG) {
                counter += 1;
                if (counter % 2_000 == 0) {
                    log.warn("possible deadlock", .{});
                }
            }

            sys.selfYield();
            if (self.tryLock()) return;
        }
    }

    pub fn isLocked(self: *Self) bool {
        return self.inner.isLocked();
    }

    pub fn unlock(self: *Self) void {
        self.inner.unlock();
    }
};

pub const SpinMutex = struct {
    lock_state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    const Self = @This();

    pub fn new() Self {
        return .{ .lock_state = std.atomic.Value(u8).init(0) };
    }

    pub fn newLocked() Self {
        return .{ .lock_state = std.atomic.Value(u8).init(1) };
    }

    pub fn lock(self: *Self) void {
        var counter = if (conf.IS_DEBUG) @as(usize, 0) else {};
        while (null != self.lock_state.cmpxchgWeak(0, 1, .acquire, .monotonic)) {
            while (self.isLocked()) {
                if (conf.IS_DEBUG) {
                    counter += 1;
                    if (counter % 10_000 == 0) {
                        log.warn("possible deadlock", .{});
                    }
                }
                std.atomic.spinLoopHint();
            }
        }
    }

    pub fn tryLock(self: *Self) bool {
        if (null == self.lock_state.cmpxchgStrong(0, 1, .acquire, .monotonic)) {
            @branchHint(.likely);
            return true;
        } else {
            @branchHint(.cold);
            return false;
        }
    }

    pub fn isLocked(self: *Self) bool {
        return self.lock_state.load(.monotonic) == 1;
    }

    pub fn unlock(self: *Self) void {
        self.lock_state.store(0, .release);
    }
};
