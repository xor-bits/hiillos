const std = @import("std");
const builtin = @import("builtin");

const caps = @import("caps.zig");
const conf = @import("conf.zig");
const sys = @import("sys.zig");

const log = std.log.scoped(.lock);
const Error = sys.Error;

//

const State = packed struct {
    waiting: u31 = 0,
    locked: bool = false,
};

pub const Futex = extern struct {
    state: std.atomic.Value(u32) = .init(@bitCast(State{ .locked = false })),

    const Self = @This();

    pub fn locked() Self {
        return .{ .state = .init(@bitCast(State{ .locked = true })) };
    }

    pub fn isLocked(self: *Self) bool {
        return self.load(.monotonic).locked;
    }

    pub fn tryLock(self: *Self) bool {
        var state: State = self.load(.monotonic);
        while (true) {
            if (state.locked)
                return Self.tryLockSlow();

            // set the state to locked
            if (self.cmpxchg(.weak, state, State{
                .waiting = state.waiting,
                .locked = true,
            }, .acquire, .monotonic)) |failed| {
                // failed to lock, either spuriously or it was locked
                state = failed;
                continue;
            } else {
                // successfully locked
                return true;
            }
        }
    }

    fn tryLockSlow() bool {
        @branchHint(.cold);
        return false;
    }

    pub fn lock(self: *Self) void {
        var state: State = self.load(.monotonic);
        while (true) {
            if (state.locked or state.waiting != 0)
                return self.lockSlow(state);

            // set the state to locked
            if (self.cmpxchg(.weak, state, State{
                .waiting = state.waiting,
                .locked = true,
            }, .acquire, .monotonic)) |failed| {
                // failed to lock, either spuriously or it was locked
                state = failed;
                continue;
            } else {
                // successfully locked
                return;
            }
        }
    }

    fn lockSlow(self: *Self, _state: State) void {
        @branchHint(.cold);

        var state = _state;
        var registered = false;
        while (true) {
            if (!state.locked) {
                // set the state to locked
                if (self.cmpxchg(.weak, state, State{
                    .waiting = state.waiting,
                    .locked = true,
                }, .acquire, .monotonic)) |failed| {
                    // failed to lock, either spuriously or it was locked
                    state = failed;
                    continue;
                } else {
                    // successfully locked
                    return;
                }
            }

            // TODO: could spin a few times before actually waiting

            if (!registered) {
                if (state.waiting >= std.math.maxInt(u31))
                    std.debug.panic("too many threads waiting on the same futex", .{});

                if (self.cmpxchg(.weak, state, State{
                    .waiting = state.waiting + 1,
                    .locked = state.locked,
                }, .monotonic, .monotonic)) |failed| {
                    // failed to increase waiter count
                    state = failed;
                    continue;
                }
                // successfully incremented the sleeper count
                registered = true;
                state.waiting += 1;
            }

            sys.futexWait(&self.state.raw, @as(u32, @bitCast(state)), .{
                .size = .bits32,
            }) catch unreachable;

            state = self.load(.monotonic);
        }
    }

    pub fn unlock(self: *Self) void {
        var state = State{ .waiting = 0, .locked = true };
        while (true) {
            std.debug.assert(state.locked);
            if (state.waiting != 0)
                self.unlockSlow(state);

            // set the state to unlocked
            if (self.cmpxchg(.strong, state, State{
                .waiting = 0,
                .locked = false,
            }, .release, .monotonic)) |failed| {
                // failed to unlock, either spuriously or there were sleepers
                state = failed;
                continue;
            } else {
                // successfully unlocked
                return;
            }
        }
    }

    fn unlockSlow(self: *Self, _state: State) void {
        @branchHint(.cold);

        var state = _state;
        while (true) {
            std.debug.assert(state.locked);

            // set the state to unlocked
            if (self.cmpxchg(.weak, state, State{
                .waiting = state.waiting -| 1,
                .locked = false,
            }, .release, .monotonic)) |failed| {
                // failed to unlock, either spuriously or there are new sleepers
                state = failed;
                continue;
            } else {
                sys.futexWake(&self.state.raw, 1, .{
                    .size = .bits32,
                }) catch unreachable;
                return;
            }
        }
    }

    fn cmpxchg(
        self: *Self,
        comptime variant: enum { weak, strong },
        expected: State,
        new: State,
        comptime success: std.builtin.AtomicOrder,
        comptime fail: std.builtin.AtomicOrder,
    ) ?State {
        const func = if (variant == .strong) std.atomic.Value(u32).cmpxchgStrong else std.atomic.Value(u32).cmpxchgWeak;
        if (func(
            &self.state,
            @bitCast(expected),
            @bitCast(new),
            success,
            fail,
        )) |result| {
            return @bitCast(result);
        } else {
            return null;
        }
    }

    fn load(self: *Self, comptime order: std.builtin.AtomicOrder) State {
        return @bitCast(self.state.load(order));
    }
};

/// Deprecated; prefer using `Futex`.
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

        if (self.tryLock()) return true;

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

/// Deprecated; prefer using `Futex`.
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

pub const Backoff = struct {
    n: usize = 1,

    pub fn spin(self: *@This()) void {
        for (0..self.n) |_| {
            std.atomic.spinLoopHint();
        }

        self.n *|= 3;
        self.n /= 2;
    }
};
