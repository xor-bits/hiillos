const std = @import("std");
const builtin = @import("builtin");

const caps = @import("caps.zig");
const conf = @import("conf.zig");
const sys = @import("sys.zig");

const log = std.log.scoped(.lock);
const Error = sys.Error;

//

pub const Futex = extern struct {
    state: std.atomic.Value(u32) = .init(@bitCast(State{ .locked = false })),

    const Self = @This();

    const State = packed struct {
        waiting: u31 = 0,
        locked: bool = false,
    };

    pub const unlocked: Self = .{};
    pub const locked: Self = .{ .state = .init(@bitCast(State{ .locked = true })) };

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

    pub fn waitUnlocked(self: *Self) void {
        const state: State = self.load(.monotonic);
        if (state.locked) self.waitUnlockedSlow(state);
        return;
    }

    fn waitUnlockedSlow(self: *Self, _state: State) void {
        @branchHint(.cold);

        var state: State = _state;
        while (true) {
            if (!state.locked) return;

            if (state.waiting >= std.math.maxInt(u31))
                std.debug.panic("too many threads waiting on the same futex", .{});

            const prev_state = state;
            state.waiting += 1;
            if (self.cmpxchg(
                .weak,
                prev_state,
                state,
                .monotonic,
                .monotonic,
            )) |failed| {
                // failed to increase waiter count
                state = failed;
                continue;
            }
            // successfully incremented the sleeper count

            sys.futexWait(&self.state.raw, @as(u32, @bitCast(state)), .{
                .size = .bits32,
            }) catch unreachable;
            break;
        }

        state = self.load(.monotonic);
        while (true) {
            if (self.cmpxchg(.weak, state, State{
                .waiting = state.waiting - 1,
                // it can get relocked before the return
                .locked = state.locked,
            }, .acquire, .monotonic)) |failed| {
                // failed to lock, either spuriously or it was locked
                state = failed;
                continue;
            } else {
                // successfully removed the waiter
                break;
            }
        }

        // FIXME: waitUnlocked steals a spot from a real lock waiter,
        // but doesn't then wake a real lock waiter after the previous
        // unlocker woke up this waitUnlocked caller
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
        var counter = if (conf.IS_DEBUG) @as(usize, 0) else {};
        while (true) {
            if (conf.IS_DEBUG) {
                counter += 1;
                if (counter % 100 == 0) {
                    // log.warn("possible deadlock", .{});
                }
            }

            if (!state.locked) {
                // set the state to locked
                if (self.cmpxchg(.weak, state, State{
                    // `- registered`, because it removes this waiter if the locking works
                    .waiting = state.waiting - @intFromBool(registered),
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

                const prev_state = state;
                state.waiting += 1;
                if (self.cmpxchg(
                    .weak,
                    prev_state,
                    state,
                    .monotonic,
                    .monotonic,
                )) |failed| {
                    // failed to increase waiter count
                    state = failed;
                    continue;
                }
                // successfully incremented the sleeper count
                registered = true;
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
                return self.unlockSlow(state);

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
                .waiting = state.waiting,
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

pub const SpinMutex = extern struct {
    lock_state: std.atomic.Value(State) = std.atomic.Value(State).init(.unlocked),

    const State = enum(u8) {
        unlocked,
        locked,
    };

    const Self = @This();

    pub const unlocked: Self = .{};
    pub const locked: Self = .{ .lock_state = .init(.locked) };

    pub fn tryLock(
        self: *Self,
    ) bool {
        const unexpected_state = self.lock_state.cmpxchgStrong(
            .unlocked,
            .locked,
            .acquire,
            .monotonic,
        );
        if (unexpected_state == null) {
            return true;
        } else {
            @branchHint(.cold);
            std.debug.assert(unexpected_state.? == .locked);
            return false;
        }
    }

    pub fn waitUnlocked(
        self: *Self,
    ) void {
        var fail_count: u32 = 0;
        while (self.isLocked()) {
            @branchHint(.cold);
            if (conf.IS_DEBUG) {
                fail_count += 1;
                if (fail_count >= 200_000) {
                    self.waitUnlockedPotentialDeadlock();
                    return;
                }
            }
            std.atomic.spinLoopHint();
        }
    }

    // just a symbol hint, because printing the error requires locking
    // but if the lock is the printing lock, then things would be bad
    noinline fn waitUnlockedPotentialDeadlock(
        self: *Self,
    ) void {
        while (self.isLocked()) {
            @branchHint(.cold);
            std.atomic.spinLoopHint();
        }
    }

    pub fn lockAttempts(
        self: *Self,
        attempts: usize,
    ) bool {
        std.debug.assert(attempts != 0);

        for (0..attempts) |_| {
            if (self.tryLock()) return true;
        }
        return false;
    }

    pub fn lockMultiUnordered(
        self: *Self,
        other: *Self,
    ) void {
        while (true) {
            self.lock();
            if (other.tryLock()) break;
            self.unlock();

            other.lock();
            if (self.tryLock()) break;
            other.unlock();
        }

        std.debug.assert(self.isLocked());
        std.debug.assert(other.isLocked());
    }

    pub fn lock(
        self: *Self,
    ) void {
        while (null != self.lock_state.cmpxchgWeak(
            .unlocked,
            .locked,
            .acquire,
            .monotonic,
        )) {
            @branchHint(.cold);
            self.waitUnlocked();
        }
    }

    pub fn isLocked(
        self: *Self,
    ) bool {
        return self.lock_state.load(.monotonic) == .locked;
    }

    pub fn unlock(
        self: *Self,
    ) void {
        if (conf.IS_DEBUG) std.debug.assert(self.isLocked());
        self.lock_state.store(.unlocked, .release);
    }
};

pub const DummyLock = struct {
    const Self = @This();

    pub fn locked() Self {
        return .{};
    }

    pub fn tryLock(_: *const Self) bool {
        return true;
    }

    pub fn lockAttempts(_: *const Self, _: usize) bool {
        return true;
    }

    pub fn lock(_: *const Self) void {}

    pub fn unlock(_: *const Self) void {}
};

pub const DebugLock = struct {
    state: if (conf.IS_DEBUG) std.atomic.Value(usize) else void =
        if (conf.IS_DEBUG) .init(0) else {},

    const Self = @This();

    pub fn locked() Self {
        if (!conf.IS_DEBUG) return .{};
        return .{ .state = .init(returnAddress()) };
    }

    pub fn tryLock(self: *Self) bool {
        self.lock();
        return true;
    }

    pub fn lockAttempts(self: *Self, _: usize) bool {
        return self.tryLock();
    }

    pub fn lock(self: *Self) void {
        if (!conf.IS_DEBUG) return;
        const prev_lock_owner = self.state.cmpxchgStrong(
            0,
            returnAddress(),
            .acquire,
            .monotonic,
        ) orelse return;
        std.debug.panic(
            "debug lock contended, locked previously at {*}, now locked at {*}",
            .{
                @as(*anyopaque, @ptrFromInt(prev_lock_owner)),
                @as(*anyopaque, @ptrFromInt(returnAddress())),
            },
        );
    }

    fn isLocked(self: *Self) bool {
        if (!conf.IS_DEBUG) comptime unreachable;
        return self.state.load(.monotonic) != 0;
    }

    inline fn returnAddress() usize {
        const ra = @returnAddress();
        if (ra == 0) return 1;
        return ra;
    }

    pub fn assertIsLocked(self: *Self) void {
        if (!conf.IS_DEBUG) return;
        std.debug.assert(self.isLocked());
    }

    pub fn assertIsUnlocked(self: *Self) void {
        if (!conf.IS_DEBUG) return;
        std.debug.assert(!self.isLocked());
    }

    pub fn unlock(self: *Self) void {
        if (!conf.IS_DEBUG) return;
        self.assertIsLocked();
        self.state.store(0, .release);
    }
};

pub fn Once(comptime Mutex: type) type {
    return struct {
        entry_mutex: SpinMutex = .{},
        wait_mutex: Mutex = .locked,

        const Self = @This();

        /// try init whatever resource
        /// false => some other CPU did it, call `wait`
        /// true  => this CPU is doing it, call `complete` once done
        pub fn tryRun(
            self: *Self,
        ) bool {
            return self.entry_mutex.tryLock();
        }

        pub fn wait(
            self: *Self,
        ) void {
            // some other cpu is already working on this,
            // wait for it to be complete and then return
            self.wait_mutex.waitUnlocked();
        }

        pub fn complete(
            self: *Self,
        ) void {
            // unlock wait_spin to signal others
            if (@hasDecl(Mutex, "takeOwnership")) {
                self.wait_mutex.takeOwnership();
            }
            self.wait_mutex.unlock();
        }

        pub fn isReady(
            self: *Self,
        ) bool {
            return !self.wait_mutex.isLocked();
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
