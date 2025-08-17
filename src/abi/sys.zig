const std = @import("std");
const builtin = @import("builtin");

const abi = @import("lib.zig");
const ring = @import("ring.zig");

//

pub const Id = enum(usize) {
    /// print debug logs to serial output
    log = 1,
    /// manually panic the kernel from user-space in debug mode
    kernel_panic,

    /// create a new `Frame` object that can be mapped to one or many `Vmem`s
    frame_create,
    /// get the `Frame` object's size in bytes
    frame_get_size,
    // TODO:
    // /// resize the `Frame` object
    // frame_set_size,
    /// read from a `Frame` capability
    frame_read,
    /// write into a `Frame` capability
    frame_write,
    /// dummy read/write/exec access to a specific page of a `Frame`,
    /// effectively triggering a page fault without having to map
    frame_dummy_access,
    /// print all page indices to serial output
    frame_dump,

    /// create a new `Vmem` object that handles a single virtual address space
    vmem_create,
    /// create a new handle to the current `Vmem`
    vmem_self,
    /// map a part of (or the whole) `Frame` into this `Vmem`
    vmem_map,
    /// unmap any virtual address space region from this `Vmem`
    vmem_unmap,
    /// read from a `Vmem` capability
    vmem_read,
    /// write into a `Vmem` capability
    vmem_write,
    /// dummy read/write/exec access to a specific page of a `Vmem`,
    /// effectively triggering a page fault without having to ctx switch
    vmem_dummy_access,
    /// print all `Vmem` -> `Frame` mappings to serial output
    /// followed by all hardware page table vaddr -> paddr mappings
    vmem_dump,

    /// create a new `Process` object that handles a single process
    /// capability handles are tied to processes
    proc_create,
    /// create a new handle to the current `Process`
    proc_self,
    /// move a capability from the current process into the target process
    proc_give_cap,

    /// create a new `Thread` object that handles a single thread within a single process
    thread_create,
    /// create a new handle to the current `Thread`
    thread_self,
    /// read all registers of a stopped `Thread`
    thread_read_regs,
    /// write all registers of a stopped `Thread`
    thread_write_regs,
    /// start a stopped/new `Thread`
    thread_start,
    /// stop a running `Thread`
    thread_stop,
    /// modify `Thread` priority, the priority can only be as high as the highest priority in the current process
    thread_set_prio,
    /// wait for the exit code from the given `Thread`
    thread_wait,
    /// set `Thread` signal handler instruction pointer, the handler is like a hardware interrupt handler
    thread_set_sig_handler,

    /// create a new `Receiver` object that is the receiver end of a new IPC queue
    receiver_create,
    // receiver_subscribe,
    /// wait until a matching `Sender.call` is called and return the message
    receiver_recv,
    /// non-blocking reply to the last caller with a message
    receiver_reply,
    /// combined `receiver_reply` + `receiver_recv`
    receiver_reply_recv,

    /// save the last caller into a new `Reply` object to allow another `receiver_recv` before `receiver_reply`
    reply_create,
    /// non-blocking reply to the last caller with a message
    reply_reply,

    /// create a new `Sender` object that is the sender end of some already existing IPC queue
    sender_create,
    // sender_send, // TODO: non-blocking call
    /// wait until a matching `Receiver.recv` is called and switch to that thread
    /// with a provided message, and return the reply message
    sender_call,

    // TODO: maybe make all kernel objects be 'waitable' and 'notifyable'
    /// create a new `Notify` object that is a messageless IPC structure
    notify_create,
    /// wait until this `Notify` is notified with `notify_notify`,
    /// or return immediately if it was already notified
    notify_wait,
    /// check if this `Notify` object is already notified
    notify_poll,
    /// notify this `Notify` object and wake up sleepers
    notify_notify,

    /// create a new `X86IoPort` object that manages a single x86 I/O port
    /// TODO: use I/O Permissions Bitmap in the TSS to do port io from user-space
    x86_ioport_create,
    /// `inb` instruction on the specific provided `X86IoPort` port
    x86_ioport_inb,
    /// `outb` instruction on the specific provided `X86IoPort` port
    x86_ioport_outb,

    /// create a new `X86Irq` object that manages a single x86 interrupt vector
    x86_irq_create,
    /// acquire a handle to some `Notify` object that gets notified every time this IRQ is generated
    x86_irq_subscribe,
    /// queue an EOI to the interrupt controller
    x86_irq_ack,

    /// identify which object type some capability is
    handle_identify,
    /// query handle rights
    handle_rights,
    /// remove rights from a handle
    handle_restrict,
    /// create another handle to the same object
    handle_duplicate,
    /// close a handle to some object, might or might not delete the object
    handle_close,

    /// sleep if the stored value at the given address is the given value
    futex_wait,
    /// wake up a given count of threads that were waiting on a given address
    futex_wake,
    /// if the stored value at the given old address is the given value,
    /// then wakes up a given count of threads and moves a given count
    /// of threads to wait for the given new address
    futex_requeue,

    /// give up the CPU for other tasks
    self_yield,
    /// stop the active thread
    self_stop,
    /// print arch.TrapRegs to serial output
    self_dump,
    /// set an extra IPC register of this thread
    self_set_extra,
    /// get and zero an extra IPC register of this thread
    self_get_extra,
    /// get active signal handler return address
    self_get_signal,
};

/// capability or mapping rights
pub const Rights = packed struct {
    /// the frame can be read
    read: bool = false,
    /// the frame can be written
    write: bool = false,
    /// the frame can be executed (only usable with mapping)
    exec: bool = false,
    /// the frame can be user accessible (only usable with mapping)
    user: bool = false,
    /// the frame can be mapped
    frame_map: bool = false,
    /// the vmem can have frames mapped into
    vmem_map: bool = false,

    /// the handle can be cloned
    clone: bool = false,
    /// the handle can be sent via IPC
    transfer: bool = false,
    /// the handle tag can be changed (only usable with `Sender`s)
    tag: bool = false,

    _: u55 = 0,

    pub const Self = @This();

    pub const common: Self = .{
        .clone = true,
        .transfer = true,
    };

    pub fn merge(self: Self, other: Self) Self {
        return Self.decode(self.encode() | other.encode());
    }

    pub fn intersect(self: Self, other: Self) Self {
        return Self.decode(self.encode() & other.encode());
    }

    pub fn contains(self: Self, at_least: Self) bool {
        return self.intersect(at_least).encode() == at_least.encode();
    }

    pub fn isEmpty(self: Self) bool {
        return self.encode() == 0;
    }

    pub fn encode(self: Self) u64 {
        return @bitCast(self);
    }

    pub fn decode(i: u64) Self {
        return @bitCast(i);
    }
};

/// https://wiki.osdev.org/Paging#PAT
pub const CacheType = enum(u8) {
    /// All accesses are uncacheable.
    /// Write combining is not allowed.
    /// Speculative accesses are not allowed.
    uncacheable = 3,
    /// All accesses are uncacheable.
    /// Write combining is allowed.
    /// Speculative reads are allowed.
    write_combining = 4,
    /// Reads allocate cache lines on a cache miss.
    /// Cache lines are not allocated on a write miss.
    /// Write hits update the cache and main memory.
    write_through = 1,
    /// Reads allocate cache lines on a cache miss.
    /// All writes update main memory.
    /// Cache lines are not allocated on a write miss.
    /// Write hits invalidate the cache line and update main memory.
    write_protect = 5,
    /// Reads allocate cache lines on a cache miss,
    /// and can allocate to either the shared, exclusive, or modified state.
    /// Writes allocate to the modified state on a cache miss.
    write_back = 0,
    /// Same as uncacheable,
    /// except that this can be overriden by Write-Combining MTRRs.
    uncached = 2,

    pub fn patMsr() u64 {
        return (@as(u64, 6) << 0) |
            (@as(u64, 4) << 8) |
            (@as(u64, 7) << 16) |
            (@as(u64, 0) << 24) |
            (@as(u64, 1) << 32) |
            (@as(u64, 5) << 40) |
            (@as(u64, 0) << 48) |
            (@as(u64, 0) << 56);
    }
};

/// extra mapping flags
pub const MapFlags = packed struct {
    // protection_key: u8 = 0,
    cache: CacheType = .write_back,
    fixed: bool = false,
    /// map as readable
    ///
    /// forced to be true if any other mapping modes (write,exec)
    /// are set to true due to hardware limitations
    ///
    /// if read, write and exec are all false, the mapping is a guard mapping
    read: bool = true,
    /// map as writable
    write: bool = false,
    /// map as executable
    exec: bool = false,
    /// map as user accessible
    user: bool = true,

    _: u3 = 0,

    pub const ur: @This() = .{
        .read = true,
        .user = true,
    };
    pub const urw: @This() = .{
        .read = true,
        .write = true,
        .user = true,
    };
    pub const urwx: @This() = .{
        .read = true,
        .write = true,
        .exec = true,
        .user = true,
    };
    pub const urx: @This() = .{
        .read = true,
        .exec = true,
        .user = true,
    };
    pub const kr: @This() = .{
        .read = true,
        .user = false,
    };
    pub const krw: @This() = .{
        .read = true,
        .write = true,
        .user = false,
    };
    pub const krwx: @This() = .{
        .read = true,
        .write = true,
        .exec = true,
        .user = false,
    };
    pub const krx: @This() = .{
        .read = true,
        .exec = true,
        .user = false,
    };

    pub fn intersection(self: @This(), other: @This()) @This() {
        var new = self;
        new.read = new.read and other.read;
        new.write = new.write and other.write;
        new.exec = new.exec and other.exec;
        return new;
    }

    pub fn encode(self: @This()) u16 {
        return @bitCast(self);
    }

    pub fn decode(i: u16) @This() {
        return @bitCast(i);
    }
};

/// page fault access cause
pub const FaultCause = enum(u8) {
    read,
    write,
    exec,
};

/// syscall interface Error type
pub const Error = error{
    Unimplemented,
    InvalidAddress,
    InvalidFlags,
    InvalidType,
    InvalidArgument,
    InvalidCapability,
    InvalidSyscall,
    OutOfMemory,
    OutOfVirtualMemory,
    // FIXME: remove
    EntryNotPresent,
    // FIXME: remove
    EntryIsHuge,
    NotStopped,
    IsStopped,
    // FIXME: remove
    NoVmem,
    // FIXME: remove
    ThreadSafety,
    AlreadyMapped,
    NotMapped,
    MappingOverlap,
    PermissionDenied,
    Internal,
    NoReplyTarget,
    NotifyAlreadySubscribed,
    IrqAlreadySubscribed,
    IrqNotReady,
    TooManyIrqs,
    OutOfBounds,
    NotFound,
    ReadFault,
    WriteFault,
    ExecFault,
    NullHandle,
    BadHandle,
    Retry,

    UnknownError,
};

pub const ErrorEnum = enum(u8) {
    unimplemented,
    invalid_address,
    invalid_flags,
    invalid_type,
    invalid_argument,
    invalid_capability,
    invalid_syscall,
    out_of_memory,
    out_of_virtual_memory,
    entry_not_present,
    entry_is_huge,
    not_stopped,
    is_stopped,
    no_vmem,
    thread_safety,
    already_mapped,
    not_mapped,
    mapping_overlap,
    permission_denied,
    internal,
    no_reply_target,
    notify_already_subscribed,
    irq_already_subscribed,
    irq_not_ready,
    too_many_irqs,
    out_of_bounds,
    not_found,
    read_fault,
    write_fault,
    exec_fault,
    null_handle,
    bad_handle,
    retry,
    _,
};

pub fn errorToInt(err: Error) u32 {
    if (!builtin.is_test)
        std.debug.assert(err != Error.UnknownError);
    const errors = @typeInfo(Error).error_set.?;

    switch (err) {
        inline else => |_comptime_err| {
            const comptime_err: Error = comptime _comptime_err;
            inline for (errors, 0..) |err_info, i| {
                if (comptime @field(Error, err_info.name) == comptime_err) {
                    // only the switch and this return stmt
                    // will be left in the generated code
                    return i;
                }
            } else unreachable;
        },
    }
}

pub fn intToError(i: usize) Error {
    const errors = @typeInfo(Error).error_set.?;

    switch (i) {
        errors.len...std.math.maxInt(usize) => return Error.UnknownError,

        inline else => |j| {
            return @field(Error, errors[j].name);
        },
    }
}

pub fn errorToEnum(err: Error) ErrorEnum {
    return @enumFromInt(errorToInt(err));
}

pub fn enumToError(err: ErrorEnum) Error {
    return intToError(@intFromEnum(err));
}

pub fn Result(comptime Ok: type) type {
    return abi.Result(Ok, ErrorEnum);
}

pub fn encode(result: Error!u63) usize {
    if (result) |ok| {
        return ok;
    } else |err| {
        return encodeError(err);
    }
}

pub fn encodeVoid(result: Error!void) usize {
    result catch |err| {
        return encodeError(err);
    };
    return 0;
}

fn encodeError(err: Error) usize {
    return @bitCast(-@as(isize, errorToInt(err)));
}

pub fn decode(v: usize) Error!usize {
    const v_isize: isize = @bitCast(v);
    const err = -v_isize;

    return switch (err) {
        std.math.minInt(isize)...0 => v,
        else => intToError(@intCast(err)),
    };
}

pub fn decodeVoid(v: usize) Error!void {
    _ = try decode(v);
}

/// x86_64 thread registers
pub const ThreadRegs = extern struct {
    r15: u64 = 0,
    r14: u64 = 0,
    r13: u64 = 0,
    r12: u64 = 0,
    r11: u64 = 0,
    /// r10
    arg5: u64 = 0,
    /// r9
    arg4: u64 = 0,
    /// r8
    arg3: u64 = 0,
    rbp: u64 = 0,
    /// rsi
    arg1: u64 = 0,
    /// rdi
    arg0: u64 = 0,
    /// rdx
    arg2: u64 = 0,
    rcx: u64 = 0,
    rbx: u64 = 0,
    /// rax, also the return register
    syscall_id: u64 = 0,

    rip: u64 = 0,
    rsp: u64 = 0,
};

/// small IPC message
pub const Message = extern struct {
    /// capability id when sending, or stamp id when receiving
    cap_or_stamp: u32 = 0,
    /// Number of extra arguments in the thread extra arguments array.
    /// They can contain capabilities that have their ownership
    /// automatically transferred.
    extra: u32 = 0, // u7
    // fast registers \/
    arg0: usize = 0,
    arg1: usize = 0,
    arg2: usize = 0,
    arg3: usize = 0,
    arg4: usize = 0,
};

pub const PackedMessage = extern struct {
    cap_or_stamp_and_extra: usize = 0,
    arg0: usize = 0,
    arg1: usize = 0,
    arg2: usize = 0,
    arg3: usize = 0,
    arg4: usize = 0,
};

pub const ThreadStatus = enum {
    /// thread is not running, nor waiting
    stopped,
    /// thread is actively running on some CPU
    running,
    /// thread is ready to run, but is being starved
    ready,
    /// thread is blocked
    waiting,
};

comptime {
    std.debug.assert(@sizeOf(Message) == @sizeOf([6]usize));
}

pub fn dummyRead(b: []const u8) void {
    if (b.len == 0) return;

    const beg = std.math.divFloor(
        usize,
        @intFromPtr(&b[0]),
        0x1000,
    ) catch unreachable;
    const end = std.math.divFloor(
        usize,
        @intFromPtr(&b[b.len - 1]),
        0x1000,
    ) catch unreachable;

    for (beg..end) |page| {
        const page_byte: *const volatile u8 = @ptrFromInt(page * 0x1000);
        _ = page_byte.*;
    }
}

pub fn dummyWrite(slice: anytype) void {
    if (slice.len == 0) return;

    const beg = std.math.divFloor(
        usize,
        @intFromPtr(&slice[0]),
        0x1000,
    ) catch unreachable;
    const end = std.math.divFloor(
        usize,
        @intFromPtr(&slice[slice.len - 1]),
        0x1000,
    ) catch unreachable;

    for (beg..end) |page| {
        const page_byte: *volatile u8 = @ptrFromInt(page * 0x1000);
        page_byte.* = 0;
    }
}

// SYSCALLS

pub fn log(s: []const u8) void {
    var bytes = s;

    while (true) {
        var progress: usize = 0;
        _ = syscall(
            .log,
            .{ @intFromPtr(bytes.ptr), bytes.len },
            .{&progress},
        ) catch |err| switch (err) {
            Error.Retry => {
                @branchHint(.cold);
                bytes = bytes[progress..];

                dummyRead(bytes);
                continue;
            },
            else => std.debug.panic("unexpected error: {}", .{err}),
        };

        return;
    }
}

pub fn kernelPanic() noreturn {
    if (!abi.conf.KERNEL_PANIC_SYSCALL) @compileError("debug kernel panics not enabled");
    _ = syscall(.kernel_panic, .{}, .{}) catch {};
    unreachable;
}

pub fn frameCreate(size_bytes: usize) Error!u32 {
    return @intCast(try syscall(.frame_create, .{size_bytes}, .{}));
}

pub fn frameGetSize(frame: u32) Error!usize {
    var size: usize = undefined;
    _ = try syscall(.frame_get_size, .{frame}, .{&size});
    return size;
}

pub fn frameRead(
    frame: u32,
    offset_byte: usize,
    dst: []u8,
    progress: *usize,
) Error!void {
    _ = try syscall(
        .frame_read,
        .{ frame, offset_byte, @intFromPtr(dst.ptr), dst.len },
        .{progress},
    );
}

pub fn frameWrite(
    frame: u32,
    offset_byte: usize,
    src: []const u8,
    progress: *usize,
) Error!void {
    _ = try syscall(
        .frame_write,
        .{ frame, offset_byte, @intFromPtr(src.ptr), src.len },
        .{progress},
    );
}

pub fn frameDummyAccess(frame: u32, offset_byte: usize, mode: FaultCause) Error!void {
    _ = try syscall(.frame_dummy_access, .{ frame, offset_byte, @intFromEnum(mode) }, .{});
}

pub fn frameDump(frame: u32) Error!void {
    _ = try syscall(.frame_dump, .{frame}, .{});
}

pub fn vmemCreate() Error!u32 {
    return @intCast(try syscall(.vmem_create, .{}, .{}));
}

pub fn vmemSelf() Error!u32 {
    return @intCast(try syscall(.vmem_self, .{}, .{}));
}

/// if length is zero, the rest of the frame is mapped
pub fn vmemMap(
    vmem: u32,
    frame: u32,
    frame_offset: usize,
    vaddr: usize,
    length: usize,
    flags: MapFlags,
) Error!usize {
    return try syscall(.vmem_map, .{
        vmem, frame, frame_offset, vaddr, length, flags.encode(),
    }, .{});
}

pub fn vmemUnmap(vmem: u32, vaddr: usize, length: usize) Error!void {
    _ = try syscall(.vmem_unmap, .{
        vmem, vaddr, length,
    }, .{});
}

pub fn vmemRead(
    vmem: u32,
    vaddr: usize,
    dst: []u8,
    progress: *usize,
) Error!void {
    _ = try syscall(
        .vmem_read,
        .{ vmem, vaddr, @intFromPtr(dst.ptr), dst.len },
        .{progress},
    );
}

pub fn vmemWrite(
    vmem: u32,
    vaddr: usize,
    src: []const u8,
    progress: *usize,
) Error!void {
    _ = try syscall(
        .vmem_write,
        .{ vmem, vaddr, @intFromPtr(src.ptr), src.len },
        .{progress},
    );
}

pub fn vmemDummyAccess(vmem: u32, vaddr: usize, mode: FaultCause) Error!void {
    _ = try syscall(.vmem_dummy_access, .{ vmem, vaddr, @intFromEnum(mode) }, .{});
}

pub fn vmemDump(vmem: u32) Error!void {
    _ = try syscall(.vmem_dump, .{vmem}, .{});
}

pub fn procCreate(vmem: u32) Error!u32 {
    return @intCast(try syscall(.proc_create, .{vmem}, .{}));
}

pub fn procSelf() Error!u32 {
    return @intCast(try syscall(.proc_self, .{}, .{}));
}

pub fn procGiveCap(proc: u32, cap: u32) Error!u32 {
    return @intCast(try syscall(.proc_give_cap, .{ proc, cap }, .{}));
}

pub fn threadCreate(proc: u32) Error!u32 {
    return @intCast(try syscall(.thread_create, .{proc}, .{}));
}

pub fn threadSelf() Error!u32 {
    return @intCast(try syscall(.thread_self, .{}, .{}));
}

pub fn threadReadRegs(thread: u32, dst: *ThreadRegs) Error!void {
    // FIXME: this call can fail with Error.Retry

    _ = try syscall(.thread_read_regs, .{
        thread,
        @intFromPtr(dst),
    }, .{});
}

pub fn threadWriteRegs(thread: u32, dst: *const ThreadRegs) Error!void {
    // FIXME: this call can fail with Error.Retry

    _ = try syscall(.thread_write_regs, .{
        thread,
        @intFromPtr(dst),
    }, .{});
}

pub fn threadStart(thread: u32) Error!void {
    _ = try syscall(.thread_start, .{
        thread,
    }, .{});
}

pub fn threadStop(thread: u32) Error!void {
    _ = try syscall(.thread_stop, .{
        thread,
    }, .{});
}

pub fn threadSetPrio(thread: u32, prio: u2) Error!void {
    _ = try syscall(.thread_set_prio, .{
        thread,
        prio,
    }, .{});
}

pub fn threadWait(proc: u32) Error!usize {
    var exit_code: usize = undefined;
    _ = try syscall(.thread_wait, .{proc}, .{&exit_code});
    return exit_code;
}

pub fn threadSetSigHandler(thread: u32, ip: usize) !void {
    _ = try syscall(.thread_set_sig_handler, .{ thread, ip }, .{});
}

pub fn receiverCreate() Error!u32 {
    return @intCast(try syscall(.receiver_create, .{}, .{}));
}

pub fn receiverRecv(recv: u32) Error!Message {
    var msg_regs: PackedMessage = undefined;

    _ = try syscall(.receiver_recv, .{
        recv,
    }, .{
        &msg_regs.cap_or_stamp_and_extra,
        &msg_regs.arg0,
        &msg_regs.arg1,
        &msg_regs.arg2,
        &msg_regs.arg3,
        &msg_regs.arg4,
    });

    return @bitCast(msg_regs);
}

pub fn receiverReply(recv: u32, msg: Message) Error!void {
    var _msg = msg;
    _msg.cap_or_stamp = recv;
    const msg_regs = @as(PackedMessage, @bitCast(_msg));

    _ = try syscall(.receiver_reply, msg_regs, .{});
}

pub fn receiverReplyRecv(recv: u32, msg: Message) Error!Message {
    var _msg = msg;
    _msg.cap_or_stamp = recv;
    var msg_regs = @as(PackedMessage, @bitCast(_msg));

    _ = try syscall(.receiver_reply_recv, msg_regs, .{
        &msg_regs.cap_or_stamp_and_extra,
        &msg_regs.arg0,
        &msg_regs.arg1,
        &msg_regs.arg2,
        &msg_regs.arg3,
        &msg_regs.arg4,
    });

    return @bitCast(msg_regs);
}

pub fn replyCreate() Error!u32 {
    return @intCast(try syscall(.reply_create, .{}, .{}));
}

pub fn replyReply(reply: u32, msg: Message) Error!void {
    var _msg = msg;
    _msg.cap_or_stamp = reply;
    const msg_regs = @as(PackedMessage, @bitCast(_msg));

    _ = try syscall(
        .reply_reply,
        msg_regs,
        .{},
    );
}

pub fn senderCreate(recv: u32, stamp: u32) Error!u32 {
    return @intCast(try syscall(.sender_create, .{ recv, stamp }, .{}));
}

pub fn senderCall(recv: u32, msg: Message) Error!Message {
    var _msg = msg;
    _msg.cap_or_stamp = recv;
    var msg_regs = @as(PackedMessage, @bitCast(_msg));

    _ = try syscall(.sender_call, msg_regs, .{
        &msg_regs.cap_or_stamp_and_extra,
        &msg_regs.arg0,
        &msg_regs.arg1,
        &msg_regs.arg2,
        &msg_regs.arg3,
        &msg_regs.arg4,
    });

    return @bitCast(msg_regs);
}

pub fn notifyCreate() Error!u32 {
    return @intCast(try syscall(.notify_create, .{}, .{}));
}

pub fn notifyWait(notify: u32) Error!void {
    _ = try syscall(.notify_wait, .{notify}, .{});
}

pub fn notifyPoll(notify: u32) Error!bool {
    return try syscall(.notify_wait, .{notify}, .{}) != 0;
}

pub fn notifyNotify(notify: u32) Error!bool {
    return try syscall(.notify_notify, .{notify}, .{}) != 0;
}

pub fn x86IoPortCreate(x86_ioport_allocator: u32, port: u16) Error!u32 {
    return @intCast(try syscall(.x86_ioport_create, .{ x86_ioport_allocator, port }, .{}));
}

pub fn x86IoPortInb(x86_ioport: u32) Error!u8 {
    return @intCast(try syscall(.x86_ioport_inb, .{x86_ioport}, .{}));
}

pub fn x86IoPortOutb(x86_ioport: u32, byte: u8) Error!void {
    _ = try syscall(.x86_ioport_outb, .{ x86_ioport, byte }, .{});
}

pub fn x86IrqCreate(x86_irq_allocator: u32, irq: u8) Error!u32 {
    return @intCast(try syscall(.x86_irq_create, .{ x86_irq_allocator, irq }, .{}));
}

pub fn x86IrqSubscribe(x86_irq: u32) Error!u32 {
    return @intCast(try syscall(.x86_irq_subscribe, .{x86_irq}, .{}));
}

pub fn x86IrqAck(x86_irq: u32) Error!void {
    _ = try syscall(.x86_irq_ack, .{x86_irq}, .{});
}

pub fn handleIdentify(cap: u32) abi.ObjectType {
    return std.meta.intToEnum(
        abi.ObjectType,
        syscall(.handle_identify, .{cap}, .{}) catch unreachable,
    ) catch .null;
}

pub fn handleRights(cap: u32) Error!Rights {
    var rights: u64 = undefined;
    _ = try syscall(.handle_rights, .{cap}, .{&rights});
    return .decode(rights);
}

pub fn handleRestrict(cap: u32, mask: Rights) Error!void {
    _ = try syscall(.handle_restrict, .{ cap, mask.encode() }, .{});
}

pub fn handleDuplicate(cap: u32) Error!u32 {
    return @intCast(try syscall(.handle_duplicate, .{cap}, .{}));
}

pub fn handleClose(cap: u32) void {
    if (builtin.is_test) return;
    _ = syscall(.handle_close, .{cap}, .{}) catch unreachable;
}

pub const FutexFlags = packed struct {
    /// bit width of the atomic operation
    size: enum(u3) {
        bits8,
        bits16,
        bits32,
        bits64,
        bits128,
        _,
    },
    /// operate only on the `Vmem` instead of mapped `Frame`s
    private: bool = false,
    _: u4 = 0,

    pub fn fromInt(v: u8) @This() {
        return @bitCast(v);
    }

    pub fn asInt(self: @This()) u8 {
        return @bitCast(self);
    }
};

/// sleep if the stored value at the given address is the given value
pub fn futexWait(
    addr: *anyopaque,
    value: usize,
    flags: FutexFlags,
) Error!void {
    while (true) {
        _ = syscall(.futex_wait, .{
            @intFromPtr(addr),
            value,
            flags.asInt(),
        }, .{}) catch |err| switch (err) {
            Error.Retry => {
                @branchHint(.cold);
                dummyRead(@as([*]const u8, @ptrCast(addr))[0..1]);
                continue;
            },
            else => return err,
        };

        break;
    }
}

/// wake up a given count of threads that were waiting on a given address
pub fn futexWake(
    addr: *anyopaque,
    count: usize,
    flags: FutexFlags,
) Error!void {
    while (true) {
        _ = syscall(.futex_wake, .{
            @intFromPtr(addr),
            count,
            flags.asInt(),
        }, .{}) catch |err| switch (err) {
            Error.Retry => {
                @branchHint(.cold);
                dummyRead(@as([*]const u8, @ptrCast(addr))[0..1]);
                continue;
            },
            else => return err,
        };

        break;
    }
}

/// if the stored value at the given old address is the given value,
/// then wakes up a given count of threads and moves a given count
/// of threads to wait for the given new address
pub fn futexRequeue(
    old_addr: *anyopaque,
    new_addr: *anyopaque,
    wake_count: usize,
    move_count: usize,
    value: usize,
    flags: FutexFlags,
) Error!void {
    while (true) {
        _ = syscall(.futex_requeue, .{
            @intFromPtr(old_addr),
            @intFromPtr(new_addr),
            wake_count,
            move_count,
            value,
            flags.asInt(),
        }, .{}) catch |err| switch (err) {
            Error.Retry => {
                @branchHint(.cold);
                dummyRead(@as([*]const u8, @ptrCast(old_addr))[0..1]);
                dummyRead(@as([*]const u8, @ptrCast(new_addr))[0..1]);
                continue;
            },
            else => return err,
        };

        break;
    }
}

pub fn selfYield() void {
    _ = syscall(.self_yield, .{}, .{}) catch unreachable;
}

pub fn selfStop(code: usize) noreturn {
    _ = syscall(.self_stop, .{code}, .{}) catch {};
    unreachable;
}

pub fn selfDump() void {
    _ = syscall(.self_dump, .{}, .{}) catch unreachable;
}

pub const ExtraReg = struct { val: u64 = 0, is_cap: bool = false };

var mock_extra_regs: [128]ExtraReg = [1]ExtraReg{.{}} ** 128;

pub fn selfSetExtra(idx: u7, val: u64, is_cap: bool) Error!void {
    if (builtin.is_test) {
        mock_extra_regs[idx] = .{ .val = val, .is_cap = is_cap };
        return;
    }

    _ = try syscall(.self_set_extra, .{
        idx, val, @intFromBool(is_cap),
    }, .{});
}

pub fn selfGetExtra(idx: u7) Error!ExtraReg {
    if (builtin.is_test) {
        const res = mock_extra_regs[idx];
        mock_extra_regs[idx] = .{};
        return res;
    }

    var val: u64 = undefined;
    const is_cap = try syscall(.self_get_extra, .{
        idx,
    }, .{
        &val,
    });

    return .{ .val = val, .is_cap = is_cap != 0 };
}

pub const Signal = extern struct {
    ip: usize,
    sp: usize,
    target_addr: usize,
    caused_by: abi.sys.FaultCause,
    signal: enum(u8) {
        sigkill = 9,
        segv = 11,
        sigterm = 15,
        _,
    },

    _0: u16 = 0,
    _1: u32 = 0,
};

pub fn selfGetSignal() Error!Signal {
    // FIXME: this call can fail with Error.Retry

    var sig: Signal = undefined;
    _ = try syscall(.self_get_signal, .{@intFromPtr(&sig)}, .{});
    return sig;
}

//

pub fn syscall(id: Id, input: anytype, output: anytype) Error!usize {
    const Input = @TypeOf(input);
    const Output = @TypeOf(output);

    const ic = @typeInfo(Input).@"struct".fields.len;
    const oc = @typeInfo(Output).@"struct".fields.len;

    var in: [ic]usize = undefined;
    var out: [oc]usize = undefined;

    inline for (@typeInfo(Input).@"struct".fields, 0..) |field, i| {
        in[i] = @field(input, field.name);
    }

    const res = @import("syscall").invokeSyscall(
        ic,
        oc,
        @intFromEnum(id),
        &in,
        &out,
    );

    inline for (@typeInfo(Output).@"struct".fields, 0..) |field, i| {
        std.debug.assert(@typeInfo(field.type) == .pointer);
        @field(output, field.name).* = out[i];
    }

    return decode(res);
}
