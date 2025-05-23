const std = @import("std");
const abi = @import("abi");
const limine = @import("limine");

const acpi = @import("acpi.zig");
const addr = @import("addr.zig");
const arch = @import("arch.zig");
const args = @import("args.zig");
const caps = @import("caps.zig");
const fb = @import("fb.zig");
const hpet = @import("hpet.zig");
const pmem = @import("pmem.zig");
const proc = @import("proc.zig");
const util = @import("util.zig");

const log = std.log.scoped(.init);
const Error = abi.sys.Error;
const volat = util.volat;

//

/// load and exec the root process
pub fn exec(a: args.Args) !void {
    const vmem = try caps.Ref(caps.Vmem).alloc(null);

    (arch.Cr3{
        .pml4_phys_base = vmem.paddr.toParts().page,
    }).write();

    const init_thread = try caps.Ref(caps.Thread).alloc(null);
    init_thread.ptr().* = .{
        .trap = .{
            .user_instr_ptr = abi.ROOT_EXE,
        },
        .vmem = vmem,
        .priority = 0,
    };

    const init_memory = try caps.Ref(caps.Memory).alloc(null);

    const boot_info = try caps.Ref(caps.Frame).alloc(abi.ChunkSize.of(@sizeOf(abi.BootInfo)));

    const x86_ioport_allocator = caps.Ref(caps.X86IoPortAllocator){ .paddr = .fromInt(0) };

    const x86_irq_allocator = caps.Ref(caps.X86IrqAllocator){ .paddr = .fromInt(0) };

    var id: u32 = undefined;
    id = caps.pushCapability(vmem.object(init_thread.ptr()));
    std.debug.assert(id == abi.caps.ROOT_SELF_VMEM.cap);
    id = caps.pushCapability(init_thread.object(init_thread.ptr()));
    std.debug.assert(id == abi.caps.ROOT_SELF_THREAD.cap);
    id = caps.pushCapability(init_memory.object(init_thread.ptr()));
    std.debug.assert(id == abi.caps.ROOT_MEMORY.cap);
    id = caps.pushCapability(boot_info.object(init_thread.ptr()));
    std.debug.assert(id == abi.caps.ROOT_BOOT_INFO.cap);
    id = caps.pushCapability(x86_ioport_allocator.object(init_thread.ptr()));
    std.debug.assert(id == abi.caps.ROOT_X86_IOPORT_ALLOCATOR.cap);
    id = caps.pushCapability(x86_irq_allocator.object(init_thread.ptr()));
    std.debug.assert(id == abi.caps.ROOT_X86_IRQ_ALLOCATOR.cap);

    try mapRoot(init_thread.ptr(), vmem.ptr(), boot_info.ptr(), a);

    proc.start(init_thread.ptr());
    proc.init();
}

const Result = struct {
    boot_info: caps.Ref(caps.Frame),
    framebuffer: ?caps.Ref(caps.Frame),
};

fn mapRoot(thread: *caps.Thread, vmem: *caps.Vmem, boot_info: *caps.Frame, a: args.Args) !void {
    const data_len = a.root_data.len + a.root_path.len + a.initfs_data.len + a.initfs_path.len;

    const low = addr.Virt.fromInt(abi.ROOT_EXE);
    const high = addr.Virt.fromInt(abi.ROOT_EXE + data_len);

    const boot_info_ptr: *volatile abi.BootInfo = @ptrCast(boot_info);

    boot_info_ptr.* = .{
        .root_data = @ptrFromInt(abi.ROOT_EXE),
        .root_data_len = a.root_data.len,
        .root_path = @ptrFromInt(abi.ROOT_EXE + a.root_data.len),
        .root_path_len = a.root_path.len,
        .initfs_data = @ptrFromInt(abi.ROOT_EXE + a.root_data.len + a.root_path.len),
        .initfs_data_len = a.initfs_data.len,
        .initfs_path = @ptrFromInt(abi.ROOT_EXE + a.root_data.len + a.root_path.len + a.initfs_data.len),
        .initfs_path_len = a.initfs_path.len,
    };

    try fb.bootInfoInstallFramebuffer(boot_info_ptr, thread);

    try acpi.bootInfoInstallMcfg(boot_info_ptr, thread);

    const hpet_cap_id = caps.pushCapability(hpet.hpetFrame().object(thread));
    volat(&boot_info_ptr.hpet).* = .{ .cap = hpet_cap_id };

    log.info("root virtual memory size: 0x{x}", .{data_len});
    log.info("mapping root   [ 0x{x:0>16}..0x{x:0>16} ]", .{
        @intFromPtr(boot_info_ptr.root_data),
        @intFromPtr(boot_info_ptr.root_data) + boot_info_ptr.root_data_len,
    });
    log.info("mapping initfs [ 0x{x:0>16}..0x{x:0>16} ]", .{
        @intFromPtr(boot_info_ptr.initfs_data),
        @intFromPtr(boot_info_ptr.initfs_data) + boot_info_ptr.initfs_data_len,
    });
    log.info("root binary path: '{s}'", .{a.root_path});
    log.info("initfs path:      '{s}'", .{a.initfs_path});

    var current = low;
    while (current.raw < high.raw) : (current.raw += addr.Virt.fromParts(.{ .level1 = 1 }).raw) {
        // log.info("mapping level 1 entry", .{});

        try vmem.mapFrame(
            (try caps.Ref(caps.Frame).alloc(.@"4KiB")).paddr,
            current,
            .{
                .readable = true,
                .writable = true,
                .executable = true,
            },
            .{},
        );
    }

    arch.flushTlb();

    log.info("copying root data", .{});
    std.mem.copyForwards(
        u8,
        @as([]u8, @ptrCast(boot_info_ptr.rootData())),
        a.root_data,
    );
    log.info("copying root path", .{});
    std.mem.copyForwards(
        u8,
        @as([]u8, @ptrCast(boot_info_ptr.rootPath())),
        a.root_path,
    );
    log.info("copying initfs data", .{});
    std.mem.copyForwards(
        u8,
        @as([]u8, @ptrCast(boot_info_ptr.initfsData())),
        a.initfs_data,
    );
    log.info("copying initfs path", .{});
    std.mem.copyForwards(
        u8,
        @as([]u8, @ptrCast(boot_info_ptr.initfsPath())),
        a.initfs_path,
    );

    log.info("root mapped and copied", .{});
}
