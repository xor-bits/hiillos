const std = @import("std");

const arch = @import("arch.zig");
const conf = @import("abi").conf;

//

pub const TrackingSpinMutex = extern struct {
    lock_state: std.atomic.Value(InternalState) = .init(.unlocked),

    const InternalState = enum(u32) {
        unlocked = std.math.maxInt(u32),
        _,
    };

    const Self = @This();

    pub const unlocked: Self = .{};
    pub const locked: Self = .{ .lock_state = .init(@enumFromInt(0)) };

    pub fn tryLock(
        self: *Self,
    ) bool {
        const local = arch.cpuLocal();
        const locked_by_me: InternalState = @enumFromInt(local.id);
        std.debug.assert(local.held_lock_count < std.math.maxInt(u8));
        std.debug.assert(locked_by_me != .unlocked);

        const unexpected_state = self.lock_state.cmpxchgStrong(
            .unlocked,
            locked_by_me,
            .acquire,
            .monotonic,
        );
        if (unexpected_state == null) {
            local.held_lock_count += 1;
            return true;
        } else {
            @branchHint(.cold);
            // it should be locked by some other CPU
            std.debug.assert(unexpected_state.? != .unlocked);
            std.debug.assert(unexpected_state.? != locked_by_me);
            return false;
        }
    }

    pub fn waitUnlocked(
        self: *Self,
    ) void {
        var fail_count: u32 = 0;
        while (self.waitUnlockedIsLockedByOther()) {
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
        while (self.waitUnlockedIsLockedByOther()) {
            @branchHint(.cold);
            std.atomic.spinLoopHint();
        }
    }

    fn waitUnlockedIsLockedByOther(
        self: *Self,
    ) bool {
        return switch (self.state()) {
            .unlocked => false,
            .locked_by_other => true,
            .locked_by_me => unreachable,
        };
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
        const local = arch.cpuLocal();
        const init_held_lock_count = local.held_lock_count;
        std.debug.assert(init_held_lock_count < std.math.maxInt(u8) - 1);

        while (true) {
            self.lock();
            if (other.tryLock()) break;
            self.unlock();
            std.debug.assert(init_held_lock_count == local.held_lock_count);

            other.lock();
            if (self.tryLock()) break;
            other.unlock();
            std.debug.assert(init_held_lock_count == local.held_lock_count);
        }

        std.debug.assert(init_held_lock_count + 2 == local.held_lock_count);
        std.debug.assert(self.isLockedByMe());
        std.debug.assert(other.isLockedByMe());
    }

    pub fn lock(
        self: *Self,
    ) void {
        const local = arch.cpuLocal();
        const locked_by_me: InternalState = @enumFromInt(local.id);
        std.debug.assert(local.held_lock_count < std.math.maxInt(u8));
        std.debug.assert(locked_by_me != .unlocked);

        while (null != self.lock_state.cmpxchgWeak(
            .unlocked,
            locked_by_me,
            .acquire,
            .monotonic,
        )) {
            @branchHint(.cold);
            self.waitUnlocked();
        }

        local.held_lock_count += 1;
    }

    pub const State = enum {
        unlocked,
        locked_by_me,
        locked_by_other,
    };

    pub fn state(
        self: *Self,
    ) State {
        const lock_state = self.lock_state.load(.monotonic);
        if (lock_state == .unlocked) {
            return .unlocked;
        } else if (@intFromEnum(lock_state) == arch.cpuId()) {
            std.debug.assert(arch.cpuLocal().held_lock_count != 0);
            return .locked_by_me;
        } else {
            return .locked_by_other;
        }
    }

    pub fn isUnlocked(
        self: *Self,
    ) bool {
        return self.lock_state.load(.monotonic) == .unlocked;
    }

    pub fn isLocked(
        self: *Self,
    ) bool {
        return !self.isUnlocked();
    }

    pub fn isLockedByMe(
        self: *Self,
    ) bool {
        return self.state() == .locked_by_me;
    }

    pub fn isLockedByOther(
        self: *Self,
    ) bool {
        return self.state() == .locked_by_other;
    }

    pub fn giveOwnership(
        self: *Self,
    ) void {
        const local = arch.cpuLocal();
        const locked_by_me: InternalState = @enumFromInt(local.id);
        std.debug.assert(local.held_lock_count != 0);
        std.debug.assert(locked_by_me != .unlocked);
        std.debug.assert(self.isLockedByMe());
        local.held_lock_count -= 1;
    }

    pub fn takeOwnership(
        self: *Self,
    ) void {
        const local = arch.cpuLocal();
        const locked_by_me: InternalState = @enumFromInt(local.id);
        std.debug.assert(local.held_lock_count < std.math.maxInt(u8));
        std.debug.assert(locked_by_me != .unlocked);
        std.debug.assert(self.isLocked());
        // monotonic because it stays as locked for other CPUs
        self.lock_state.store(locked_by_me, .monotonic);
        local.held_lock_count += 1;
    }

    pub fn unlock(
        self: *Self,
    ) void {
        const local = arch.cpuLocal();
        std.debug.assert(local.held_lock_count != 0);
        if (conf.IS_DEBUG) std.debug.assert(self.isLockedByMe());
        local.held_lock_count -= 1;
        self.lock_state.store(.unlocked, .release);
    }
};
