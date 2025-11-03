const std = @import("std");

const abi = @import("lib.zig");
const sys = @import("sys.zig");
const lock = @import("lock.zig");
const thread = @import("thread.zig");

// some hardcoded capability handles

pub const ROOT_SELF_VMEM: Vmem = .{ .cap = 1 };
pub const ROOT_SELF_THREAD: Thread = .{ .cap = 2 };
pub const ROOT_SELF_PROC: Process = .{ .cap = 3 };
pub const ROOT_BOOT_INFO: Frame = .{ .cap = 4 };
pub const ROOT_X86_IOPORT_ALLOCATOR: X86IoPortAllocator = .{ .cap = 5 };
pub const ROOT_X86_IRQ_ALLOCATOR: X86IrqAllocator = .{ .cap = 6 };

pub const COMMON_PM = Sender{ .cap = 1 };
pub const COMMON_HPET = Sender{ .cap = 2 };
pub const COMMON_PS2 = Sender{ .cap = 3 };
pub const COMMON_VFS = Sender{ .cap = 4 };
pub const COMMON_ARG_MAP = Frame{ .cap = 5 };
pub const COMMON_ENV_MAP = Frame{ .cap = 6 };
pub const COMMON_TTY = Sender{ .cap = 7 };

//

pub fn init() !void {
    Process.self = try .createSelf();
    Vmem.self = try .createSelf();
    Thread.main = try .createSelf();
}

//

pub const Handle = extern struct {
    cap: u32 = 0,

    pub const default_rights = abi.sys.Rights{
        .clone = true,
        .transfer = true,
    };

    pub fn identify(this: @This()) abi.ObjectType {
        return sys.handleIdentify(this.cap);
    }

    pub fn clone(this: @This()) sys.Error!@This() {
        const cap = try sys.handleDuplicate(this.cap);
        return .{ .cap = cap };
    }

    pub fn rights(this: @This()) sys.Error!sys.Rights {
        return try sys.handleRights(this.cap);
    }

    pub fn restrict(this: @This(), mask: sys.Rights) sys.Error!void {
        try sys.handleRestrict(this.cap, mask);
    }

    pub fn close(this: @This()) void {
        sys.handleClose(this.cap);
    }
};

/// capability to manage a single process
pub const Process = extern struct {
    cap: u32 = 0,

    pub const object_type = abi.ObjectType.process;
    pub const default_rights = abi.sys.Rights{
        .clone = true,
        .transfer = true,
    };

    pub var self: @This() = .{};

    pub fn create(vmem: Vmem) sys.Error!@This() {
        const cap = try sys.procCreate(vmem.cap);
        return .{ .cap = cap };
    }

    pub fn createSelf() sys.Error!@This() {
        const cap = try sys.procSelf();
        return .{ .cap = cap };
    }

    pub fn clone(this: @This()) sys.Error!@This() {
        const cap = try sys.handleDuplicate(this.cap);
        return .{ .cap = cap };
    }

    pub fn close(this: @This()) void {
        std.debug.assert(this.cap != self.cap);
        sys.handleClose(this.cap);
    }

    pub fn giveHandle(this: @This(), h: anytype) sys.Error!u32 {
        return try this.giveCap(h.cap);
    }

    pub fn giveCap(this: @This(), cap: u32) sys.Error!u32 {
        return try sys.procGiveCap(this.cap, cap);
    }

    pub fn handle(this: @This()) Handle {
        return .{ .cap = this.cap };
    }
};

/// capability to manage a single thread control block (TCB)
pub const Thread = extern struct {
    cap: u32 = 0,

    pub const object_type = abi.ObjectType.thread;
    pub const default_rights = abi.sys.Rights{
        .read = true,
        .write = true,
        .clone = true,
        .transfer = true,
    };

    pub var main: @This() = .{};

    pub fn create(proc: Process) sys.Error!@This() {
        const cap = try sys.threadCreate(proc.cap);
        return .{ .cap = cap };
    }

    pub fn createSelf() sys.Error!@This() {
        const cap = try sys.threadSelf();
        return .{ .cap = cap };
    }

    pub fn clone(this: @This()) sys.Error!@This() {
        const cap = try sys.handleDuplicate(this.cap);
        return .{ .cap = cap };
    }

    pub fn close(this: @This()) void {
        std.debug.assert(this.cap != main.cap);
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

    pub fn threadSetSigHandler(this: @This(), ip: usize) sys.Error!void {
        return try sys.threadSetSigHandler(this.cap, ip);
    }

    pub fn handle(this: @This()) Handle {
        return .{ .cap = this.cap };
    }
};

/// capability to the virtual memory structure
pub const Vmem = extern struct {
    cap: u32 = 0,

    pub var self: @This() = .{};

    pub const object_type = abi.ObjectType.vmem;
    pub const default_rights = abi.sys.Rights{
        .read = true,
        .write = true,
        .exec = true,
        .user = true,
        .vmem_map = true,
        .clone = true,
        .transfer = true,
    };

    pub fn create() sys.Error!@This() {
        const cap = try sys.vmemCreate();
        return .{ .cap = cap };
    }

    pub fn createSelf() sys.Error!@This() {
        const cap = try sys.vmemSelf();
        return .{ .cap = cap };
    }

    pub fn clone(this: @This()) sys.Error!@This() {
        const cap = try sys.handleDuplicate(this.cap);
        return .{ .cap = cap };
    }

    pub fn close(this: @This()) void {
        std.debug.assert(this.cap != self.cap);
        sys.handleClose(this.cap);
    }

    /// if length is zero, the rest of the frame is mapped
    pub fn map(
        this: @This(),
        frame: Frame,
        frame_offset: usize,
        vaddr: usize,
        length: usize,
        flags: abi.sys.MapFlags,
    ) sys.Error!usize {
        const name = if (@hasDecl(@import("root"), "manifest")) @import("root").manifest.name else "<unknown>";
        if (this.cap == 0) std.log.err("vmem is null {s}", .{name});
        if (frame.cap == 0) std.log.err("frame is null {s}", .{name});

        return sys.vmemMap(
            this.cap,
            frame.cap,
            frame_offset,
            vaddr,
            length,
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

    pub fn handle(this: @This()) Handle {
        return .{ .cap = this.cap };
    }
};

/// capability to a physical memory region (sized `ChunkSize`)
pub const Frame = extern struct {
    cap: u32 = 0,

    pub const object_type = abi.ObjectType.frame;
    pub const default_rights = abi.sys.Rights{
        .read = true,
        .write = true,
        .exec = true,
        .user = true,
        .frame_map = true,
        .clone = true,
        .transfer = true,
    };

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
    }

    pub const Reader = struct {
        frame: Frame, // borrowed frame
        read: usize = 0,
        size: usize,
        interface: std.Io.Reader,

        fn stream(
            r: *std.Io.Reader,
            w: *std.Io.Writer,
            limit: std.Io.Limit,
        ) std.Io.Reader.StreamError!usize {
            if (limit == .nothing) return 0;

            const self: *@This() = @fieldParentPtr("interface", r);

            const dest = limit.slice(try w.writableSliceGreedy(1));

            const n = @min(dest.len, self.size -| self.read);
            if (n == 0) return error.EndOfStream;
            try self.frame.read(self.read, dest[0..n]);
            self.read += n;

            w.advance(n);
            return n;
        }

        fn discard(r: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
            const self: *@This() = @fieldParentPtr("interface", r);

            const n = @min(self.size -| self.read, @intFromEnum(limit));
            self.read += n;

            return n;
        }
    };

    pub fn reader(this: @This(), buffer: []u8, frame_size: usize) Reader {
        return .{
            .frame = this,
            .size = frame_size,
            .interface = .{
                .buffer = buffer,
                .vtable = &.{
                    .stream = Reader.stream,
                    .discard = Reader.discard,
                },
            },
        };
    }

    pub const Writer = struct {
        frame: Frame, // borrowed frame
        write: usize = 0,
        size: usize,
        interface: std.Io.Writer,

        fn wr(self: *@This(), bytes: []const u8) error{WriteFailed}!usize {
            const n = @min(bytes.len, self.size -| self.write);
            if (n != 0) {
                self.frame.write(self.write, bytes[0..n]) catch return error.WriteFailed;
            }
            return n;
        }

        fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const self: *@This() = @fieldParentPtr("interface", w);

            {
                const written = self.wr(w.buffer[0..w.end]) catch return error.WriteFailed;
                if (written != w.end) return error.WriteFailed;
                w.end = 0;
            }

            const pattern = data[data.len - 1];
            var n: usize = 0;

            for (data[0 .. data.len - 1]) |bytes| {
                const written = try self.wr(bytes);
                if (written == 0) return n;
                n += written;
            }
            for (0..splat) |_| {
                const written = try self.wr(pattern);
                if (written == 0) return n;
                n += written;
            }
            return n;
        }
    };

    pub fn writer(this: @This(), buffer: []u8, frame_size: usize) Writer {
        return .{
            .frame = this,
            .size = frame_size,
            .interface = .{
                .buffer = buffer,
                .vtable = &.{
                    .drain = Writer.drain,
                },
            },
        };
    }

    pub fn dummyAccess(this: @This(), offset_byte: usize, mode: sys.FaultCause) sys.Error!void {
        return try sys.frameDummyAccess(this.cap, offset_byte, mode);
    }

    pub fn dump(this: @This()) sys.Error!void {
        return try sys.frameDump(this.cap);
    }

    pub fn handle(this: @This()) Handle {
        return .{ .cap = this.cap };
    }
};

pub fn channel() sys.Error!struct { Receiver, Sender } {
    const rx, const tx = try abi.sys.channelCreate();
    return .{ .{ .cap = rx }, .{ .cap = tx } };
}

/// capability to **the** receiver end of an endpoint,
/// there can only be a single receiver
pub const Receiver = extern struct {
    cap: u32 = 0,

    pub const object_type = abi.ObjectType.receiver;
    pub const default_rights = abi.sys.Rights{
        .clone = true,
        .transfer = true,
    };

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

    pub fn handle(this: @This()) Handle {
        return .{ .cap = this.cap };
    }
};

/// capability to **a** sender end of an endpoint,
/// there can be multiple senders
pub const Sender = extern struct {
    cap: u32 = 0,

    pub const object_type = abi.ObjectType.sender;
    pub const default_rights = abi.sys.Rights{
        .clone = true,
        .transfer = true,
        .tag = true,
    };

    pub fn clone(this: @This()) sys.Error!@This() {
        const cap = try sys.handleDuplicate(this.cap);
        return .{ .cap = cap };
    }

    pub fn close(this: @This()) void {
        sys.handleClose(this.cap);
    }

    pub fn stamp(self: @This(), s: u32) sys.Error!@This() {
        const cap = try sys.senderStamp(self.cap, s);
        return .{ .cap = cap };
    }

    /// helper to stamp and restrict the sender to create a new sender that cannot be stamped
    pub fn stampFinal(self: @This(), s: u32) sys.Error!@This() {
        const new = try self.stamp(s);
        try new.handle().restrict(sys.Rights.common);
        return new;
    }

    pub fn call(self: @This(), msg: sys.Message) sys.Error!sys.Message {
        return try sys.senderCall(self.cap, msg);
    }

    pub fn handle(this: @This()) Handle {
        return .{ .cap = this.cap };
    }
};

/// capability to **a** reply object
/// it can be saved/loaded from receiver or replied with
pub const Reply = extern struct {
    cap: u32 = 0,

    pub const object_type = abi.ObjectType.reply;
    pub const default_rights = abi.sys.Rights{
        .transfer = true,
    };

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

    pub fn handle(this: @This()) Handle {
        return .{ .cap = this.cap };
    }
};

/// capability to **a** notify object
/// there can be multiple of them
pub const Notify = extern struct {
    cap: u32 = 0,

    pub const object_type = abi.ObjectType.notify;
    pub const default_rights = abi.sys.Rights{
        .clone = true,
        .transfer = true,
    };

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

    pub fn handle(this: @This()) Handle {
        return .{ .cap = this.cap };
    }
};

/// x86 specific capability that allows allocating `x86_ioport` capabilities
pub const X86IoPortAllocator = extern struct {
    cap: u32 = 0,

    pub const object_type = abi.ObjectType.x86_ioport_allocator;
    pub const default_rights = abi.sys.Rights{
        .clone = true,
        .transfer = true,
    };

    pub fn clone(this: @This()) sys.Error!@This() {
        const cap = try sys.handleDuplicate(this.cap);
        return .{ .cap = cap };
    }

    pub fn close(this: @This()) void {
        sys.handleClose(this.cap);
    }

    pub fn handle(this: @This()) Handle {
        return .{ .cap = this.cap };
    }
};

/// x86 specific capability that gives access to one IO port
pub const X86IoPort = extern struct {
    cap: u32 = 0,

    pub const object_type = abi.ObjectType.x86_ioport;
    pub const default_rights = abi.sys.Rights{
        .clone = true,
        .transfer = true,
    };

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

    pub fn handle(this: @This()) Handle {
        return .{ .cap = this.cap };
    }
};

/// x86 specific capability that allows allocating `x86_irq` capabilities
pub const X86IrqAllocator = extern struct {
    cap: u32 = 0,

    pub const object_type = abi.ObjectType.x86_irq_allocator;
    pub const default_rights = abi.sys.Rights{
        .clone = true,
        .transfer = true,
    };

    pub fn clone(this: @This()) sys.Error!@This() {
        const cap = try sys.handleDuplicate(this.cap);
        return .{ .cap = cap };
    }

    pub fn close(this: @This()) void {
        sys.handleClose(this.cap);
    }

    pub fn handle(this: @This()) Handle {
        return .{ .cap = this.cap };
    }
};

/// x86 specific capability that gives access to one IRQ (= interrupt request)
pub const X86Irq = extern struct {
    cap: u32 = 0,

    pub const object_type = abi.ObjectType.x86_irq;
    pub const default_rights = abi.sys.Rights{
        .clone = true,
        .transfer = true,
    };

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

    pub fn ack(self: @This()) sys.Error!void {
        try sys.x86IrqAck(self.cap);
    }

    pub fn handle(this: @This()) Handle {
        return .{ .cap = this.cap };
    }
};
