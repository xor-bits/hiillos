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
pub const Channel = caps_ipc.Channel;
pub const Receiver = caps_ipc.Receiver;
pub const Reply = caps_ipc.Reply;
pub const Sender = caps_ipc.Sender;
pub const Notify = caps_ipc.Notify;
pub const X86IoPortAllocator = caps_x86.X86IoPortAllocator;
// TODO: use IOPB in the TSS for this
pub const X86IoPort = caps_x86.X86IoPort;
pub const X86IrqAllocator = caps_x86.X86IrqAllocator;
pub const X86Irq = caps_x86.X86Irq;

pub const HalVmem = caps_x86.HalVmem;
pub const PcidLru = HalVmem.PcidLru;

//

pub fn init() !void {
    // initialize the global kernel address space
    try caps_x86.init();

    // initialize the dedupe lazyinit readonly zero page
    readonly_zero_page = pmem.allocChunk(.@"4KiB") orelse return error.OutOfMemory;

    inline for ([_]type{
        CapabilitySlot,     Process,
        Thread,             Frame,
        Vmem,               Mapping,
        Receiver,           Reply,
        Sender,             Notify,
        X86IoPortAllocator, X86IoPort,
        X86IrqAllocator,    X86Irq,
    }) |T| {
        debugType(T);
    }
}

pub fn incCount(ty: abi.ObjectType, init_args: anytype) void {
    if (conf.LOG_OBJ_CALLS)
        log.info("{t}.init {any}", .{ ty, init_args });
    if (conf.LOG_OBJ_STATS == .none) return;
    _ = obj_counts.getPtr(ty).fetchAdd(1, .monotonic);

    if (conf.LOG_OBJ_STATS == .each_init) {
        printCounts();
    }
}

pub fn decCount(ty: abi.ObjectType) void {
    if (conf.LOG_OBJ_CALLS)
        log.info("{t}.deinit", .{ty});
    if (conf.LOG_OBJ_STATS == .none) return;
    const old_count = obj_counts.getPtr(ty).fetchSub(1, .monotonic);
    std.debug.assert(old_count != 0);
}

pub fn printCounts() void {
    if (conf.LOG_OBJ_STATS == .none) return;
    log.debug("objects:", .{});
    var it = obj_counts.iterator();
    while (it.next()) |e| {
        const v = e.value.load(.monotonic);
        log.debug(" - {}: {}", .{ e.key, v });
    }
}

var obj_counts: std.EnumArray(abi.ObjectType, std.atomic.Value(usize)) = .initFill(.init(0));

//

pub const Object = struct {
    refcnt: abi.epoch.RefCnt = .{},
    type: abi.ObjectType,

    pub fn clone(
        self: *Object,
    ) void {
        self.refcnt.inc();
    }

    pub fn deinit(
        self: *Object,
    ) void {
        if (!self.refcnt.dec()) return;

        switch (self.type) {
            .null,
            .hal_vmem,
            .tlb_shootdown,
            => unreachable,

            inline else => |t| {
                self.downcast(typeOf(t)).deinitFull();
            },
        }
    }

    pub fn typeOf(comptime ty: abi.ObjectType) type {
        return switch (ty) {
            .frame => Frame,
            .vmem => Vmem,
            .process => Process,
            .thread => Thread,
            .receiver => Receiver,
            .reply => Reply,
            .sender => Sender,
            .notify => Notify,
            .x86_ioport_allocator => X86IoPortAllocator,
            .x86_ioport => X86IoPort,
            .x86_irq_allocator => X86IrqAllocator,
            .x86_irq => X86Irq,

            .null,
            .hal_vmem,
            .tlb_shootdown,
            => @compileError("invalid type " ++ @tagName(ty)),
        };
    }

    pub fn downcast(
        self: *@This(),
        comptime T: type,
    ) *T {
        std.debug.assert(T.UserHandle.object_type == self.type);
        return @alignCast(@fieldParentPtr("base", self));
    }
};

pub const CapabilitySlot = struct {
    object: ?*Object,
    rights: abi.sys.Rights,

    pub fn initUsed(
        base: *Object,
        rights: abi.sys.Rights,
    ) @This() {
        return .{
            .object = base,
            .rights = rights,
        };
    }

    pub fn initFree(
        next_free: u32,
    ) @This() {
        return .{
            .object = null,
            .rights = .decode(next_free),
        };
    }

    pub fn deinit(self: @This()) void {
        const obj = self.object orelse return;
        obj.deinit();
    }

    /// returns the next free list entry
    pub fn nextFree(self: *const @This()) u32 {
        std.debug.assert(self.object == null);
        return @intCast(self.rights.encode());
    }
};

// This would have been useful for tracking handle lifetimes
// without a runtime cost but
// https://codeberg.org/ziglang/zig/issues/32045 is a thing.
//
// pub fn Handle(comptime T: type) type {
//     return struct {
//         ptr: *T,
//         rights: abi.sys.Rights,
//         comptime state: enum(u32) { owned, borrowed, deinit },

//         pub fn deinit(
//             self: *@This(),
//         ) void {
//             switch (self.state) {
//                 .owned => {
//                     if (comptime T == Object) {
//                         self.ptr.deinit();
//                     } else {
//                         self.upcast().deinit();
//                     }
//                 },
//                 .borrowed => {},
//                 .deinit => unreachable,
//             }
//         }

//         pub fn downcast(
//             self: @This(),
//             comptime U: type,
//         ) void {
//             comptime std.debug.assert(T == Object);
//             const obj: *Object = self.ptr;
//             return .{
//                 .ref = obj.downcast(U),
//                 .rights = self.rights,
//                 .state = self.state,
//             };
//         }

//         pub fn upcast(self: @This()) Handle(Object) {
//             comptime std.debug.assert(T != Object);
//             return .{
//                 .ptr = &self.base,
//                 .rights = self.rights,
//                 .state = self.state,
//             };
//         }
//     };
// }

pub var slab_allocator = abi.mem.SlabAllocator.init(pmem.page_allocator);
pub var readonly_zero_page: addr.Phys = undefined;

fn debugType(comptime T: type) void {
    std.log.debug("{s}: size={} align={}", .{ @typeName(T), @sizeOf(T), @alignOf(T) });
}
