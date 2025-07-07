const std = @import("std");
const abi = @import("lib.zig");
const sys = @import("sys.zig");
const lock = @import("lock.zig");

// some hardcoded capability handles

pub const ROOT_SELF_VMEM: Vmem = .{ .cap = 1 };
pub const ROOT_SELF_THREAD: Thread = .{ .cap = 2 };
pub const ROOT_SELF_PROC: Process = .{ .cap = 3 };
pub const ROOT_BOOT_INFO: Frame = .{ .cap = 4 };
pub const ROOT_X86_IOPORT_ALLOCATOR: X86IoPortAllocator = .{ .cap = 5 };
pub const ROOT_X86_IRQ_ALLOCATOR: X86IrqAllocator = .{ .cap = 6 };

//

pub const Handle = extern struct {
    cap: u32 = 0,

    pub fn identify(this: @This()) abi.ObjectType {
        return sys.handleIdentify(this.cap);
    }

    pub fn clone(this: @This()) sys.Error!@This() {
        const cap = try sys.handleDuplicate(this.cap);
        return .{ .cap = cap };
    }

    pub fn close(this: @This()) void {
        sys.handleClose(this.cap);
    }
};

/// capability to manage a single process
pub const Process = extern struct {
    cap: u32 = 0,

    pub const Type: abi.ObjectType = .process;

    pub fn create(vmem: Vmem) sys.Error!@This() {
        const cap = try sys.procCreate(vmem.cap);
        return .{ .cap = cap };
    }

    pub fn self() sys.Error!@This() {
        const cap = try sys.procSelf();
        return .{ .cap = cap };
    }

    pub fn clone(this: @This()) sys.Error!@This() {
        const cap = try sys.handleDuplicate(this.cap);
        return .{ .cap = cap };
    }

    pub fn close(this: @This()) void {
        sys.handleClose(this.cap);
    }

    pub fn giveHandle(this: @This(), handle: anytype) sys.Error!u32 {
        return try this.giveCap(handle.cap);
    }

    pub fn giveCap(this: @This(), cap: u32) sys.Error!u32 {
        return try sys.procGiveCap(this.cap, cap);
    }
};

/// capability to manage a single thread control block (TCB)
pub const Thread = extern struct {
    cap: u32 = 0,

    pub const Type: abi.ObjectType = .thread;

    pub fn create(proc: Process) sys.Error!@This() {
        const cap = try sys.threadCreate(proc.cap);
        return .{ .cap = cap };
    }

    pub fn self() sys.Error!@This() {
        const cap = try sys.threadSelf();
        return .{ .cap = cap };
    }

    pub fn clone(this: @This()) sys.Error!@This() {
        const cap = try sys.handleDuplicate(this.cap);
        return .{ .cap = cap };
    }

    pub fn close(this: @This()) void {
        sys.handleClose(this.cap);
    }

    pub fn readRegs(this: @This(), regs: *sys.ThreadRegs) sys.Error!void {
        try sys.threadReadRegs(this.cap, regs);
    }

    pub fn writeRegs(this: @This(), regs: *const sys.ThreadRegs) sys.Error!void {
        try sys.threadWriteRegs(this.cap, regs);
    }

    pub fn start(this: @This()) sys.Error!void {
        try sys.threadStart(this.cap);
    }

    pub fn stop(this: @This()) sys.Error!void {
        try sys.threadStop(this.cap);
    }

    pub fn setPrio(this: @This(), prio: u2) sys.Error!void {
        try sys.threadSetPrio(this.cap, prio);
    }

    pub fn wait(this: @This()) sys.Error!usize {
        return try sys.threadWait(this.cap);
    }
};

/// capability to the virtual memory structure
pub const Vmem = extern struct {
    cap: u32 = 0,

    var global_self: std.atomic.Value(u32) = .init(0);
    var global_self_init: lock.Once(lock.YieldMutex) = .new();

    pub const Type: abi.ObjectType = .vmem;

    pub fn create() sys.Error!@This() {
        const cap = try sys.vmemCreate();
        return .{ .cap = cap };
    }

    pub fn self() sys.Error!@This() {
        if (!global_self_init.tryRun()) {
            global_self_init.wait();
            return .{ .cap = global_self.load(.acquire) };
        }

        const self_vmem_cap = try sys.vmemSelf();
        global_self.store(self_vmem_cap, .release);
        global_self_init.complete();

        return .{ .cap = self_vmem_cap };
    }

    pub fn clone(this: @This()) sys.Error!@This() {
        const cap = try sys.handleDuplicate(this.cap);
        return .{ .cap = cap };
    }

    pub fn close(this: @This()) void {
        if (this.cap == global_self.load(.monotonic)) return;

        sys.handleClose(this.cap);
    }

    /// if length is zero, the rest of the frame is mapped
    pub fn map(
        this: @This(),
        frame: Frame,
        frame_offset: usize,
        vaddr: usize,
        length: usize,
        rights: abi.sys.Rights,
        flags: abi.sys.MapFlags,
    ) sys.Error!usize {
        return sys.vmemMap(
            this.cap,
            frame.cap,
            frame_offset,
            vaddr,
            length,
            rights,
            flags,
        );
    }

    pub fn unmap(this: @This(), vaddr: usize, length: usize) sys.Error!void {
        return try sys.vmemUnmap(this.cap, vaddr, length);
    }

    pub fn read(this: @This(), _vaddr: usize, _dst: []u8) sys.Error!void {
        var vaddr = _vaddr;
        var dst = _dst;

        while (true) {
            var progress: usize = 0;
            sys.vmemRead(
                this.cap,
                vaddr,
                dst,
                &progress,
            ) catch |err| switch (err) {
                sys.Error.Retry => {
                    @branchHint(.cold);
                    vaddr += progress;
                    dst = dst[progress..];

                    sys.dummyWrite(dst);
                    try sys.vmemDummyAccess(this.cap, vaddr, .read);
                    continue;
                },
                else => return err,
            };

            return;
        }
    }

    pub fn write(this: @This(), _vaddr: usize, _src: []const u8) sys.Error!void {
        var vaddr = _vaddr;
        var src = _src;

        while (true) {
            var progress: usize = 0;
            sys.vmemWrite(
                this.cap,
                vaddr,
                src,
                &progress,
            ) catch |err| switch (err) {
                sys.Error.Retry => {
                    @branchHint(.cold);
                    vaddr += progress;
                    src = src[progress..];

                    sys.dummyRead(src);
                    try sys.vmemDummyAccess(this.cap, vaddr, .write);
                    continue;
                },
                else => return err,
            };

            return;
        }
    }

    pub fn dummyAccess(this: @This(), vaddr: usize, mode: sys.FaultCause) sys.Error!void {
        return try sys.vmemDummyAccess(this.cap, vaddr, mode);
    }

    pub fn dump(this: @This()) sys.Error!void {
        return try sys.vmemDump(this.cap);
    }
};

/// capability to a physical memory region (sized `ChunkSize`)
pub const Frame = extern struct {
    cap: u32 = 0,

    pub const Type: abi.ObjectType = .frame;

    pub fn create(size_bytes: usize) sys.Error!@This() {
        const cap = try sys.frameCreate(size_bytes);
        return .{ .cap = cap };
    }

    pub fn init(bytes: []const u8) sys.Error!@This() {
        const frame = try create(bytes.len);
        try frame.write(0, bytes);
        return frame;
    }

    pub fn clone(this: @This()) sys.Error!@This() {
        const cap = try sys.handleDuplicate(this.cap);
        return .{ .cap = cap };
    }

    pub fn close(this: @This()) void {
        sys.handleClose(this.cap);
    }

    pub fn getSize(self: @This()) sys.Error!usize {
        return try sys.frameGetSize(self.cap);
    }

    pub fn read(this: @This(), _offset_byte: usize, _dst: []u8) sys.Error!void {
        var offset_byte = _offset_byte;
        var dst = _dst;

        while (true) {
            var progress: usize = 0;
            sys.frameRead(
                this.cap,
                offset_byte,
                dst,
                &progress,
            ) catch |err| switch (err) {
                sys.Error.Retry => {
                    @branchHint(.cold);
                    offset_byte += progress;
                    dst = dst[progress..];

                    sys.dummyWrite(dst);
                    try sys.frameDummyAccess(this.cap, offset_byte, .read);
                    continue;
                },
                else => return err,
            };

            return;
        }
    }

    pub fn write(this: @This(), _offset_byte: usize, _src: []const u8) sys.Error!void {
        var offset_byte = _offset_byte;
        var src = _src;

        while (true) {
            var progress: usize = 0;
            sys.frameWrite(
                this.cap,
                offset_byte,
                src,
                &progress,
            ) catch |err| switch (err) {
                sys.Error.Retry => {
                    @branchHint(.cold);
                    offset_byte += progress;
                    src = src[progress..];

                    sys.dummyRead(src);
                    try sys.frameDummyAccess(this.cap, offset_byte, .write);
                    continue;
                },
                else => return err,
            };

            return;
        }
        return try sys.frameWrite(this.cap, offset_byte, src);
    }

    pub const Stream = struct {
        frame: Frame, // borrowed frame
        read: usize = 0,
        write: usize = 0,

        pub const Reader = struct {
            stream: *Stream,

            pub const Error = sys.Error;

            pub fn read(self: @This(), buf: []u8) Error!usize {
                try self.stream.frame.read(self.stream.read, buf);
                self.stream.read += buf.len;
                return buf.len;
            }

            pub fn flush(_: @This()) Error!void {}
        };

        pub fn reader(this: *@This()) Reader {
            return .{ .stream = this };
        }

        pub const Writer = struct {
            stream: *Stream,

            pub const Error = sys.Error;

            pub fn write(self: @This(), bytes: []const u8) Error!usize {
                try self.stream.frame.write(self.stream.write, bytes);
                self.stream.write += bytes.len;
                return bytes.len;
            }

            pub fn writeAll(self: @This(), bytes: []const u8) Error!void {
                _ = try self.write(bytes);
            }

            pub fn writeBytesNTimes(self: @This(), bytes: []const u8, n: usize) Error!void {
                for (0..n) |_| try self.writeAll(bytes);
            }

            pub fn flush(_: @This()) Error!void {}
        };

        pub fn writer(this: *@This()) Writer {
            return .{ .stream = this };
        }
    };

    pub fn stream(this: @This()) Stream {
        return .{ .frame = this };
    }

    pub fn dummyAccess(this: @This(), offset_byte: usize, mode: sys.FaultCause) sys.Error!void {
        return try sys.frameDummyAccess(this.cap, offset_byte, mode);
    }

    pub fn dump(this: @This()) sys.Error!void {
        return try sys.frameDump(this.cap);
    }
};

/// capability to **the** receiver end of an endpoint,
/// there can only be a single receiver
pub const Receiver = extern struct {
    cap: u32 = 0,

    pub const Type: abi.ObjectType = .receiver;

    pub fn create() sys.Error!@This() {
        const cap = try sys.receiverCreate();
        return .{ .cap = cap };
    }

    pub fn clone(this: @This()) sys.Error!@This() {
        const cap = try sys.handleDuplicate(this.cap);
        return .{ .cap = cap };
    }

    pub fn close(this: @This()) void {
        sys.handleClose(this.cap);
    }

    pub fn recv(self: @This()) sys.Error!sys.Message {
        return try sys.receiverRecv(self.cap);
    }

    pub fn reply(self: @This(), msg: sys.Message) sys.Error!void {
        return try sys.receiverReply(self.cap, msg);
    }

    pub fn replyRecv(self: @This(), msg: sys.Message) sys.Error!sys.Message {
        return try sys.receiverReplyRecv(self.cap, msg);
    }
};

/// capability to **a** sender end of an endpoint,
/// there can be multiple senders
pub const Sender = extern struct {
    cap: u32 = 0,

    pub const Type: abi.ObjectType = .sender;

    pub fn create(recv: Receiver, stamp: u32) sys.Error!@This() {
        const cap = try sys.senderCreate(recv.cap, stamp);
        return .{ .cap = cap };
    }

    pub fn clone(this: @This()) sys.Error!@This() {
        const cap = try sys.handleDuplicate(this.cap);
        return .{ .cap = cap };
    }

    pub fn close(this: @This()) void {
        sys.handleClose(this.cap);
    }

    pub fn call(self: @This(), msg: sys.Message) sys.Error!sys.Message {
        return try sys.senderCall(self.cap, msg);
    }
};

/// capability to **a** reply object
/// it can be saved/loaded from receiver or replied with
pub const Reply = extern struct {
    cap: u32 = 0,

    pub const Type: abi.ObjectType = .reply;

    pub fn create() sys.Error!@This() {
        const cap = try sys.replyCreate();
        return .{ .cap = cap };
    }

    pub fn clone(this: @This()) sys.Error!@This() {
        const cap = try sys.handleDuplicate(this.cap);
        return .{ .cap = cap };
    }

    pub fn close(this: @This()) void {
        sys.handleClose(this.cap);
    }

    pub fn reply(self: @This(), msg: sys.Message) sys.Error!void {
        return sys.replyReply(self.cap, msg);
    }
};

/// capability to **a** notify object
/// there can be multiple of them
pub const Notify = extern struct {
    cap: u32 = 0,

    pub const Type: abi.ObjectType = .notify;

    pub fn create() sys.Error!@This() {
        const cap = try sys.notifyCreate();
        return .{ .cap = cap };
    }

    pub fn clone(this: @This()) sys.Error!@This() {
        const cap = try sys.handleDuplicate(this.cap);
        return .{ .cap = cap };
    }

    pub fn close(this: @This()) void {
        sys.handleClose(this.cap);
    }

    pub fn wait(self: @This()) void {
        return sys.notifyWait(self.cap) catch unreachable;
    }

    pub fn poll(self: @This()) bool {
        return sys.notifyPoll(self.cap) catch unreachable;
    }

    pub fn notify(self: @This()) bool {
        return sys.notifyNotify(self.cap) catch unreachable;
    }
};

/// x86 specific capability that allows allocating `x86_ioport` capabilities
pub const X86IoPortAllocator = extern struct {
    cap: u32 = 0,

    pub const Type: abi.ObjectType = .x86_ioport_allocator;

    pub fn clone(this: @This()) sys.Error!@This() {
        const cap = try sys.handleDuplicate(this.cap);
        return .{ .cap = cap };
    }

    pub fn close(this: @This()) void {
        sys.handleClose(this.cap);
    }
};

/// x86 specific capability that gives access to one IO port
pub const X86IoPort = extern struct {
    cap: u32 = 0,

    pub const Type: abi.ObjectType = .x86_ioport;

    pub fn create(alloc: X86IoPortAllocator, port: u16) sys.Error!@This() {
        const cap = try sys.x86IoPortCreate(alloc.cap, port);
        return .{ .cap = cap };
    }

    pub fn clone(this: @This()) sys.Error!@This() {
        const cap = try sys.handleDuplicate(this.cap);
        return .{ .cap = cap };
    }

    pub fn close(this: @This()) void {
        sys.handleClose(this.cap);
    }

    pub fn inb(self: @This()) sys.Error!u8 {
        return try sys.x86IoPortInb(self.cap);
    }

    pub fn outb(self: @This(), byte: u8) sys.Error!void {
        return try sys.x86IoPortOutb(self.cap, byte);
    }
};

/// x86 specific capability that allows allocating `x86_irq` capabilities
pub const X86IrqAllocator = extern struct {
    cap: u32 = 0,

    pub const Type: abi.ObjectType = .x86_irq_allocator;

    pub fn clone(this: @This()) sys.Error!@This() {
        const cap = try sys.handleDuplicate(this.cap);
        return .{ .cap = cap };
    }

    pub fn close(this: @This()) void {
        sys.handleClose(this.cap);
    }
};

/// x86 specific capability that gives access to one IRQ (= interrupt request)
pub const X86Irq = extern struct {
    cap: u32 = 0,

    pub const Type: abi.ObjectType = .x86_irq;

    pub fn create(alloc: X86IrqAllocator, irq: u8) sys.Error!@This() {
        const cap = try sys.x86IrqCreate(alloc.cap, irq);
        return .{ .cap = cap };
    }

    pub fn clone(this: @This()) sys.Error!@This() {
        const cap = try sys.handleDuplicate(this.cap);
        return .{ .cap = cap };
    }

    pub fn close(this: @This()) void {
        sys.handleClose(this.cap);
    }

    pub fn subscribe(self: @This()) sys.Error!Notify {
        const cap = try sys.x86IrqSubscribe(self.cap);
        return .{ .cap = cap };
    }
};
