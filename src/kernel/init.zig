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

const log = std.log.scoped(.init);
const Error = abi.sys.Error;
const Rights = abi.sys.Rights;

//

/// load and exec the root process
pub fn exec(a: args.Args) !void {
    log.info("creating root vmem", .{});
    const init_vmem = try caps.Vmem.init();
    try init_vmem.start();
    init_vmem.switchTo();

    log.info("creating root proc", .{});
    const init_proc = try caps.Process.init(init_vmem);

    log.info("creating root thread", .{});
    const init_thread = try caps.Thread.init(init_proc);
    init_thread.priority = 0;
    init_thread.trap.rip = abi.ROOT_EXE;

    log.info("creating root boot_info", .{});
    const boot_info = try caps.Frame.init(@sizeOf(abi.BootInfo));

    log.info("creating root x86_ioport_allocator", .{});
    const x86_ioport_allocator = try caps.X86IoPortAllocator.init();

    log.info("creating root x86_irq_allocator", .{});
    const x86_irq_allocator = try caps.X86IrqAllocator.init();

    var id: u32 = undefined;

    id = try init_proc.pushCapability(.init(init_vmem, null));
    std.debug.assert(id == abi.caps.ROOT_SELF_VMEM.cap);

    id = try init_proc.pushCapability(.init(init_thread, null));
    std.debug.assert(id == abi.caps.ROOT_SELF_THREAD.cap);

    id = try init_proc.pushCapability(.init(init_proc, null));
    std.debug.assert(id == abi.caps.ROOT_SELF_PROC.cap);

    id = try init_proc.pushCapability(.init(boot_info, null));
    std.debug.assert(id == abi.caps.ROOT_BOOT_INFO.cap);

    id = try init_proc.pushCapability(.init(x86_ioport_allocator, null));
    std.debug.assert(id == abi.caps.ROOT_X86_IOPORT_ALLOCATOR.cap);

    id = try init_proc.pushCapability(.init(x86_irq_allocator, null));
    std.debug.assert(id == abi.caps.ROOT_X86_IRQ_ALLOCATOR.cap);

    // the handles (init_thread, init_vmem, boot_info) moved, but they are still valid
    try mapRoot(init_thread, init_vmem, boot_info, a);

    proc.start(init_thread);
    proc.init();
}

const Result = struct {
    boot_info: caps.Ref(caps.Frame),
    framebuffer: ?caps.Ref(caps.Frame),
};

fn mapRoot(thread: *caps.Thread, vmem: *caps.Vmem, boot_info: *caps.Frame, a: args.Args) !void {
    const data_len = a.root_data.len + a.root_path.len + a.initfs_data.len + a.initfs_path.len;

    log.info("writing root boot_info", .{});
    try boot_info.initialWrite(0, @as([*]const u8, @ptrCast(&abi.BootInfo{
        .root_data = @ptrFromInt(abi.ROOT_EXE),
        .root_data_len = a.root_data.len,
        .root_path = @ptrFromInt(abi.ROOT_EXE + a.root_data.len),
        .root_path_len = a.root_path.len,
        .initfs_data = @ptrFromInt(abi.ROOT_EXE + a.root_data.len + a.root_path.len),
        .initfs_data_len = a.initfs_data.len,
        .initfs_path = @ptrFromInt(abi.ROOT_EXE + a.root_data.len + a.root_path.len + a.initfs_data.len),
        .initfs_path_len = a.initfs_path.len,
    }))[0..@sizeOf(abi.BootInfo)]);

    try hpet.bootInfoInstallHpet(boot_info, thread);
    try fb.bootInfoInstallFramebuffer(boot_info, thread);
    try acpi.bootInfoInstallMcfg(boot_info, thread);

    log.info("creating root frame", .{});
    const root_frame = try caps.Frame.init(data_len);

    var i: usize = 0;
    log.info("copying root data", .{});
    try root_frame.initialWrite(i, a.root_data);
    i += a.root_data.len;
    log.info("copying root path", .{});
    try root_frame.initialWrite(i, a.root_path);
    i += a.root_path.len;
    log.info("copying initfs data", .{});
    try root_frame.initialWrite(i, a.initfs_data);
    i += a.initfs_data.len;
    log.info("copying initfs path", .{});
    try root_frame.initialWrite(i, a.initfs_path);

    log.info("mapping root", .{});
    _ = try vmem.map(
        root_frame,
        0,
        addr.Virt.fromInt(abi.ROOT_EXE),
        @intCast(root_frame.pages.len),
        .{
            .fixed = true,
            .write = true,
            .exec = true,
        },
    );

    arch.flushTlb();

    log.info("root mapped and copied", .{});
}
