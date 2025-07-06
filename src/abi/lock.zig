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

    pub fn lockAttempts(self: *Self, attempts: usize) bool {
        std.debug.assert(attempts != 0);

        if (self.tryLock()) return;

        for (0..attempts - 1) |_| {
            self.sleepers.store(true, .seq_cst);
            self.notify.wait();
            if (self.tryLock()) return true;
        }
        return false;
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

            self.sleepers.store(true, .seq_cst);
            self.notify.wait();
            if (self.tryLock()) return;
        }
    }

    pub fn isLocked(self: *Self) bool {
        return self.inner.isLocked();
    }

    pub fn unlock(self: *Self) void {
        self.inner.unlock();
        _ = self.notify.notify();
    }
};

pub const YieldMutex = extern struct {
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

    pub fn lockAttempts(self: *Self, attempts: usize) bool {
        std.debug.assert(attempts != 0);

        if (self.tryLock()) return true;

        for (0..attempts - 1) |_| {
            sys.selfYield();
            if (self.tryLock()) return true;
        }
        return false;
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

pub const SpinMutex = extern struct {
    lock_state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    const Self = @This();

    pub fn new() Self {
        return .{ .lock_state = std.atomic.Value(u8).init(0) };
    }

    pub fn newLocked() Self {
        return .{ .lock_state = std.atomic.Value(u8).init(1) };
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

    pub fn lockAttempts(self: *Self, attempts: usize) bool {
        std.debug.assert(attempts != 0);

        if (self.tryLock()) return true;

        for (0..attempts - 1) |_| {
            if (self.tryLock()) return true;
        }
        return false;
    }

    pub fn lock(self: *Self) void {
        var counter = if (conf.IS_DEBUG) @as(usize, 0) else {};
        while (null != self.lock_state.cmpxchgWeak(0, 1, .acquire, .monotonic)) {
            while (self.isLocked()) {
                if (conf.IS_DEBUG) {
                    counter += 1;
                    if (counter % 100_000 == 0) {
                        log.warn("possible deadlock", .{});
                    }
                }
                std.atomic.spinLoopHint();
            }
        }
    }

    pub fn isLocked(self: *Self) bool {
        return self.lock_state.load(.monotonic) != 0;
    }

    pub fn unlock(self: *Self) void {
        if (conf.IS_DEBUG)
            std.debug.assert(self.lock_state.load(.seq_cst) == 1);

        self.lock_state.store(0, .release);
    }
};

pub fn Once(comptime Mutex: type) type {
    return struct {
        entry_mutex: Mutex = .new(),
        wait_mutex: Mutex = .newLocked(),

        const Self = @This();

        pub fn new() Self {
            return .{};
        }

        /// try init whatever resource
        /// false => some other CPU did it, call `wait`
        /// true  => this CPU is doing it, call `complete` once done
        pub fn tryRun(self: *Self) bool {
            return self.entry_mutex.tryLock();
        }

        pub fn wait(self: *Self) void {
            // some other cpu is already working on this,
            // wait for it to be complete and then return
            self.wait_mutex.lock();
            self.wait_mutex.unlock();
        }

        pub fn complete(self: *Self) void {
            // unlock wait_spin to signal others
            self.wait_mutex.unlock();
        }
    };
}
