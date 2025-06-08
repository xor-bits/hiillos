const std = @import("std");

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
    /// get the `Frame` object's size in pages
    frame_get_size,
    /// read from a `Frame` capability
    frame_read,
    /// write into a `Frame` capability
    frame_write,

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

    /// identify which object type some capability is
    handle_identify,
    /// create another handle to the same object
    handle_duplicate,
    /// close a handle to some object, might or might not delete the object
    handle_close,

    /// give up the CPU for other tasks
    selfYield,
    /// stop the active thread
    selfStop,
    /// set an extra IPC register of this thread
    self_set_extra,
    /// get and zero an extra IPC register of this thread
    self_get_extra,
};

/// capability or mapping rights
pub const Rights = packed struct {
    readable: bool = true,
    writable: bool = false,
    executable: bool = false,
    user_accessible: bool = true,
    _: u4 = 0,

    pub fn intersection(self: Rights, other: Rights) Rights {
        return Rights{
            .readable = self.readable and other.readable,
            .writable = self.writable and other.writable,
            .executable = self.executable and other.executable,
            .user_accessible = self.user_accessible and other.user_accessible,
        };
    }

    pub fn asInt(self: Rights) u8 {
        return @as(u8, @bitCast(self));
    }

    pub fn fromInt(i: u8) Rights {
        return @as(Rights, @bitCast(i));
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
    _: u7 = 0,
    // global: bool = false,
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
    EntryNotPresent,
    EntryIsHuge,
    NotStopped,
    IsStopped,
    NoVmem,
    ThreadSafety,
    AlreadyMapped,
    NotMapped,
    MappingOverlap,
    PermissionDenied,
    Internal,
    NoReplyTarget,
    NotifyAlreadySubscribed,
    IrqAlreadySubscribed,
    TooManyIrqs,
    OutOfBounds,
    NotFound,
    ReadFault,
    WriteFault,
    ExecFault,
    NullHandle,
    BadHandle,

    UnknownError,
};

/// FIXME: should be Error!u32
pub fn encode(result: Error!usize) usize {
    const val = result catch |err| {
        return encodeError(err);
    };

    return val;
}

pub fn encodeVoid(result: Error!void) usize {
    result catch |err| {
        return encodeError(err);
    };
    return 0;
}

fn encodeError(err: Error) usize {
    return @bitCast(-@as(isize, switch (err) {
        Error.Unimplemented => 1,
        Error.InvalidAddress => 2,
        Error.InvalidFlags => 3,
        Error.InvalidType => 4,
        Error.InvalidArgument => 5,
        Error.InvalidCapability => 6,
        Error.InvalidSyscall => 7,
        Error.OutOfMemory => 8,
        Error.OutOfVirtualMemory => 9,
        Error.EntryNotPresent => 10,
        Error.EntryIsHuge => 11,
        Error.NotStopped => 12,
        Error.IsStopped => 13,
        Error.NoVmem => 14,
        Error.ThreadSafety => 15,
        Error.AlreadyMapped => 16,
        Error.NotMapped => 17,
        Error.MappingOverlap => 18,
        Error.PermissionDenied => 19,
        Error.Internal => 20,
        Error.NoReplyTarget => 21,
        Error.NotifyAlreadySubscribed => 22,
        Error.IrqAlreadySubscribed => 23,
        Error.TooManyIrqs => 24,
        Error.OutOfBounds => 25,
        Error.NotFound => 26,
        Error.ReadFault => 27,
        Error.WriteFault => 28,
        Error.ExecFault => 29,
        Error.NullHandle => 30,
        Error.BadHandle => 31,

        Error.UnknownError => std.debug.panic("unknown error shouldn't be encoded", .{}),
    }));
}

pub fn decode(v: usize) Error!usize {
    const v_isize: isize = @bitCast(v);
    const err = -v_isize;

    return switch (err) {
        std.math.minInt(isize)...0 => v,
        1 => Error.Unimplemented,
        2 => Error.InvalidAddress,
        3 => Error.InvalidFlags,
        4 => Error.InvalidType,
        5 => Error.InvalidArgument,
        6 => Error.InvalidCapability,
        7 => Error.InvalidSyscall,
        8 => Error.OutOfMemory,
        9 => Error.OutOfVirtualMemory,
        10 => Error.EntryNotPresent,
        11 => Error.EntryIsHuge,
        12 => Error.NotStopped,
        13 => Error.IsStopped,
        14 => Error.NoVmem,
        15 => Error.ThreadSafety,
        16 => Error.AlreadyMapped,
        17 => Error.NotMapped,
        18 => Error.MappingOverlap,
        19 => Error.PermissionDenied,
        20 => Error.Internal,
        21 => Error.NoReplyTarget,
        22 => Error.NotifyAlreadySubscribed,
        23 => Error.IrqAlreadySubscribed,
        24 => Error.TooManyIrqs,
        25 => Error.OutOfBounds,
        26 => Error.NotFound,
        27 => Error.ReadFault,
        28 => Error.WriteFault,
        29 => Error.ExecFault,
        30 => Error.NullHandle,
        31 => Error.BadHandle,

        else => return Error.UnknownError,
    };
}

pub fn decodeVoid(v: usize) Error!void {
    _ = try decode(v);
}

/// x86_64 thread registers
pub const ThreadRegs = extern struct {
    _r15: u64 = 0,
    _r14: u64 = 0,
    _r13: u64 = 0,
    _r12: u64 = 0,
    // RFlags, inaccessible to user-space (it is ignored on write and set to 0 on read)
    _r11: u64 = 0,
    /// r10
    arg5: u64 = 0,
    /// r9
    arg4: u64 = 0,
    /// r8
    arg3: u64 = 0,
    _rbp: u64 = 0,
    /// rsi
    arg1: u64 = 0,
    /// rdi
    arg0: u64 = 0,
    /// rdx
    arg2: u64 = 0,
    /// rcx
    user_instr_ptr: u64 = 0,
    _rbx: u64 = 0,
    /// rax = 0, also the return register
    syscall_id: u64 = 0,
    /// rsp
    user_stack_ptr: u64 = 0,
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

comptime {
    std.debug.assert(@sizeOf(Message) == @sizeOf([6]usize));
}

// SYSCALLS

pub fn log(s: []const u8) void {
    _ = syscall(.log, .{ @intFromPtr(s.ptr), s.len }) catch unreachable;
}

pub fn kernelPanic() noreturn {
    if (!abi.conf.KERNEL_PANIC_SYSCALL) @compileError("debug kernel panics not enabled");
    _ = syscall(.kernel_panic, .{}) catch {};
    unreachable;
}

pub fn frameCreate(size_bytes: usize) Error!u32 {
    return @intCast(try syscall(.frame_create, .{size_bytes}));
}

pub fn frameGetSize(frame: u32) Error!usize {
    return try syscall(.frame_get_size, .{frame}) * 0x1000;
}

pub fn frameRead(frame: u32, offset_byte: usize, dst: []u8) Error!void {
    _ = try syscall(.frame_read, .{ frame, offset_byte, @intFromPtr(dst.ptr), dst.len });
}

pub fn frameWrite(frame: u32, offset_byte: usize, src: []const u8) Error!void {
    _ = try syscall(.frame_write, .{ frame, offset_byte, @intFromPtr(src.ptr), src.len });
}

pub fn vmemCreate() Error!u32 {
    return @intCast(try syscall(.vmem_create, .{}));
}

pub fn vmemSelf() Error!u32 {
    return @intCast(try syscall(.vmem_self, .{}));
}

pub fn packRightsFlags(rights: Rights, flags: MapFlags) u24 {
    const val: packed struct { r: Rights, f: MapFlags } = .{ .r = rights, .f = flags };
    return @bitCast(val);
}

pub fn unpackRightsFlags(v: u24) struct { Rights, MapFlags } {
    const val: packed struct { r: Rights, f: MapFlags } = @bitCast(v);
    return .{ val.r, val.f };
}

/// if length is zero, the rest of the frame is mapped
pub fn vmemMap(
    vmem: u32,
    frame: u32,
    frame_offset: usize,
    vaddr: usize,
    length: usize,
    rights: Rights,
    flags: MapFlags,
) Error!usize {
    return try syscall(.vmem_map, .{
        vmem, frame, frame_offset, vaddr, length, packRightsFlags(rights, flags),
    });
}

pub fn vmemUnmap(vmem: u32, vaddr: usize, length: usize) Error!void {
    _ = try syscall(.vmem_unmap, .{
        vmem, vaddr, length,
    });
}

pub fn vmemRead(vmem: u32, vaddr: usize, dst: []u8) Error!void {
    _ = try syscall(.vmem_read, .{ vmem, vaddr, @intFromPtr(dst.ptr), dst.len });
}

pub fn vmemWrite(vmem: u32, vaddr: usize, src: []const u8) Error!void {
    _ = try syscall(.vmem_write, .{ vmem, vaddr, @intFromPtr(src.ptr), src.len });
}

pub fn procCreate(vmem: u32) Error!u32 {
    return @intCast(try syscall(.proc_create, .{vmem}));
}

pub fn procSelf() Error!u32 {
    return @intCast(try syscall(.proc_self, .{}));
}

pub fn procGiveCap(proc: u32, cap: u32) Error!u32 {
    return @intCast(try syscall(.proc_give_cap, .{ proc, cap }));
}

pub fn threadCreate(proc: u32) Error!u32 {
    return @intCast(try syscall(.thread_create, .{proc}));
}

pub fn threadSelf() Error!u32 {
    return @intCast(try syscall(.thread_self, .{}));
}

pub fn threadReadRegs(thread: u32, dst: *ThreadRegs) Error!void {
    _ = try syscall(.thread_read_regs, .{
        thread,
        @intFromPtr(dst),
    });
}

pub fn threadWriteRegs(thread: u32, dst: *const ThreadRegs) Error!void {
    _ = try syscall(.thread_write_regs, .{
        thread,
        @intFromPtr(dst),
    });
}

pub fn threadStart(thread: u32) Error!void {
    _ = try syscall(.thread_start, .{
        thread,
    });
}

pub fn threadStop(thread: u32) Error!void {
    _ = try syscall(.thread_stop, .{
        thread,
    });
}

pub fn threadSetPrio(thread: u32, prio: u2) Error!void {
    _ = try syscall(.thread_set_prio, .{
        thread,
        prio,
    });
}

pub fn receiverCreate() Error!u32 {
    return @intCast(try syscall(.receiver_create, .{}));
}

pub fn receiverRecv(recv: u32) Error!Message {
    var arg0: usize = undefined; // arrays dont work on outputs for whatever reason
    var arg1: usize = undefined;
    var arg2: usize = undefined;
    var arg3: usize = undefined;
    var arg4: usize = undefined;
    var arg5: usize = undefined;

    const res = asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
          [arg0out] "={rdi}" (arg0),
          [arg1out] "={rsi}" (arg1),
          [arg2out] "={rdx}" (arg2),
          [arg3out] "={r8}" (arg3),
          [arg4out] "={r9}" (arg4),
          [arg5out] "={r10}" (arg5),
        : [id] "{rax}" (@intFromEnum(Id.receiver_recv)),
          [arg0in] "{rdi}" (recv),
        : "rcx", "r11" // rcx becomes rip and r11 becomes rflags
    );

    _ = try decode(res);

    return @bitCast([_]usize{ arg0, arg1, arg2, arg3, arg4, arg5 });
}

pub fn receiverReply(recv: u32, msg: Message) Error!void {
    var _msg = msg;
    _msg.cap_or_stamp = recv;
    const msg_regs = @as([6]usize, @bitCast(_msg));

    const arg0: usize = msg_regs[0]; // arrays dont work on outputs for whatever reason
    const arg1: usize = msg_regs[1];
    const arg2: usize = msg_regs[2];
    const arg3: usize = msg_regs[3];
    const arg4: usize = msg_regs[4];
    const arg5: usize = msg_regs[5];

    const res = asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [id] "{rax}" (@intFromEnum(Id.receiver_reply)),
          [arg0in] "{rdi}" (arg0),
          [arg1in] "{rsi}" (arg1),
          [arg2in] "{rdx}" (arg2),
          [arg3in] "{r8}" (arg3),
          [arg4in] "{r9}" (arg4),
          [arg5in] "{r10}" (arg5),
        : "rcx", "r11" // rcx becomes rip and r11 becomes rflags
    );

    _ = try decode(res);
}

pub fn receiverReplyRecv(recv: u32, msg: Message) Error!Message {
    var _msg = msg;
    _msg.cap_or_stamp = recv;
    const msg_regs = @as([6]usize, @bitCast(_msg));

    var arg0: usize = msg_regs[0]; // arrays dont work on outputs for whatever reason
    var arg1: usize = msg_regs[1];
    var arg2: usize = msg_regs[2];
    var arg3: usize = msg_regs[3];
    var arg4: usize = msg_regs[4];
    var arg5: usize = msg_regs[5];

    const res = asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
          [arg0out] "={rdi}" (arg0),
          [arg1out] "={rsi}" (arg1),
          [arg2out] "={rdx}" (arg2),
          [arg3out] "={r8}" (arg3),
          [arg4out] "={r9}" (arg4),
          [arg5out] "={r10}" (arg5),
        : [id] "{rax}" (@intFromEnum(Id.receiver_reply_recv)),
          [arg0in] "{rdi}" (arg0),
          [arg1in] "{rsi}" (arg1),
          [arg2in] "{rdx}" (arg2),
          [arg3in] "{r8}" (arg3),
          [arg4in] "{r9}" (arg4),
          [arg5in] "{r10}" (arg5),
        : "rcx", "r11" // rcx becomes rip and r11 becomes rflags
    );

    _ = try decode(res);

    return @bitCast([_]usize{ arg0, arg1, arg2, arg3, arg4, arg5 });
}

pub fn replyCreate() Error!u32 {
    return @intCast(try syscall(.reply_create, .{}));
}

pub fn replyReply(reply: u32, msg: Message) Error!void {
    var _msg = msg;
    _msg.cap_or_stamp = reply;
    const msg_regs = @as([6]usize, @bitCast(_msg));

    _ = try syscall(.reply_reply, .{
        msg_regs[0],
        msg_regs[1],
        msg_regs[2],
        msg_regs[3],
        msg_regs[4],
        msg_regs[5],
    });
}

pub fn senderCreate(recv: u32, stamp: u32) Error!u32 {
    return @intCast(try syscall(.sender_create, .{ recv, stamp }));
}

pub fn senderCall(recv: u32, msg: Message) Error!Message {
    var _msg = msg;
    _msg.cap_or_stamp = recv;
    const msg_regs = @as([6]usize, @bitCast(_msg));

    var arg0: usize = msg_regs[0]; // arrays dont work on outputs for whatever reason
    var arg1: usize = msg_regs[1];
    var arg2: usize = msg_regs[2];
    var arg3: usize = msg_regs[3];
    var arg4: usize = msg_regs[4];
    var arg5: usize = msg_regs[5];

    const res = asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
          [arg0out] "={rdi}" (arg0),
          [arg1out] "={rsi}" (arg1),
          [arg2out] "={rdx}" (arg2),
          [arg3out] "={r8}" (arg3),
          [arg4out] "={r9}" (arg4),
          [arg5out] "={r10}" (arg5),
        : [id] "{rax}" (@intFromEnum(Id.sender_call)),
          [arg0in] "{rdi}" (arg0),
          [arg1in] "{rsi}" (arg1),
          [arg2in] "{rdx}" (arg2),
          [arg3in] "{r8}" (arg3),
          [arg4in] "{r9}" (arg4),
          [arg5in] "{r10}" (arg5),
        : "rcx", "r11" // rcx becomes rip and r11 becomes rflags
    );

    _ = try decode(res);

    return @bitCast([_]usize{ arg0, arg1, arg2, arg3, arg4, arg5 });
}

pub fn notifyCreate() Error!u32 {
    return @intCast(try syscall(.notify_create, .{}));
}

pub fn notifyWait(notify: u32) Error!void {
    _ = try syscall(.notify_wait, .{notify});
}

pub fn notifyPoll(notify: u32) Error!bool {
    return try syscall(.notify_wait, .{notify}) != 0;
}

pub fn notifyNotify(notify: u32) Error!bool {
    return try syscall(.notify_notify, .{notify}) != 0;
}

pub fn x86IoPortCreate(x86_ioport_allocator: u32, port: u16) Error!u32 {
    return @intCast(try syscall(.x86_ioport_create, .{ x86_ioport_allocator, port }));
}

pub fn x86IoPortInb(x86_ioport: u32) Error!u8 {
    return @intCast(try syscall(.x86_ioport_inb, .{x86_ioport}));
}

pub fn x86IoPortOutb(x86_ioport: u32, byte: u8) Error!void {
    _ = try syscall(.x86_ioport_outb, .{ x86_ioport, byte });
}

pub fn x86IrqCreate(x86_irq_allocator: u32, irq: u8) Error!u32 {
    return @intCast(try syscall(.x86_irq_create, .{ x86_irq_allocator, irq }));
}

pub fn x86IrqSubscribe(x86_irq: u32) Error!u32 {
    return @intCast(try syscall(.x86_irq_subscribe, .{x86_irq}));
}

pub fn handleIdentify(cap: u32) abi.ObjectType {
    return std.meta.intToEnum(
        abi.ObjectType,
        syscall(.handle_identify, .{cap}) catch unreachable,
    ) catch .null;
}

pub fn handleDuplicate(cap: u32) Error!u32 {
    return @intCast(try syscall(.handle_duplicate, .{cap}));
}

pub fn handleClose(cap: u32) void {
    _ = syscall(.handle_close, .{cap}) catch unreachable;
}

pub fn selfYield() void {
    _ = syscall(.selfYield, .{}) catch unreachable;
}

pub fn selfStop() noreturn {
    _ = syscall(.selfStop, .{}) catch {};
    asm volatile ("mov 0, %rax"); // read from nullptr to kill the process for sure
    unreachable;
}

pub fn selfSetExtra(idx: u7, val: u64, is_cap: bool) Error!void {
    const res = asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [id] "{rax}" (@intFromEnum(Id.self_set_extra)),
          [arg0in] "{rdi}" (idx),
          [arg1in] "{rsi}" (val),
          [arg2in] "{rdx}" (@intFromBool(is_cap)),
        : "rcx", "r11" // rcx becomes rip and r11 becomes rflags
    );

    _ = try decode(res);
}

pub fn selfGetExtra(idx: u7) Error!struct { val: u64, is_cap: bool } {
    var val: u64 = undefined;
    const res = asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
          [arg0out] "={rdi}" (val),
        : [id] "{rax}" (@intFromEnum(Id.self_get_extra)),
          [arg0in] "{rdi}" (idx),
        : "rcx", "r11" // rcx becomes rip and r11 becomes rflags
    );

    const is_cap = try decode(res);

    return .{ .val = val, .is_cap = is_cap != 0 };
}

//

pub fn syscall(id: Id, args: anytype) Error!usize {
    const ArgsType = @TypeOf(args);
    const args_type_info = @typeInfo(ArgsType);
    if (args_type_info != .@"struct" or !args_type_info.@"struct".is_tuple) {
        @compileError("expected tuple argument, found " ++ @typeName(ArgsType));
    }

    const fields = args_type_info.@"struct".fields;

    const syscall_id = @intFromEnum(id);
    const result: usize = switch (fields.len) {
        0 => syscall0(
            syscall_id,
        ),
        1 => syscall1(
            syscall_id,
            @field(args, fields[0].name),
        ),
        2 => syscall2(
            syscall_id,
            @field(args, fields[0].name),
            @field(args, fields[1].name),
        ),
        3 => syscall3(
            syscall_id,
            @field(args, fields[0].name),
            @field(args, fields[1].name),
            @field(args, fields[2].name),
        ),
        4 => syscall4(
            syscall_id,
            @field(args, fields[0].name),
            @field(args, fields[1].name),
            @field(args, fields[2].name),
            @field(args, fields[3].name),
        ),
        5 => syscall5(
            syscall_id,
            @field(args, fields[0].name),
            @field(args, fields[1].name),
            @field(args, fields[2].name),
            @field(args, fields[3].name),
            @field(args, fields[4].name),
        ),
        6 => syscall6(
            syscall_id,
            @field(args, fields[0].name),
            @field(args, fields[1].name),
            @field(args, fields[2].name),
            @field(args, fields[3].name),
            @field(args, fields[4].name),
            @field(args, fields[5].name),
        ),
        else => @compileError("expected 6 or less syscall arguments, found " ++ fields.len),
    };

    return try decode(result);
}

// TODO: move intFromEnum to here
pub fn syscall0(id: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [id] "{rax}" (id),
        : "rcx", "r11" // rcx becomes rip and r11 becomes rflags
    );
}

pub fn syscall1(id: usize, arg1: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [id] "{rax}" (id),
          [arg1] "{rdi}" (arg1),
        : "rcx", "r11" // rcx becomes rip and r11 becomes rflags
    );
}

pub fn syscall2(id: usize, arg1: usize, arg2: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [id] "{rax}" (id),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
        : "rcx", "r11" // rcx becomes rip and r11 becomes rflags
    );
}

pub fn syscall3(id: usize, arg1: usize, arg2: usize, arg3: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [id] "{rax}" (id),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
          [arg3] "{rdx}" (arg3),
        : "rcx", "r11" // rcx becomes rip and r11 becomes rflags
    );
}

pub fn syscall4(id: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [id] "{rax}" (id),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
          [arg3] "{rdx}" (arg3),
          [arg4] "{r8}" (arg4),
        : "rcx", "r11" // rcx becomes rip and r11 becomes rflags
    );
}

pub fn syscall5(id: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [id] "{rax}" (id),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
          [arg3] "{rdx}" (arg3),
          [arg4] "{r8}" (arg4),
          [arg5] "{r9}" (arg5),
        : "rcx", "r11" // rcx becomes rip and r11 becomes rflags
    );
}

pub fn syscall6(id: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize, arg6: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [id] "{rax}" (id),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
          [arg3] "{rdx}" (arg3),
          [arg4] "{r8}" (arg4),
          [arg5] "{r9}" (arg5),
          [arg6] "{r10}" (arg6),
        : "rcx", "r11" // rcx becomes rip and r11 becomes rflags
    );
}

pub fn syscall1rw(id: usize, args: [1]usize) struct { usize, [1]usize } {
    var arg0: usize = undefined; // arrays dont work on outputs for whatever reason

    const res = asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
          [arg0out] "={rdi}" (arg0),
        : [id] "{rax}" (id),
          [arg0in] "{rdi}" (args[0]),
        : "rcx", "r11" // rcx becomes rip and r11 becomes rflags
    );

    return .{
        res,
        .{arg0},
    };
}

pub fn syscall6rw(id: usize, args: [6]usize) struct { usize, [6]usize } {
    var arg0: usize = undefined; // arrays dont work on outputs for whatever reason
    var arg1: usize = undefined;
    var arg2: usize = undefined;
    var arg3: usize = undefined;
    var arg4: usize = undefined;
    var arg5: usize = undefined;

    const res = asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
          [arg0out] "={rdi}" (arg0),
          [arg1out] "={rsi}" (arg1),
          [arg2out] "={rdx}" (arg2),
          [arg3out] "={r8}" (arg3),
          [arg4out] "={r9}" (arg4),
          [arg5out] "={r10}" (arg5),
        : [id] "{rax}" (id),
          [arg0in] "{rdi}" (args[0]),
          [arg1in] "{rsi}" (args[1]),
          [arg2in] "{rdx}" (args[2]),
          [arg3in] "{r8}" (args[3]),
          [arg4in] "{r9}" (args[4]),
          [arg5in] "{r10}" (args[5]),
        : "rcx", "r11" // rcx becomes rip and r11 becomes rflags
    );

    return .{
        res,
        .{ arg0, arg1, arg2, arg3, arg4, arg5 },
    };
}
