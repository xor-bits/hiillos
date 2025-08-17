const std = @import("std");
const abi = @import("abi");

const addr = @import("addr.zig");
const arch = @import("arch.zig");
const pmem = @import("pmem.zig");
const proc = @import("proc.zig");

const caps_ipc = @import("caps/ipc.zig");
const caps_thread = @import("caps/thread.zig");
const caps_proc = @import("caps/proc.zig");
const caps_vmem = @import("caps/vmem.zig");
const caps_frame = @import("caps/frame.zig");
const caps_mapping = @import("caps/mapping.zig");
const caps_x86 = @import("caps/x86.zig");

const conf = abi.conf;
const log = std.log.scoped(.caps);
const Error = abi.sys.Error;
const Rights = abi.sys.Rights;
const RefCnt = abi.epoch.RefCnt;

//

pub const Thread = caps_thread.Thread;
pub const Process = caps_proc.Process;
pub const Frame = caps_frame.Frame;
pub const TlbShootdown = caps_frame.TlbShootdown;
pub const Vmem = caps_vmem.Vmem;
pub const Mapping = caps_mapping.Mapping;
pub const Receiver = caps_ipc.Receiver;
pub const Reply = caps_ipc.Reply;
pub const Sender = caps_ipc.Sender;
pub const Notify = caps_ipc.Notify;
pub const X86IoPortAllocator = caps_x86.X86IoPortAllocator;
pub const X86IoPort = caps_x86.X86IoPort;
pub const X86IrqAllocator = caps_x86.X86IrqAllocator;
pub const X86Irq = caps_x86.X86Irq;

pub const HalVmem = caps_x86.Vmem;

//

pub fn init() !void {
    // initialize the global kernel address space
    try caps_x86.init();

    // initialize the dedupe lazyinit readonly zero page
    const page = pmem.allocChunk(.@"4KiB") orelse return error.OutOfMemory;
    std.crypto.secureZero(u64, page.toHhdm().toPtr([*]volatile u64)[0..512]);
    readonly_zero_page.store(page.toParts().page, .release);

    debugType(CapabilitySlot);
    debugType(Capability);
    debugType(Generic);
    debugType(Process);
    debugType(Thread);
    debugType(Frame);
    debugType(Vmem);
    debugType(Mapping);
    debugType(Receiver);
    debugType(Reply);
    debugType(Sender);
    debugType(Notify);
    debugType(X86IoPortAllocator);
    debugType(X86IoPort);
    debugType(X86IrqAllocator);
    debugType(X86Irq);
}

pub fn incCount(ty: abi.ObjectType) void {
    if (!conf.LOG_OBJ_STATS) return;
    _ = obj_counts.getPtr(ty).fetchAdd(1, .monotonic);

    log.debug("objects: (new {})", .{ty});
    var it = obj_counts.iterator();
    while (it.next()) |e| {
        const v = e.value.load(.monotonic);
        log.debug(" - {}: {}", .{ e.key, v });
    }
}

pub fn decCount(ty: abi.ObjectType) void {
    if (!conf.LOG_OBJ_STATS) return;
    _ = obj_counts.getPtr(ty).fetchSub(1, .monotonic);
}

var obj_counts: std.EnumArray(abi.ObjectType, std.atomic.Value(usize)) = .initFill(.init(0));

//

pub const CapabilitySlot = packed struct {
    ptr: u56 = 0,
    type: abi.ObjectType = .null,
    rights: abi.sys.Rights = .{},

    pub fn init(cap: Capability) @This() {
        var self = @This(){};
        self.set(cap);
        return self;
    }

    pub fn initFree(next_free: u32) @This() {
        return @This(){ .ptr = next_free };
    }

    pub fn deinit(self: @This()) void {
        if (self.get()) |cap| {
            cap.deinit();
        }
    }

    /// returns the next free list entry
    pub fn nextFree(self: *const @This()) u32 {
        std.debug.assert(self.type == .null);
        return @intCast(self.ptr);
    }

    /// returns a Capability THAT IS NOT REF COUNTED
    pub fn getBorrow(self: *const @This()) ?Capability {
        if (self.type == .null) return null;

        return Capability{
            .ptr = @ptrFromInt(@as(u64, self.ptr) | 0xFF00_0000_0000_0000),
            .type = self.type,
            .rights = self.rights,
        };
    }

    /// returns an owned ref counted Capability
    pub fn get(self: *const @This()) ?Capability {
        const cap = self.getBorrow() orelse return null;
        cap.refcnt().inc();
        return cap;
    }

    /// returns an owned ref counted Capability, leaving the slot empty
    pub fn take(self: *@This()) ?Capability {
        const cap = self.getBorrow() orelse return null;
        self.set(.{});
        return cap;
    }

    /// takes an owned ref counted Capability
    pub fn set(self: *@This(), new: Capability) void {
        std.debug.assert((@intFromPtr(new.ptr) >> 56) == 0xFF);
        self.ptr = @truncate(@intFromPtr(new.ptr));
        self.type = new.type;
        self.rights = new.rights;
    }

    pub fn unwrap(self: @This()) ?Capability {
        var s = self;
        return s.take();
    }
};

pub const Capability = struct {
    ptr: *void = @ptrFromInt(0xFFFF_8000_0000_0000),
    type: abi.ObjectType = .null,
    rights: abi.sys.Rights = .{},

    pub fn init(obj: anytype, rights: ?Rights) @This() {
        const pointer = @typeInfo(@TypeOf(obj)).pointer;
        comptime std.debug.assert(!pointer.is_const);
        const UserHandle = pointer.child.UserHandle;

        return .{
            .ptr = @ptrCast(obj),
            .type = UserHandle.object_type,
            .rights = rights orelse UserHandle.default_rights,
        };
    }

    pub fn deinit(self: @This()) void {
        switch (self.type) {
            .frame => self.as(Frame).?.deinit(),
            .vmem => self.as(Vmem).?.deinit(),
            .process => self.as(Process).?.deinit(),
            .thread => self.as(Thread).?.deinit(),
            .receiver => self.as(Receiver).?.deinit(),
            .reply => self.as(Reply).?.deinit(),
            .sender => self.as(Sender).?.deinit(),
            .notify => self.as(Notify).?.deinit(),
            .x86_ioport_allocator => self.as(X86IoPortAllocator).?.deinit(),
            .x86_ioport => self.as(X86IoPort).?.deinit(),
            .x86_irq_allocator => self.as(X86IrqAllocator).?.deinit(),
            .x86_irq => self.as(X86Irq).?.deinit(),
            else => unreachable,
        }
    }

    pub fn as(self: @This(), comptime T: type) ?*T {
        const expected_type: abi.ObjectType = switch (T) {
            Frame => .frame,
            Vmem => .vmem,
            Process => .process,
            Thread => .thread,
            Receiver => .receiver,
            Reply => .reply,
            Sender => .sender,
            Notify => .notify,
            X86IoPortAllocator => .x86_ioport_allocator,
            X86IoPort => .x86_ioport,
            X86IrqAllocator => .x86_irq_allocator,
            X86Irq => .x86_irq,
            else => @compileError("invalid type"),
        };

        if (self.type != expected_type) {
            return null;
        }

        return @ptrCast(@alignCast(self.ptr));
    }

    pub fn refcnt(self: @This()) *abi.epoch.RefCnt {
        if (0 != @offsetOf(Frame, "refcnt") or
            0 != @offsetOf(Vmem, "refcnt") or
            0 != @offsetOf(Process, "refcnt") or
            0 != @offsetOf(Thread, "refcnt") or
            0 != @offsetOf(Receiver, "refcnt") or
            0 != @offsetOf(Reply, "refcnt") or
            0 != @offsetOf(Sender, "refcnt") or
            0 != @offsetOf(Notify, "refcnt") or
            0 != @offsetOf(X86IoPortAllocator, "refcnt") or
            0 != @offsetOf(X86IoPort, "refcnt") or
            0 != @offsetOf(X86IrqAllocator, "refcnt") or
            0 != @offsetOf(X86Irq, "refcnt"))
        {
            log.warn("slow kernel object refcnt access", .{});
            // FIXME: prevent reordering so that the offset would be same on all objects
            return switch (self.type) {
                .null => unreachable,
                .frame => &self.as(Frame).?.refcnt,
                .vmem => &self.as(Vmem).?.refcnt,
                .process => &self.as(Process).?.refcnt,
                .thread => &self.as(Thread).?.refcnt,
                .receiver => &self.as(Receiver).?.refcnt,
                .reply => &self.as(Reply).?.refcnt,
                .sender => &self.as(Sender).?.refcnt,
                .notify => &self.as(Notify).?.refcnt,
                .x86_ioport_allocator => &self.as(X86IoPortAllocator).?.refcnt,
                .x86_ioport => &self.as(X86IoPort).?.refcnt,
                .x86_irq_allocator => &self.as(X86IrqAllocator).?.refcnt,
                .x86_irq => &self.as(X86Irq).?.refcnt,
            };
        }

        return @ptrCast(@alignCast(self.ptr));
    }
};

pub const Generic = struct {
    refcnt: abi.epoch.RefCnt,
};

pub var slab_allocator = abi.mem.SlabAllocator.init(pmem.page_allocator);
/// written once by the BSP with .release before any other CPU runs
/// only read after that with .monotonic
pub var readonly_zero_page: std.atomic.Value(u32) = .init(0);

fn debugType(comptime T: type) void {
    std.log.debug("{s}: size={} align={}", .{ @typeName(T), @sizeOf(T), @alignOf(T) });
}

test "new VmemObject and FrameObject" {
    // disable temporarily while tests dont support complex control flow
    if (true) return;

    const vmem = try Vmem.init();
    const frame = try Frame.init(0x8000);
    _ = try vmem.map(frame.clone(), 1, addr.Virt.fromInt(0x1000), 6, .{
        .readable = true,
        .writable = true,
        .executable = true,
    }, .{});
    try vmem.start();
    vmem.switchTo();
    vmem.pageFault(
        .write,
        addr.Virt.fromInt(0x1000),
    ) catch unreachable;
    vmem.pageFault(
        .write,
        addr.Virt.fromInt(0x4000),
    ) catch unreachable;
    var thread: Thread = undefined;
    var trap: arch.TrapRegs = undefined;
    _ = try vmem.unmap(
        &trap,
        &thread,
        addr.Virt.fromInt(0x2000),
        1,
        true,
    );
    std.debug.assert(error.NotMapped == vmem.pageFault(
        .write,
        addr.Virt.fromInt(0x2000),
    ));
    vmem.pageFault(
        .write,
        addr.Virt.fromInt(0x5000),
    ) catch unreachable;
    const a = try frame.pageFault(4, true, null);
    const b = try frame.pageFault(4, false, null);
    std.debug.assert(a == b);
    std.debug.assert(a != 0);
    frame.deinit();
    vmem.deinit();
}

test "consecutive maps" {
    const vmem = try Vmem.init();

    const frame0 = try Frame.init(0x10000);
    const frame1 = try Frame.init(0x10000);

    _ = try vmem.map(
        frame0.clone(),
        0,
        addr.Virt.fromInt(0x10000),
        0x10,
        .{},
    );
    _ = try vmem.map(
        frame1.clone(),
        0,
        addr.Virt.fromInt(0x20000),
        0x10,
        .{},
    );

    try std.testing.expect(vmem.mappings.items[0].frame == frame0);
    try std.testing.expect(vmem.mappings.items[1].frame == frame1);

    frame0.deinit();
    frame1.deinit();

    vmem.deinit();
}
