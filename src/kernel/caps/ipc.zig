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
    recv_queue: abi.util.Queue(caps.Thread, "scheduler_queue_node") = .{},
    /// queue for when there are more active senders than active receivers
    send_queue: abi.util.Queue(caps.Thread, "scheduler_queue_node") = .{},

    pub fn init() !struct { *Receiver, *Sender } {
        const allocator = caps.slab_allocator.allocator();

        if (conf.LOG_OBJ_CALLS)
            log.info("Channel.init", .{});
        if (conf.LOG_OBJ_STATS) {
            caps.incCount(.receiver);
            caps.incCount(.sender);
        }

        errdefer if (conf.LOG_OBJ_STATS) {
            caps.decCount(.receiver);
            caps.decCount(.sender);
        };

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

        log.info("deinit recv", .{});

        std.debug.assert(self.recv_count == 1);
        self.recv_count = 0;

        // wake up all threads waiting to receive messages (BadHandle)
        while (self.recv_queue.popFront()) |listener| {
            std.debug.assert(listener.status == .waiting);
            listener.trap.syscall_id = abi.sys.encode(Error.BadHandle);
            proc.ready(listener);
        }

        // wake up all threads waiting to send messages (ChannelClosed)
        while (self.send_queue.popFront()) |caller| {
            std.debug.assert(caller.status == .waiting);
            caller.trap.syscall_id = abi.sys.encode(Error.ChannelClosed);
            proc.ready(caller);
        }

        return self.send_count == 0;
    }

    /// returns `true` if both ends were closed and `deinit` should be called
    pub fn deinitSend(self: *@This()) bool {
        self.lock.lock();
        defer self.lock.unlock();

        log.info("deinit send", .{});

        std.debug.assert(self.send_count != 0);
        self.send_count -= 1;
        if (self.send_count != 0) return false;

        // wake up all threads waiting to receive messages (ChannelClosed)
        while (self.recv_queue.popFront()) |listener| {
            std.debug.assert(listener.status == .waiting);
            listener.trap.syscall_id = abi.sys.encode(Error.ChannelClosed);
            proc.ready(listener);
        }

        // wake up all threads waiting to send messages (BadHandle)
        while (self.send_queue.popFront()) |caller| {
            std.debug.assert(caller.status == .waiting);
            caller.trap.syscall_id = abi.sys.encode(Error.BadHandle);
            proc.ready(caller);
        }

        return self.recv_count == 0;
    }

    /// block until something sends
    /// returns true if the current thread went to sleep
    pub fn recv(
        self: *@This(),
        thread: *caps.Thread,
        trap: *arch.TrapRegs,
    ) Error!void {
        if (thread.reply) |discarded| discarded.deinit();
        thread.reply = null;

        if (self.recvNoFail(thread, trap)) {
            proc.switchNow(trap);
        }
    }

    // might block the user-space thread (kernel-space should only ever block after a syscall is complete)
    /// returns true if the current thread went to sleep
    fn recvNoFail(
        self: *@This(),
        thread: *caps.Thread,
        trap: *arch.TrapRegs,
    ) bool {
        // stop the thread early to hold the lock for a shorter time
        thread.status = .waiting;
        thread.waiting_cause = .ipc_recv;
        proc.switchFrom(trap, thread);

        // check if a sender is already waiting
        self.lock.lock();
        const caller = self.send_queue.popFront() orelse {
            self.recv_queue.pushBack(thread);
            self.lock.unlock();
            return true;
        };
        self.lock.unlock();

        if (conf.LOG_WAITING)
            log.debug("IPC wake {*}", .{caller});

        // copy over the message
        const msg = caller.trap.readMessage();
        trap.writeMessage(msg);
        caller.moveExtra(thread, @truncate(msg.extra));

        // save the reply target
        std.debug.assert(thread.reply == null);
        thread.reply = caller;

        // undo stopping the current thread
        thread.status = .running;
        proc.switchUndo(thread);
        return false;
    }

    pub fn reply(
        thread: *caps.Thread,
        msg: abi.sys.Message,
    ) Error!void {
        const sender = try replyGetSender(thread, msg);
        std.debug.assert(sender != thread);

        // set the original caller thread as ready to run again, but return to the current thread
        proc.ready(sender);
    }

    fn replyGetSender(
        thread: *caps.Thread,
        msg: abi.sys.Message,
    ) Error!*caps.Thread {
        const sender = thread.takeReply() orelse
            return Error.InvalidCapability;

        try replyToSender(thread, msg, sender);
        return sender;
    }

    fn replyToSender(
        thread: *caps.Thread,
        msg: abi.sys.Message,
        sender: *caps.Thread,
    ) Error!void {
        if (conf.LOG_OBJ_CALLS)
            log.debug("replying {} from {*}", .{ msg, thread });

        // copy over the reply message
        sender.trap.writeMessage(msg);
        thread.moveExtra(sender, @truncate(msg.extra));
    }

    pub fn replyRecv(
        self: *@This(),
        thread: *caps.Thread,
        trap: *arch.TrapRegs,
        msg: abi.sys.Message,
    ) Error!void {
        if (conf.LOG_OBJ_CALLS)
            log.debug("Channel.replyRecv", .{});

        const sender = try replyGetSender(thread, msg);
        std.debug.assert(sender != thread);

        // push the receiver thread into the ready queue
        // if there was a sender queued
        if (self.recvNoFail(thread, trap)) {
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
        // stop the thread early to hold the lock for a shorter time
        thread.status = .waiting;
        thread.waiting_cause = .ipc_call0;
        trap.writeMessage(msg); // the message was modified by the kernel (stamped)
        proc.switchFrom(trap, thread);

        // check if a receiver is already waiting
        self.lock.lock();
        const listener = self.recv_queue.popFront() orelse {
            @branchHint(.cold);
            self.send_queue.pushBack(thread);
            self.lock.unlock();

            proc.switchNow(trap);
            return;
        };
        self.lock.unlock();
        std.debug.assert(listener.status == .waiting);

        // copy over the message
        listener.trap.writeMessage(msg);
        thread.moveExtra(listener, @truncate(msg.extra));

        // save the reply target
        std.debug.assert(listener.reply == null);
        listener.reply = thread;

        // switch to the listener
        thread.status = .waiting;
        thread.waiting_cause = .ipc_call1;

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

        if (conf.LOG_OBJ_CALLS)
            log.info("Receiver.deinit", .{});
        if (conf.LOG_OBJ_STATS)
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

        if (conf.LOG_OBJ_CALLS)
            log.info("Sender.deinit", .{});
        if (conf.LOG_OBJ_STATS)
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
        if (conf.LOG_OBJ_CALLS)
            log.info("Reply.init", .{});
        if (conf.LOG_OBJ_STATS)
            caps.incCount(.reply);

        const sender = thread.takeReply() orelse {
            @branchHint(.cold);
            return Error.InvalidCapability;
        };

        const obj: *@This() = try caps.slab_allocator.allocator().create(@This());
        obj.* = .{ .sender = .init(null) };
        obj.sender.store(sender, .release);

        return obj;
    }

    pub fn deinit(self: *@This()) void {
        if (!self.refcnt.dec()) return;

        if (conf.LOG_OBJ_CALLS)
            log.info("Reply.deinit", .{});
        if (conf.LOG_OBJ_STATS)
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

        Channel.replyToSender(thread, msg, sender) catch unreachable;

        // set the original caller thread as ready to run again, but return to the current thread
        proc.ready(sender);
    }
};

pub const Notify = struct {
    // FIXME: prevent reordering so that the offset would be same on all objects
    refcnt: abi.epoch.RefCnt = .{},

    notified: std.atomic.Value(bool) = .init(false),

    // waiter queue
    queue_lock: abi.lock.SpinMutex = .locked(),
    queue: abi.util.Queue(caps.Thread, "scheduler_queue_node") = .{},

    pub const UserHandle = abi.caps.Notify;

    pub fn init() !*@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("Notify.init", .{});
        if (conf.LOG_OBJ_STATS)
            caps.incCount(.notify);

        const obj: *@This() = try caps.slab_allocator.allocator().create(@This());
        obj.* = .{};
        obj.queue_lock.unlock();

        return obj;
    }

    pub fn deinit(self: *@This()) void {
        if (!self.refcnt.dec()) return;

        if (conf.LOG_OBJ_CALLS)
            log.info("Notify.deinit", .{});
        if (conf.LOG_OBJ_STATS)
            caps.decCount(.notify);

        while (self.queue.popFront()) |waiter| {
            waiter.deinit();
        }

        caps.slab_allocator.allocator().destroy(self);
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

        // save the state and go to sleep
        thread.status = .waiting;
        thread.waiting_cause = .notify_wait;
        proc.switchFrom(trap, thread);

        self.queue_lock.lock();
        self.queue.pushBack(thread);

        // while holding the lock: if it became active before locking but after the swap, then test it again
        if (self.poll()) {
            self.queue_lock.unlock();
            // undo
            std.debug.assert(self.queue.popBack() == thread);
            std.debug.assert(thread.status == .waiting);
            thread.status = .running;
            proc.switchUndo(thread);
            return;
        }
        self.queue_lock.unlock();

        proc.switchNow(trap);
    }

    pub fn poll(self: *@This()) bool {
        return self.notified.swap(false, .acquire);
    }

    pub fn notify(self: *@This()) bool {
        self.queue_lock.lock();
        if (self.queue.popFront()) |waiter| {
            self.queue_lock.unlock();

            proc.ready(waiter);
            return false;
        } else {
            defer self.queue_lock.unlock();

            return null != self.notified.cmpxchgStrong(false, true, .monotonic, .monotonic);
        }
    }
};
