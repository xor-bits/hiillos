const std = @import("std");
const abi = @import("abi");

const addr = @import("../addr.zig");
const apic = @import("../apic.zig");
const arch = @import("../arch.zig");
const caps = @import("../caps.zig");
const pmem = @import("../pmem.zig");
const proc = @import("../proc.zig");

const conf = abi.conf;
const log = std.log.scoped(.caps);
const Error = abi.sys.Error;

//

pub const Channel = struct {
    lock: abi.lock.SpinMutex = .locked(),

    /// there can be only zero or one receivers (of course multiple handles to it are allowed)
    recv_count: u1 = 1,
    /// there can be zero or more senders, each with their own stamp values
    send_count: usize = 1,

    /// queue for when there are more active receivers than active senders
    recv_queue: caps.Thread.Queue = .{},
    /// queue for when there are more active senders than active receivers
    send_queue: caps.Thread.Queue = .{},

    pub fn init() !struct { *Receiver, *Sender } {
        const allocator = caps.slab_allocator.allocator();

        caps.incCount(.receiver, .{});
        caps.incCount(.sender, .{});
        errdefer caps.decCount(.receiver);
        errdefer caps.decCount(.sender);

        const obj: *@This() = try allocator.create(@This());
        errdefer allocator.destroy(obj);
        obj.* = .{};
        obj.lock.unlock();

        const receiver = try allocator.create(Receiver);
        errdefer allocator.destroy(receiver);
        receiver.* = .{ .channel = obj };

        const sender = try allocator.create(Sender);
        errdefer allocator.destroy(sender);
        sender.* = .{ .channel = obj };

        return .{ receiver, sender };
    }

    pub fn deinit(self: *@This()) void {
        caps.slab_allocator.allocator().destroy(self);
    }

    /// returns `true` if both ends were closed and `deinit` should be called
    pub fn deinitRecv(self: *@This()) bool {
        self.lock.lock();
        defer self.lock.unlock();

        std.debug.assert(self.recv_count == 1);
        self.recv_count = 0;

        // wake up all threads waiting to receive messages (BadHandle)
        while (self.recv_queue.popFirstLocked(
            &self.lock,
            .ready,
        )) |listener| {
            listener.exec_lock.lock();
            listener.trap.syscall_id = abi.sys.encode(Error.BadHandle);
            listener.exec_lock.unlock();
            proc.ready(listener);
        }

        // wake up all threads waiting to send messages (ChannelClosed)
        while (self.send_queue.popFirstLocked(
            &self.lock,
            .ready,
        )) |caller| {
            caller.exec_lock.lock();
            caller.trap.syscall_id = abi.sys.encode(Error.ChannelClosed);
            caller.exec_lock.unlock();
            proc.ready(caller);
        }

        return self.send_count == 0;
    }

    /// returns `true` if both ends were closed and `deinit` should be called
    pub fn deinitSend(self: *@This()) bool {
        self.lock.lock();
        defer self.lock.unlock();

        std.debug.assert(self.send_count != 0);
        self.send_count -= 1;
        const was_last_sender = self.send_count != 0;

        if (was_last_sender) return false;

        // wake up all threads waiting to receive messages (ChannelClosed)
        while (self.recv_queue.popFirstLocked(
            &self.lock,
            .ready,
        )) |listener| {
            listener.exec_lock.lock();
            listener.trap.syscall_id = abi.sys.encode(Error.ChannelClosed);
            listener.exec_lock.unlock();
            proc.ready(listener);
        }

        // wake up all threads waiting to send messages (BadHandle)
        while (self.send_queue.popFirstLocked(
            &self.lock,
            .ready,
        )) |caller| {
            caller.exec_lock.lock();
            caller.trap.syscall_id = abi.sys.encode(Error.BadHandle);
            caller.exec_lock.unlock();
            proc.ready(caller);
        }

        return self.recv_count == 0;
    }

    /// might block the user-space thread (kernel-space should only ever block after a syscall is complete)
    pub fn recv(
        self: *@This(),
        thread: *caps.Thread,
        trap: *arch.TrapRegs,
    ) Error!void {
        // early sleep
        thread.discardReplyLockedExec();
        proc.switchFrom(trap, thread);

        self.lock.lock();
        const caller = self.send_queue.popFirstLocked(
            &self.lock,
            .running,
        ) orelse {
            @branchHint(.cold);
            // if there are no waiting listeners,
            // then push this thread into the wait queue

            if (self.send_count == 0) {
                @branchHint(.cold);
                self.lock.unlock();

                thread.exec_lock.lock();
                thread.trap.syscall_id = abi.sys.encode(Error.ChannelClosed);
                thread.exec_lock.unlock();

                proc.switchUndo(thread);
                return;
            }

            thread.lock.lock();
            self.recv_queue.pushLockedThreadLocked(
                &self.lock,
                thread,
                0,
                .waiting,
            );
            thread.lock.unlock();
            self.lock.unlock();
            return;
        };
        self.lock.unlock();

        if (conf.LOG_WAITING)
            log.debug("IPC wake {*}", .{caller});

        // lock ordering does not matter,
        // because these are debug locks
        // which just assert that it is
        // not locked by some other cpu
        thread.exec_lock.lock();
        caller.exec_lock.lock();

        // copy over the message and everything else
        trap.writeMessage(caller.message);
        thread.trap.writeMessage(caller.message);
        caller.moveExtraLockedExec(thread, @truncate(caller.message.extra));
        thread.setReplyLockedExec(caller);

        caller.exec_lock.unlock();
        thread.exec_lock.unlock();

        proc.switchUndo(thread);
    }

    pub fn reply(
        thread: *caps.Thread,
        msg: abi.sys.Message,
    ) Error!void {
        const sender = try replyGetSender(thread, msg) orelse return;

        // set the original caller thread as ready to run again, but return to the current thread
        proc.ready(sender);
    }

    /// sends the reply and returns the reply target thread without pushing it to the ready queue
    ///
    /// returns null if the return target cancelled
    fn replyGetSender(
        thread: *caps.Thread,
        msg: abi.sys.Message,
    ) Error!?*caps.Thread {
        const sender = thread.takeReplyLockedExec() orelse {
            return Error.InvalidCapability;
        };

        replyToSender(thread, msg, sender);
        return sender;
    }

    fn replyToSender(
        thread: *caps.Thread,
        msg: abi.sys.Message,
        sender: *caps.Thread,
    ) void {
        if (conf.LOG_OBJ_CALLS)
            log.debug("replying {} from {*}", .{ msg, thread });

        sender.exec_lock.lock();
        defer sender.exec_lock.unlock();

        // copy over the reply message
        sender.trap.writeMessage(msg);
        thread.moveExtraLockedExec(sender, @truncate(msg.extra));
    }

    var last_count: std.atomic.Value(u64) = .init(0);
    pub fn replyRecv(
        self: *@This(),
        thread: *caps.Thread,
        trap: *arch.TrapRegs,
        msg: abi.sys.Message,
    ) Error!void {
        if (conf.LOG_OBJ_CALLS)
            log.debug("Channel.replyRecv", .{});

        if (conf.IPC_BENCHMARK and conf.IPC_BENCHMARK_PERFMON) {
            const count1: u64 = arch.x86_64.rdpmc();

            const count0 = last_count.load(.acquire);
            log.info("RTT cycles: {}", .{count1 - count0});

            // record the stored PMC counter again to skip the log call
            const count2: u64 = arch.x86_64.rdpmc();
            last_count.store(count2, .release);
        }

        const sender_opt = try replyGetSender(thread, msg);
        if (thread.reply != null)
            log.err("discard reply from replyRecv call", .{});
        try self.recv(thread, trap);
        const sender = sender_opt orelse {
            @branchHint(.cold);
            // if the sender cancelled and the receiver switched,
            // return with no thread causing a scheduler switch
            return;
        };

        if (arch.cpuLocal().current_thread == null) {
            // if the receiver went to sleep, switch to the original caller thread
            proc.switchTo(trap, sender);
        } else {
            @branchHint(.cold);
            // return back to the server, which is prob more important
            // and keeps the TLB cache warm
            // + ready up the caller thread
            proc.ready(sender);
        }
    }

    // block until the receiver is free, then switch to the receiver
    pub fn call(
        self: *@This(),
        thread: *caps.Thread,
        trap: *arch.TrapRegs,
        msg: abi.sys.Message,
    ) void {
        // early sleep
        proc.switchFrom(trap, thread);

        self.lock.lock();
        const listener = self.recv_queue.popFirstLocked(
            &self.lock,
            .running,
        ) orelse {
            @branchHint(.cold);
            // if there are no waiting callers,
            // then push this thread into the wait queue

            if (self.recv_count == 0) {
                @branchHint(.cold);
                self.lock.unlock();

                thread.exec_lock.lock();
                thread.trap.syscall_id = abi.sys.encode(Error.ChannelClosed);
                thread.exec_lock.unlock();

                proc.switchUndo(thread);
                return;
            }

            thread.lock.lock();
            thread.message = msg;
            self.send_queue.pushLockedThreadLocked(
                &self.lock,
                thread,
                0,
                .waiting,
            );
            thread.lock.unlock();
            self.lock.unlock();
            return;
        };
        self.lock.unlock();

        if (conf.LOG_WAITING)
            log.debug("IPC fast call {*}", .{listener});

        // lock ordering does not matter,
        // because these are debug locks
        // which just assert that it is
        // not locked by some other cpu
        thread.exec_lock.lock();
        listener.exec_lock.lock();

        // copy over the message and everything else
        trap.writeMessage(msg);
        listener.trap.writeMessage(msg);
        thread.moveExtraLockedExec(listener, @truncate(msg.extra));
        listener.setReplyLockedExec(thread);

        listener.exec_lock.unlock();
        thread.exec_lock.unlock();

        proc.switchTo(trap, listener);
    }
};

pub const Receiver = struct {
    // FIXME: prevent reordering so that the offset would be same on all objects
    refcnt: abi.epoch.RefCnt = .{},

    // TODO: useless double indirection
    channel: *Channel,

    pub const UserHandle = abi.caps.Receiver;

    pub fn deinit(self: *@This()) void {
        if (!self.refcnt.dec()) return;
        caps.decCount(.receiver);

        if (self.channel.deinitRecv()) {
            self.channel.deinit();
        }

        caps.slab_allocator.allocator().destroy(self);
    }

    /// block until something sends
    /// returns true if the current thread went to sleep
    pub fn recv(
        self: *@This(),
        thread: *caps.Thread,
        trap: *arch.TrapRegs,
    ) Error!void {
        if (conf.LOG_OBJ_CALLS)
            log.debug("Receiver.recv", .{});

        if (thread.reply != null)
            log.err("discard reply from recv call", .{});
        try self.channel.recv(thread, trap);
    }

    pub fn reply(
        thread: *caps.Thread,
        msg: abi.sys.Message,
    ) Error!void {
        if (conf.LOG_OBJ_CALLS)
            log.debug("Receiver.reply", .{});
        try Channel.reply(thread, msg);
    }

    pub fn replyRecv(
        self: *@This(),
        thread: *caps.Thread,
        trap: *arch.TrapRegs,
        msg: abi.sys.Message,
    ) Error!void {
        if (conf.LOG_OBJ_CALLS)
            log.debug("Receiver.replyRecv", .{});

        try self.channel.replyRecv(thread, trap, msg);
    }
};

pub const Sender = struct {
    // FIXME: prevent reordering so that the offset would be same on all objects
    refcnt: abi.epoch.RefCnt = .{},

    channel: *Channel,
    stamp: u32 = 0,

    pub const UserHandle = abi.caps.Sender;

    pub fn deinit(self: *@This()) void {
        if (!self.refcnt.dec()) return;
        caps.decCount(.sender);

        if (self.channel.deinitSend()) {
            self.channel.deinit();
        }

        caps.slab_allocator.allocator().destroy(self);
    }

    pub fn clone(self: *@This()) *@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("Sender.clone", .{});

        self.refcnt.inc();
        return self;
    }

    pub fn restamp(
        self: *const @This(),
        stamp: u32,
    ) Error!*@This() {
        const allocator = caps.slab_allocator.allocator();

        {
            self.channel.lock.lock();
            defer self.channel.lock.unlock();
            self.channel.send_count = std.math.add(usize, self.channel.send_count, 1) catch
                return Error.OutOfBounds;
        }

        const sender = try allocator.create(Sender);
        errdefer allocator.destroy(sender);
        sender.* = .{ .channel = self.channel, .stamp = stamp };

        return sender;
    }

    // block until the receiver is free, then switch to the receiver
    pub fn call(
        self: *@This(),
        thread: *caps.Thread,
        trap: *arch.TrapRegs,
        msg: abi.sys.Message,
    ) void {
        const stamped_msg = msg.withStamp(self.stamp);
        if (conf.LOG_OBJ_CALLS)
            log.debug("Sender.call {}", .{stamped_msg});

        self.channel.call(thread, trap, stamped_msg);
    }
};

pub const Reply = struct {
    // TODO: this shouldn't be cloneable
    // FIXME: prevent reordering so that the offset would be same on all objects
    refcnt: abi.epoch.RefCnt = .{},
    sender: std.atomic.Value(?*caps.Thread),

    pub const UserHandle = abi.caps.Reply;

    /// only borrows `thread`
    pub fn init(thread: *caps.Thread) !*@This() {
        caps.incCount(.reply, .{ .thread = thread });

        const sender = thread.takeReplyLockedExec() orelse {
            return Error.InvalidCapability;
        };

        const obj: *@This() = try caps.slab_allocator.allocator().create(@This());
        obj.* = .{ .sender = .init(null) };
        obj.sender.store(sender, .release);

        return obj;
    }

    pub fn deinit(self: *@This()) void {
        if (!self.refcnt.dec()) return;
        caps.decCount(.reply);

        caps.slab_allocator.allocator().destroy(self);
    }

    pub fn reply(
        self: *@This(),
        thread: *caps.Thread,
        msg: abi.sys.Message,
    ) Error!void {
        if (conf.LOG_OBJ_CALLS)
            log.debug("Reply.reply", .{});

        const sender = self.sender.swap(null, .acquire) orelse {
            // reply cap will be destroyed and its fine
            return Error.BadHandle;
        };

        Channel.replyToSender(thread, msg, sender);

        // set the original caller thread as ready to run again, but return to the current thread
        proc.ready(sender);
    }
};

pub const Notify = struct {
    // FIXME: prevent reordering so that the offset would be same on all objects
    refcnt: abi.epoch.RefCnt = .{},

    queue_lock: abi.lock.SpinMutex = .locked(),
    queue: caps.Thread.Queue = .{},
    notified: bool = false,

    pub const UserHandle = abi.caps.Notify;

    pub fn init() !*@This() {
        caps.incCount(.notify, .{});

        const obj: *@This() = try caps.slab_allocator.allocator().create(@This());
        obj.* = .{};
        obj.queue_lock.unlock();

        return obj;
    }

    pub fn deinit(self: *@This()) void {
        if (!self.refcnt.dec()) return;
        caps.decCount(.notify);

        self.cancel();

        caps.slab_allocator.allocator().destroy(self);
    }

    fn cancel(self: *@This()) void {
        self.queue_lock.lock();
        defer self.queue_lock.unlock();

        while (self.queue.popFirstLocked(
            &self.queue_lock,
            .ready,
        )) |waiter| {
            waiter.exec_lock.lock();
            waiter.trap.syscall_id = abi.sys.encode(Error.Cancelled);
            waiter.exec_lock.unlock();

            proc.ready(waiter);
        }
    }

    pub fn clone(self: *@This()) *@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("Notify.clone", .{});

        self.refcnt.inc();
        return self;
    }

    /// returns true if the current thread went to sleep
    pub fn wait(self: *@This(), thread: *caps.Thread, trap: *arch.TrapRegs) void {
        // early test if its active
        if (self.poll()) {
            return;
        }

        proc.switchFrom(trap, thread);

        self.queue_lock.lock();
        thread.lock.lock();

        // late test if its active
        if (self.pollLocked()) {
            thread.lock.unlock();
            self.queue_lock.unlock();
            proc.switchUndo(thread);
            return;
        }

        self.queue.pushLockedThreadLocked(
            &self.queue_lock,
            thread,
            0,
            .waiting,
        );

        thread.lock.unlock();
        self.queue_lock.unlock();
    }

    pub fn poll(self: *@This()) bool {
        self.queue_lock.lock();
        defer self.queue_lock.unlock();
        return self.pollLocked();
    }

    pub fn pollLocked(self: *@This()) bool {
        defer self.notified = false;
        return self.notified;
    }

    /// returns true if the object was already notified
    pub fn notify(self: *@This()) bool {
        self.queue_lock.lock();

        if (self.queue.inner.size == 0) {
            defer self.queue_lock.unlock();
            // is this cursed?
            defer self.notified = true;
            return self.notified;
        }

        const waiter = self.queue.popFirstLocked(
            &self.queue_lock,
            .ready,
        ).?;
        self.queue_lock.unlock();

        proc.ready(waiter);
        return false;
    }
};
