const abi = @import("abi");
const std = @import("std");

const addr = @import("../addr.zig");
const arch = @import("../arch.zig");
const caps = @import("../caps.zig");
const pmem = @import("../pmem.zig");
const proc = @import("../proc.zig");

const conf = abi.conf;
const log = std.log.scoped(.caps);
const Error = abi.sys.Error;

//

/// thread information
pub const Thread = struct {
    // FIXME: prevent reordering so that the offset would be same on all objects
    refcnt: abi.epoch.RefCnt align(16) = .{},

    proc: *caps.Process,

    // debug lock for executing the thread
    exec_lock: abi.lock.DebugLock = .locked(),
    /// all context data, except fx
    trap: arch.TrapRegs = .{},
    /// fx context data, switched lazily
    fx: arch.FxRegs = .{},

    // lock for modifying the thread
    lock: abi.lock.SpinMutex = .locked(),
    /// scheduler priority
    priority: u2 = 1,
    /// is the thread stopped/running/ready/waiting
    status: abi.sys.ThreadStatus = .stopped,
    prev_status: abi.sys.ThreadStatus = .stopped,
    in_queue: bool = false,
    exit_code: usize = 0,
    exit_waiters: Queue = .{},
    waiting_cause: Cause = .not_started,
    prev_waiting_cause: Cause = .not_started,
    // TODO: IPC buffer Frame where the userspace can write data freely
    // and on send, the kernel copies it (with CoW) to the destination IPC buffer
    // and replaces all handles with the target handles (u32 -> handle -> giveCap -> handle -> u32)
    /// extra ipc registers
    /// controlled by Receiver and Sender
    extra_regs: std.MultiArrayList(CapOrVal) = .{},
    /// signal handler instruction pointer
    signal_handler: usize = 0,
    /// if a signal handler is running, this is the return address
    signal: ?abi.sys.Signal = null,
    message: abi.sys.Message = .{},

    /// scheduler linked list
    scheduler_queue_node: abi.util.QueueNode(@This()) = .{},
    /// process threads linked list
    process_threads_node: abi.util.QueueNode(@This()) = .{},
    /// IPC reply target
    reply: ?*Thread = null,

    pub const Queue = ThreadQueue;
    pub const Cause = enum {
        not_started,
        starving,
        other_thread_exit,
        other_process_exit,
        unmap_tlb_shootdown,
        transient_page_fault,
        notify_wait,
        ipc_recv,
        ipc_call0,
        ipc_call1,
        signal,
        futex,
        cancel_stop,
    };
    pub const UserHandle = abi.caps.Thread;

    pub const CapOrVal = union(enum) {
        cap: caps.CapabilitySlot,
        val: u64,

        pub fn deinit(self: @This()) void {
            switch (self) {
                .cap => |cap| cap.deinit(),
                else => {},
            }
        }
    };

    pub fn init(from_proc: *caps.Process) !*@This() {
        errdefer from_proc.deinit();

        if (conf.LOG_OBJ_CALLS)
            log.info("Thread.init", .{});
        if (conf.LOG_OBJ_STATS)
            caps.incCount(.thread);

        const obj: *@This() = try caps.slab_allocator.allocator().create(@This());
        obj.* = .{ .proc = from_proc };

        try obj.extra_regs.resize(caps.slab_allocator.allocator(), 128);
        for (0..128) |i| obj.extra_regs.set(i, .{ .val = 0 });

        obj.lock.unlock();
        obj.exec_lock.unlock();

        return obj;
    }

    pub fn deinit(self: *@This()) void {
        if (!self.refcnt.dec()) return;

        if (conf.LOG_OBJ_CALLS)
            log.info("Thread.deinit", .{});
        if (conf.LOG_OBJ_STATS)
            caps.decCount(.thread);

        self.exit(0);

        self.lock.lock();
        std.debug.assert(self.scheduler_queue_node.next == null);
        std.debug.assert(self.scheduler_queue_node.prev == null);
        self.discardReply();
        self.lock.unlock();

        self.proc.deinit();

        for (0..128) |i| self.getExtra(@truncate(i)).deinit();
        self.extra_regs.deinit(caps.slab_allocator.allocator());

        caps.slab_allocator.allocator().destroy(self);
    }

    pub fn clone(self: *@This()) *@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("Thread.clone", .{});

        self.refcnt.inc();
        return self;
    }

    pub fn switchTo(
        self: *@This(),
        trap: *arch.TrapRegs,
    ) void {
        self.exec_lock.lock();
        trap.* = self.trap;
        self.fx.restore();

        self.proc.vmem.switchTo();
    }

    pub fn switchFrom(
        self: *@This(),
        trap: *const arch.TrapRegs,
    ) void {
        self.fx.save();
        self.trap = trap.*;
        self.exec_lock.unlock();
    }

    pub fn checkRunningUnlocked(
        self: *@This(),
    ) error{Cancelled}!void {
        self.lock.lock();
        defer self.lock.unlock();
        return try self.checkRunning();
    }

    pub fn checkRunning(
        self: *@This(),
    ) error{Cancelled}!void {
        std.debug.assert(self.lock.isLocked());
        switch (self.status) {
            .running => {},
            .stopping => {
                @branchHint(.cold);
                self.prev_status = self.status;
                self.status = .stopped;
                return error.Cancelled;
            },
            .exiting => {
                @branchHint(.cold);
                self.prev_status = self.status;
                self.status = .dead;
                return error.Cancelled;
            },

            .stopped,
            .ready,
            .waiting,
            .dead,
            .starting,
            => if (conf.IS_DEBUG) {
                std.debug.panic("unexpected thread state: state={}, cause={}", .{
                    self.status,
                    self.waiting_cause,
                });
            } else {
                unreachable;
            },
        }
    }

    pub fn pushPrepareUnlocked(
        self: *@This(),
        comptime opts: Queue.PushOpts,
    ) error{Cancelled}!void {
        self.lock.lock();
        defer self.lock.unlock();
        return try self.pushPrepare(opts);
    }

    pub fn pushPrepare(
        self: *@This(),
        comptime opts: Queue.PushOpts,
    ) error{Cancelled}!void {
        std.debug.assert(self.lock.isLocked());
        switch (self.status) {
            .running,
            .starting,
            => {
                self.prev_status = self.status;
                self.prev_waiting_cause = self.waiting_cause;

                self.status = opts.new_status;
                self.waiting_cause = opts.new_cause;
            },
            .stopping => {
                @branchHint(.cold);
                if (opts.cancel_op != .allow_cancelled) {
                    self.prev_status = self.status;
                    self.status = .stopped;
                }
                return error.Cancelled;
            },
            .exiting => {
                @branchHint(.cold);
                if (opts.cancel_op != .allow_cancelled) {
                    self.prev_status = self.status;
                    self.status = .dead;
                }
                return error.Cancelled;
            },

            // thread cannot be pushed into a queue directly after the state is one of these:
            //  - `stopped`, because it has to go through `stopping` first
            //  - `ready`, because that would mean the thread is
            //    also in some scheduler ready queue
            //  - `waiting`, because that would mean the thread is
            //    also in some IPC/other wait queue
            //  - `dead`, because the thread is now permanently dead
            .stopped,
            .ready,
            .waiting,
            .dead,
            => if (conf.IS_DEBUG) {
                std.debug.panic("unexpected thread state: state={}, cause={}", .{
                    self.status,
                    self.waiting_cause,
                });
            } else {
                unreachable;
            },
        }
    }

    pub fn popFinishUnlocked(
        self: *@This(),
        comptime opts: Queue.PopOpts,
    ) error{Cancelled}!void {
        self.lock.lock();
        defer self.lock.unlock();
        return try self.popFinish(opts);
    }

    pub fn popFinish(
        self: *@This(),
        comptime opts: Queue.PopOpts,
    ) error{Cancelled}!void {
        std.debug.assert(self.lock.isLocked());
        switch (self.status) {
            .ready,
            .waiting,
            => {
                self.prev_status = self.status;
                self.status = .running;
            },
            .exiting => {
                @branchHint(.cold);
                if (opts.cancel_op != .allow_cancelled) {
                    self.prev_status = self.status;
                    self.status = .dead;
                }
                return error.Cancelled;
            },
            .stopping => {
                @branchHint(.cold);
                if (opts.cancel_op != .allow_cancelled) {
                    self.prev_status = self.status;
                    self.status = .stopped;
                }
                return error.Cancelled;
            },

            // thread cannot be in a queue and one of these at the same time:
            //  - `stopped`, because only taking it from a
            //    queue while its `stopping` changes it to stopped
            //  - `running`, because that would mean two CPUs could
            //    be running the same thread at the same time
            //  - `dead`, because only taking it from a
            //    queue while its exiting changes it to `dead`
            //  - `starting`, because it was just `stopped` and not yet added this queue
            .stopped,
            .running,
            .dead,
            .starting,
            => if (conf.IS_DEBUG) {
                std.debug.panic("unexpected thread state: state={}, cause={}", .{
                    self.status,
                    self.waiting_cause,
                });
            } else {
                unreachable;
            },
        }
    }

    pub fn start(self: *@This()) !void {
        try self.proc.start(self);

        if (conf.LOG_ENTRYPOINT_CODE) {
            // dump the entrypoint code
            var it = self.proc.vmem.data(addr.Virt.fromInt(self.trap.rip), false);
            defer it.deinit();

            log.info("{}", .{self.trap});

            var len: usize = 200;
            while (it.next() catch null) |chunk| {
                const limit = @min(len, chunk.len);
                len -= limit;

                log.info("{}", .{abi.util.hex(@volatileCast(chunk[0..limit]))});
                if (len == 0) break;
            }
        }

        self.lock.lock();
        switch (self.status) {
            .stopped => {
                self.prev_status = self.status;
                self.status = .running;

                self.lock.unlock();
                proc.start(self.clone());
            },
            .stopping => {
                self.status = self.prev_status;

                self.lock.unlock();
            },
            else => {
                self.lock.unlock();
                return Error.NotStopped;
            },
        }
    }

    pub fn stop(
        self: *@This(),
        thread: *caps.Thread,
        trap: *arch.TrapRegs,
    ) !void {
        {
            self.lock.lock();
            defer self.lock.unlock();
            // FIXME: atomic status, because the scheduler might be reading/writing this
            if (self.status != .ready and
                self.status != .running and
                self.status != .waiting)
                return Error.NotRunning;
            self.prev_status = self.status;
            self.status = .stopping;
        }

        if (self == thread) {
            proc.switchFrom(trap, thread);
        }
        // proc.stop(thread);
    }

    pub fn exit(
        self: *@This(),
        exit_code: usize,
    ) void {
        self.proc.exit(exit_code, self);

        self.lock.lock();
        self.prev_status = self.status;
        self.status = .dead;
        self.exit_code = exit_code;
        self.lock.unlock();

        // TODO: swap with empty, unlock and then process
        while (self.exit_waiters.pop(&self.lock)) |waiter| {
            waiter.lock.lock();
            waiter.trap.arg0 = exit_code;
            waiter.lock.unlock();

            proc.ready(waiter);
        }
    }

    pub fn waitExit(
        self: *@This(),
        thread: *caps.Thread,
        trap: *arch.TrapRegs,
    ) void {
        if (self == thread) {
            trap.syscall_id = abi.sys.encode(Error.PermissionDenied);
            return;
        }

        // early block the thread (or cancel)
        proc.switchFrom(trap, thread);
        thread.lock.lock();
        thread.pushPrepare(.{
            .new_status = .waiting,
            .new_cause = .other_thread_exit,
        }) catch {
            @branchHint(.cold);
            thread.lock.unlock();

            // the current thread was stopped
            trap.syscall_id = abi.sys.encode(Error.Cancelled);
            proc.switchFrom(trap, thread);
            thread.deinit();
            return;
        };
        thread.lock.unlock();

        // if the thread isnt already dead, then add it to the wait queue
        self.lock.lock();
        if (self.status != .dead) {
            self.exit_waiters.queue.pushBack(thread);
            self.lock.unlock();
            return;
        }
        const exit_code = self.exit_code;
        self.lock.unlock();

        // the thread was already dead
        trap.arg0 = exit_code;
        proc.switchUndo(thread);
        thread.popFinishUnlocked(.{}) catch {
            // the current thread was stopped
            trap.syscall_id = abi.sys.encode(Error.Cancelled);
            proc.switchFrom(trap, thread);
            thread.deinit();
        };
    }

    pub fn getExtra(self: *@This(), idx: u7) CapOrVal {
        self.lock.lock();
        defer self.lock.unlock();

        const val = self.extra_regs.get(idx);
        self.extra_regs.set(idx, .{ .val = 0 });
        return val;
    }

    pub fn setExtra(self: *@This(), idx: u7, data: CapOrVal) void {
        self.lock.lock();
        defer self.lock.unlock();

        self.extra_regs.get(idx).deinit();
        self.extra_regs.set(idx, data);
    }

    /// prepareExtras has to be called for `dst` first
    pub fn moveExtra(src: *@This(), dst: *@This(), count: u7) void {
        if (count == 0) {
            return;
        } else {
            @branchHint(.cold);
        }

        src.lock.lock();
        defer src.lock.unlock();
        dst.lock.lock();
        defer dst.lock.unlock();

        for (0..count) |idx| {
            const val = src.extra_regs.get(@truncate(idx));
            src.extra_regs.set(@truncate(idx), .{ .val = 0 });

            const old_val = dst.extra_regs.get(idx);
            dst.extra_regs.set(@truncate(idx), val);

            old_val.deinit();
        }
    }

    pub fn readRegs(self: *@This()) abi.sys.ThreadRegs {
        self.lock.lock();
        defer self.lock.unlock();

        var regs: abi.sys.ThreadRegs = undefined;
        inline for (@typeInfo(abi.sys.ThreadRegs).@"struct".fields) |field| {
            @field(regs, field.name) = @field(self.trap, field.name);
        }
        return regs;
    }

    pub fn writeRegs(self: *@This(), regs: abi.sys.ThreadRegs) void {
        self.lock.lock();
        defer self.lock.unlock();

        // only iretq preserves rcx and r11
        self.trap.return_mode = .iretq;
        inline for (@typeInfo(abi.sys.ThreadRegs).@"struct".fields) |field| {
            @field(self.trap, field.name) = @field(regs, field.name);
        }
    }

    pub fn setReply(self: *@This(), target: *Thread) void {
        std.debug.assert(self.reply == null);
        std.debug.assert(self != target);
        std.debug.assert(target.status == .waiting);
        self.reply = target;
    }

    pub fn takeReply(self: *@This()) ?*Thread {
        std.debug.assert(self.lock.isLocked());
        const sender = self.reply orelse {
            @branchHint(.cold);
            return null;
        };
        std.debug.assert(sender.status == .waiting);
        self.reply = null;
        return sender;
    }

    pub fn discardReply(self: *@This()) void {
        std.debug.assert(self.lock.isLocked());
        if (self.reply) |discarded| {
            @branchHint(.cold);
            discarded.trap.syscall_id = abi.sys.encode(Error.NoReply);
            proc.ready(discarded);
        }
        self.reply = null;
    }

    pub fn unhandledPageFault(
        self: *@This(),
        target_addr: usize,
        caused_by: abi.sys.FaultCause,
        ip: usize,
        sp: usize,
        reason: anyerror,
        trap: *arch.TrapRegs,
    ) void {
        if (self.signal_handler != 0) {
            self.signal = abi.sys.Signal{
                .ip = ip,
                .sp = sp,
                .target_addr = target_addr,
                .caused_by = caused_by,
                .signal = .segv,
            };
            trap.rip = self.signal_handler;
            return;
        }

        log.warn(
            \\unhandled page fault 0x{x} (user) ({})
            \\ - caused by: {}
            \\ - ip: 0x{x}
            \\ - sp: 0x{x}
        , .{
            target_addr,
            reason,
            caused_by,
            ip,
            sp,
        });
        self.proc.vmem.dump();

        while (conf.DEBUG_UNHANDLED_FAULT) {}

        // TODO: sigsegv

        proc.switchFrom(trap, self);
    }
};

const ThreadQueue = struct {
    queue: abi.util.Queue(Thread, "scheduler_queue_node") = .{},

    pub fn takeAll(
        self: *@This(),
        lock: *abi.lock.SpinMutex,
    ) @This() {
        std.debug.assert(lock.isLocked());
        defer self.* = .{};
        return self.*;
    }

    pub const PushOpts = struct {
        new_status: abi.sys.ThreadStatus,
        new_cause: Thread.Cause,
        cancel_op: enum {
            ignore,
            set_error,
            allow_cancelled,
        } = .ignore,
    };

    /// sets thread status to `status` and pushes it to the queue
    pub fn push(
        self: *@This(),
        lock: *abi.lock.SpinMutex,
        thread: *Thread,
        comptime opts: PushOpts,
    ) void {
        if (conf.IS_DEBUG) std.debug.assert(
            arch.cpuLocal().current_thread != thread,
        );

        {
            thread.lock.lock();
            defer thread.lock.unlock();
            thread.pushPrepare(
                opts,
            ) catch switch (opts.cancel_op) {
                .ignore => {
                    thread.deinit();
                    return;
                },
                .set_error => {
                    thread.exec_lock.lock();
                    thread.trap.syscall_id =
                        abi.sys.encode(Error.Cancelled);
                    thread.exec_lock.unlock();
                    thread.deinit();
                    return;
                },
                .allow_cancelled => {},
            };
        }

        {
            lock.lock();
            defer lock.unlock();
            self.queue.pushBack(thread);
        }
    }

    /// pops a thread and marks it as running
    pub fn pop(
        self: *@This(),
        lock: *abi.lock.SpinMutex,
    ) ?*Thread {
        return self.popOpts(lock, .{});
    }

    pub const PopOpts = struct {
        empty_op: enum {
            return_unlocked,
            return_locked,
        } = .return_unlocked,
        cancel_op: enum {
            ignore,
            set_error,
            allow_cancelled,
        } = .ignore,
        no_pop_finish: bool = false,
    };

    /// pops a thread and marks it as running
    pub fn popOpts(
        self: *@This(),
        lock: *abi.lock.SpinMutex,
        comptime opts: PopOpts,
    ) ?*Thread {
        while (true) {
            lock.lock();
            const next_thread = self.queue.popFront() orelse switch (opts.empty_op) {
                .return_unlocked => {
                    @branchHint(.cold);
                    lock.unlock();
                    return null;
                },
                .return_locked => {
                    @branchHint(.cold);
                    return null;
                },
            };
            lock.unlock();

            next_thread.lock.lock();
            defer next_thread.lock.unlock();
            if (opts.no_pop_finish) return next_thread;
            next_thread.popFinish(opts) catch switch (opts.cancel_op) {
                .ignore => {
                    next_thread.deinit();
                    continue;
                },
                .set_error => {
                    next_thread.exec_lock.lock();
                    next_thread.trap.syscall_id =
                        abi.sys.encode(Error.Cancelled);
                    next_thread.exec_lock.unlock();
                    next_thread.deinit();
                    continue;
                },
                .allow_cancelled => {},
            };
            return next_thread;
        }
    }

    inline fn cancelError(thread: *Thread) void {
        thread.trap.syscall_id = abi.sys.encode(Error.Cancelled);
    }
};
