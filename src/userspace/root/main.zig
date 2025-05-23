const std = @import("std");
const abi = @import("abi");

const initfsd = @import("initfsd.zig");

const log = std.log.scoped(.root);
const Error = abi.sys.Error;
const caps = abi.caps;

//

pub const std_options = abi.std_options;
pub const panic = abi.panic;
pub const name = "root";

//

/// elf loader temporary mapping location
pub const LOADER_TMP = 0x2000_0000_0000;
/// uncompressed initfs.tar location
pub const INITFS_TAR = 0x3000_0000_0000;
pub const FRAMEBUFFER = 0x4000_0000_0000;
pub const BACKBUFFER = 0x4100_0000_0000;
pub const FRAMEBUFFER_INFO = 0x4200_0000_0000;
pub const INITFS_TMP = 0x5000_0000_0000;
pub const INITFS_LIST = 0x5800_0000_0000;
pub const STACK_SIZE = 0x40000;
pub const STACK_TOP = 0x8000_0000_0000 - 0x2000;
pub const STACK_BOTTOM = STACK_TOP - STACK_SIZE;
pub const INITFS_STACK_TOP = STACK_BOTTOM - 0x2000;
pub const INITFS_STACK_BOTTOM = INITFS_STACK_TOP - STACK_SIZE;
pub const SPINNER_STACK_TOP = INITFS_STACK_BOTTOM - 0x2000;
pub const SPINNER_STACK_BOTTOM = SPINNER_STACK_TOP - STACK_SIZE;
/// boot info location
pub const BOOT_INFO = 0x8000_0000_0000 - 0x1000;

//

pub var self_memory_lock: abi.lock.YieldMutex = .new();
pub var self_vmem_lock: abi.lock.YieldMutex = .new();

//

pub fn main() !void {
    log.info("I am root", .{});

    try map(
        abi.caps.ROOT_BOOT_INFO,
        BOOT_INFO,
        .{ .writable = true },
        .{},
    );
    log.info("boot info mapped", .{});

    try initfsd.init();

    const recv = try alloc(abi.caps.Receiver);
    var system: System = .{ .recv = recv };

    const boot_info = @as(*const volatile abi.BootInfo, @ptrFromInt(BOOT_INFO)).*;
    system.devices.set(.hpet, .{
        .mmio_frame = boot_info.hpet,
        .info_frame = .{},
    });
    system.devices.set(.framebuffer, .{
        .mmio_frame = boot_info.framebuffer,
        .info_frame = boot_info.framebuffer_info,
    });
    system.devices.set(.mcfg, .{
        .mmio_frame = boot_info.mcfg,
        .info_frame = boot_info.mcfg_info,
    });

    const vm_sender = try recv.subscribe();

    try initfsd.wait();

    // virtual memory manager (system) (server)
    // maps new processes to memory and manages page faults,
    // heaps, lazy alloc, shared memory, swapping, etc.
    system.servers.getPtr(.vm).bin = try binBytes("/sbin/vm");

    // process manager (system) (server)
    // manages unix-like process stuff like permissions, cli args, etc.
    system.servers.getPtr(.pm).bin = try binBytes("/sbin/pm");

    // resource manager (system) (server)
    // manages ioports, irqs, device memory, etc. should also manage physical memory
    system.servers.getPtr(.rm).bin = try binBytes("/sbin/rm");

    // virtual filesystem (system) (server)
    // manages the main VFS tree, everything mounted into it and file descriptors
    system.servers.getPtr(.vfs).bin = try binBytes("/sbin/vfs");

    // timer (system) (server)
    // manages timer drivers and accepts sleep, sleepDeadline and timestamp calls
    system.servers.getPtr(.timer).bin = try binBytes("/sbin/timer");

    // input (system) (server)
    // manages input drivers
    system.servers.getPtr(.input).bin = try binBytes("/sbin/input");

    // FIXME: figure out a way to reclaim capabilities from crashed processes

    const vm = system.servers.getPtr(.vm);
    vm.thread = try execVm(vm.bin, vm_sender);
    vm.endpoint = vm_sender.cap;

    const server = Proto.init(&system, system.recv);

    log.info("root waiting for messages", .{});
    var msg: abi.sys.Message = undefined;
    try server.rx.recv(&msg);
    while (true) {
        server.ctx.dont_reply = false;
        server.process(&msg);

        if (!server.ctx.dont_reply)
            try server.rx.replyRecv(&msg)
        else
            try server.rx.recv(&msg);
    }
}

pub fn map(frame: caps.Frame, vaddr: usize, rights: abi.sys.Rights, flags: abi.sys.MapFlags) Error!void {
    self_vmem_lock.lock();
    defer self_vmem_lock.unlock();
    return caps.ROOT_SELF_VMEM.map(frame, vaddr, rights, flags);
}

pub fn unmap(frame: caps.Frame, vaddr: usize) Error!void {
    self_vmem_lock.lock();
    defer self_vmem_lock.unlock();
    return caps.ROOT_SELF_VMEM.unmap(frame, vaddr);
}

pub fn mapDevice(frame: caps.DeviceFrame, vaddr: usize, rights: abi.sys.Rights, flags: abi.sys.MapFlags) Error!void {
    self_vmem_lock.lock();
    defer self_vmem_lock.unlock();
    return caps.ROOT_SELF_VMEM.mapDevice(frame, vaddr, rights, flags);
}

pub fn unmapDevice(frame: caps.DeviceFrame, vaddr: usize) Error!void {
    self_vmem_lock.lock();
    defer self_vmem_lock.unlock();
    return caps.ROOT_SELF_VMEM.unmapDevice(frame, vaddr);
}

pub fn alloc(comptime T: type) Error!T {
    self_memory_lock.lock();
    defer self_memory_lock.unlock();
    return caps.ROOT_MEMORY.alloc(T);
}

pub fn allocSized(comptime T: type, size: abi.ChunkSize) Error!T {
    self_memory_lock.lock();
    defer self_memory_lock.unlock();
    return caps.ROOT_MEMORY.allocSized(T, size);
}

fn binBytes(path: []const u8) ![]const u8 {
    return initfsd.readFile(initfsd.openFile(path) orelse {
        log.err("missing critical system binary: '{s}'", .{path});
        return error.MissingSystem;
    });
}

const Proto = abi.RootProtocol.Server(.{
    .Context = *System,
    .scope = if (abi.conf.LOG_SERVERS) .root else null,
}, .{
    .memory = memoryHandler,
    .ioports = ioportsHandler,
    .irqs = irqsHandler,
    .device = deviceHandler,
    .serverReady = serverReadyHandler,
    .serverSender = serverSenderHandler,
    .initfs = initfsHandler,
    .newSender = newSenderHandler,
});

const Server = struct {
    /// server thread
    thread: caps.Thread = .{},
    /// server ELF binary
    bin: []const u8 = "",
    /// sender for communicating with the server
    sender: caps.Sender = .{},
    /// sender cap id, used for verifying that the sender is the system it says it is
    endpoint: u32 = 0,
    /// Reply objects to all callers waiting for a sender
    ready_waiters: std.BoundedArray(caps.Reply, 8) =
        std.BoundedArray(caps.Reply, 8).init(0) catch unreachable,
};

const System = struct {
    recv: caps.Receiver,
    dont_reply: bool = false,

    devices: std.EnumArray(abi.DeviceKind, abi.Device) = .initFill(.{}),

    servers: std.EnumArray(abi.ServerKind, Server) = .initFill(.{}),

    fn expectIsSystem(ctx: *System, sender: u32) Error!void {
        var it = ctx.servers.iterator();
        while (it.next()) |next| {
            if (next.value.endpoint == sender) return;
        }
        return Error.PermissionDenied;
    }
};

fn memoryHandler(ctx: *System, sender: u32, _: void) struct { Error!void, caps.Memory } {
    ctx.expectIsSystem(sender) catch |err| return .{ err, .{} };

    const memory = alloc(abi.caps.Memory) catch |err| {
        return .{ err, .{} };
    };

    return .{ {}, memory };
}

fn ioportsHandler(ctx: *System, sender: u32, _: void) struct { Error!void, caps.X86IoPortAllocator } {
    if (ctx.servers.get(.rm).endpoint != sender) {
        return .{ Error.PermissionDenied, .{} };
    }

    const ioports = caps.ROOT_X86_IOPORT_ALLOCATOR.clone() catch |err| {
        return .{ err, .{} };
    };

    return .{ {}, ioports };
}

fn irqsHandler(ctx: *System, sender: u32, _: void) struct { Error!void, caps.X86IrqAllocator } {
    if (ctx.servers.get(.rm).endpoint != sender) {
        return .{ Error.PermissionDenied, .{} };
    }

    const irqs = caps.ROOT_X86_IRQ_ALLOCATOR.clone() catch |err| {
        return .{ err, .{} };
    };

    return .{ {}, irqs };
}

fn deviceHandler(ctx: *System, sender: u32, req: struct { abi.DeviceKind }) struct { Error!void, caps.DeviceFrame, caps.Frame } {
    if (ctx.servers.get(.rm).endpoint != sender) {
        return .{ Error.PermissionDenied, .{}, .{} };
    }

    const kind = req.@"0";
    const device = ctx.devices.get(kind);
    ctx.devices.set(kind, .{});

    if (device.mmio_frame.cap == 0) return .{ Error.AlreadyMapped, .{}, .{} };

    return .{ {}, device.mmio_frame, device.info_frame };
}

fn serverReadyHandler(ctx: *System, sender: u32, req: struct { abi.ServerKind, caps.Sender }) struct { Error!void, void } {
    const kind = req.@"0";
    const server = ctx.servers.getPtr(kind);

    if (server.endpoint != sender) {
        return .{ Error.PermissionDenied, {} };
    }

    // FIXME: verify that it is a cap
    server.sender = req.@"1";

    const is_vm = kind == .vm;
    const is_requested = server.ready_waiters.len != 0;

    if (is_vm or is_requested) {
        ctx.dont_reply = true;
        Proto.reply(ctx.recv, .serverReady, .{ {}, {} }) catch |err| {
            log.info("failed to reply manually: {}", .{err});
        };
    }

    if (is_vm) {
        log.info("vm ready, exec all other servers", .{});

        var it = ctx.servers.iterator();
        while (it.next()) |next| {
            if (next.key == .vm) continue;

            next.value.endpoint = execWithVm(ctx, next.value.bin) catch |err| {
                log.err("failed to exec {}: {}", .{ next.key, err });
                return .{ {}, {} };
            };
        }
    }

    if (is_requested) {
        log.info("server ready, handling waiting {} requests", .{kind});

        for (server.ready_waiters.slice()) |caller| {
            const msg = serverSenderHandler(ctx, server.endpoint, .{kind});
            abi.RootProtocol.replyTo(caller, .serverSender, msg) catch |err| {
                log.info("failed to reply manually: {}", .{err});
            };
        }
        server.ready_waiters.clear();
    }

    return .{ {}, {} };
}

fn serverSenderHandler(ctx: *System, _: u32, req: struct { abi.ServerKind }) struct { Error!void, caps.Sender } {
    // ctx.expectIsSystem(sender) catch |err| return .{ err, .{} };

    const server = ctx.servers.getPtr(req.@"0");

    if (server.sender.cap == 0) {
        log.info("deferred serverSender call {}", .{req.@"0"});
        const caller = ctx.recv.saveCaller() catch |err| {
            log.err("failed to save caller: {}", .{err});
            return .{ err, .{} };
        };
        ctx.dont_reply = true;
        server.ready_waiters.append(caller) catch |err| {
            log.err("too many active requests for servers before it is up: {}", .{err});
            return .{ Error.Internal, .{} };
        };
        return .{ {}, .{} };
    }
    log.info("handling serverSender call {}", .{req.@"0"});

    var result: Error!struct { Error!void, caps.Sender } = undefined;
    switch (req.@"0") {
        .vm => result = abi.VmProtocol.Client().init(server.sender).call(.newSender, {}),
        .pm => result = abi.PmProtocol.Client().init(server.sender).call(.newSender, {}),
        .rm => result = abi.RmProtocol.Client().init(server.sender).call(.newSender, {}),
        .timer => result = abi.TimerProtocol.Client().init(server.sender).call(.newSender, {}),
        .input => result = abi.InputProtocol.Client().init(server.sender).call(.newSender, {}),
        .vfs => @panic("todo"),
    }

    const res: Error!void, const dupe_sender: caps.Sender = result catch |err| {
        log.err("failed to communicate with {}: {}", .{ req.@"0", err });
        return .{ err, .{} };
    };
    res catch |err| {
        log.err("failed to communicate with {}: {}", .{ req.@"0", err });
        return .{ err, .{} };
    };

    return .{ {}, dupe_sender };
}

fn initfsHandler(_: *System, _: u32, _: void) struct { Error!void, caps.Sender } {
    // even init is allowed

    const initfs_sender = initfsd.getSender() catch |err| {
        log.err("failed to communicate with vm: {}", .{err});
        return .{ err, .{} };
    };

    return .{ {}, initfs_sender };
}

fn newSenderHandler(ctx: *System, sender: u32, _: void) struct { Error!void, caps.Sender } {
    ctx.expectIsSystem(sender) catch |err| return .{ err, .{} };

    const root_sender = ctx.recv.subscribe() catch |err| {
        log.err("failed to subscribe: {}", .{err});
        return .{ err, .{} };
    };

    return .{ {}, root_sender };
}

/// returns the endpoint id of the server, used for verifying server identity
fn execWithVm(ctx: *System, bin: []const u8) !u32 {
    // send the file to vm server using shared memory IPC

    const frame = try allocSized(
        abi.caps.Frame,
        abi.ChunkSize.of(bin.len) orelse {
            log.err("binary too large", .{});
            return error.BinaryTooLarge;
        },
    );

    try map(
        frame,
        LOADER_TMP,
        .{ .writable = true },
        .{},
    );
    abi.util.copyForwardsVolatile(
        u8,
        @as([*]volatile u8, @ptrFromInt(LOADER_TMP))[0..bin.len],
        bin,
    );
    try unmap(
        frame,
        LOADER_TMP,
    );

    const vm_sender = abi.VmProtocol.Client().init(ctx.servers.get(.vm).sender);
    var res, const vmem_handle = try vm_sender.call(.newVmem, {});
    try res;

    const res1 = try vm_sender.call(.loadElf, .{
        vmem_handle,
        frame,
        0,
        bin.len,
    });
    _ = try res1.@"0";

    res, const thread = try vm_sender.call(.newThread, .{ vmem_handle, 0, 0 });
    try res;

    res, const vm_sender_dupe: caps.Sender = try vm_sender.call(.newSender, {});
    try res;

    res, _ = try vm_sender.call(.moveOwner, .{ vmem_handle, vm_sender_dupe.cap });
    try res;

    const sender = try ctx.recv.subscribe();

    try thread.setPrio(0);
    try thread.transferCap(sender.cap);
    try thread.transferCap(vm_sender_dupe.cap);
    var regs: abi.sys.ThreadRegs = undefined;
    try thread.readRegs(&regs);
    regs.arg0 = sender.cap; // set RDI to the root client (sender cap)
    regs.arg1 = vm_sender_dupe.cap; // set RSI to the vm server client (sender cap)
    regs.arg2 = vmem_handle; // set RDX to the server's own vmem handle
    try thread.writeRegs(&regs);
    try thread.start();

    return sender.cap;
}

fn execVm(elf_bytes: []const u8, sender: abi.caps.Sender) !caps.Thread {
    var elf = std.io.fixedBufferStream(elf_bytes);

    var crc: u32 = 0;
    for (elf_bytes) |b| {
        crc = @addWithOverflow(crc, @as(u32, b))[0];
    }
    log.info("xor crc of is {d}", .{crc});

    const header = try std.elf.Header.read(&elf);
    var program_headers = header.program_header_iterator(&elf);

    const new_vmem = try alloc(abi.caps.Vmem);

    var heap_bottom: usize = 0;

    // var frames: std.BoundedArray(u32, 1000) = .init(0);
    // frames.append(item: T);

    while (try program_headers.next()) |program_header| {
        if (program_header.p_type != std.elf.PT_LOAD) {
            continue;
        }

        if (program_header.p_memsz == 0) {
            continue;
        }

        const bytes: []const u8 = elf.buffer[program_header.p_offset..][0..program_header.p_filesz];

        const rights = abi.sys.Rights{
            .writable = program_header.p_flags & std.elf.PF_W != 0,
            .executable = program_header.p_flags & std.elf.PF_X != 0,
        };

        const segment_vaddr_bottom = std.mem.alignBackward(usize, program_header.p_vaddr, 0x1000);
        const segment_vaddr_top = std.mem.alignForward(usize, program_header.p_vaddr + program_header.p_memsz, 0x1000);
        const segment_data_bottom_offset = program_header.p_vaddr - segment_vaddr_bottom;
        // const data_vaddr_bottom = program_header.p_vaddr;
        // const data_vaddr_top = data_vaddr_bottom + program_header.p_filesz;
        // const zero_vaddr_bottom = std.mem.alignForward(usize, data_vaddr_top, 0x1000);
        // const zero_vaddr_top = segment_vaddr_top;

        heap_bottom = @max(heap_bottom, segment_vaddr_top + 0x1000);

        // log.info("flags: {}, segment_vaddr_bottom=0x{x} segment_vaddr_top=0x{x} data_vaddr_bottom=0x{x} data_vaddr_top=0x{x}", .{
        //     rights,
        //     segment_vaddr_bottom,
        //     segment_vaddr_top,
        //     data_vaddr_bottom,
        //     data_vaddr_top,
        // });

        // FIXME: potential alignment errors when segments are bigger than 2MiB,
        // because frame caps use huge and giant pages automatically

        const size = segment_vaddr_top - segment_vaddr_bottom;
        self_memory_lock.lock();
        defer self_memory_lock.unlock();
        const frames = try abi.util.allocVector(abi.caps.ROOT_MEMORY, size);

        self_vmem_lock.lock();
        defer self_vmem_lock.unlock();
        try abi.util.mapVector(
            &frames,
            abi.caps.ROOT_SELF_VMEM,
            LOADER_TMP,
            .{ .writable = true },
            .{},
        );

        // log.info("copying to [ 0x{x}..0x{x} ]", .{
        //     segment_vaddr_bottom + segment_data_bottom_offset,
        //     segment_vaddr_bottom + segment_data_bottom_offset + program_header.p_filesz,
        // });
        abi.util.copyForwardsVolatile(
            u8,
            @as([*]volatile u8, @ptrFromInt(LOADER_TMP + segment_data_bottom_offset))[0..program_header.p_filesz],
            bytes,
        );

        try abi.util.unmapVector(
            &frames,
            abi.caps.ROOT_SELF_VMEM,
            LOADER_TMP,
        );

        try abi.util.mapVector(
            &frames,
            new_vmem,
            segment_vaddr_bottom,
            rights,
            .{},
        );
    }

    while (true) {
        log.info("alloc + free 10_000 frames of size 4KiB", .{});

        for (0..10_000) |_| {
            const frame = try allocSized(caps.Frame, .@"4KiB");
            // log.info("frame cap_id={}", .{frame.cap});
            for (0..1_000) |_| {
                _ = try frame.subframe(0, .@"4KiB");
            }
            try frame.revoke();
        }
    }

    // map a stack
    // log.info("mapping a stack", .{});
    const stack = try allocSized(caps.Frame, .@"256KiB");
    try new_vmem.map(
        stack,
        0x7FFF_FFF0_0000,
        .{ .writable = true },
        .{},
    );
    // try new_vmem.map(
    //     stack_copy,
    //     0x7FFF_FFE0_0000,
    //     .{ .writable = true },
    //     .{},
    // );

    // map an initial heap
    // log.info("mapping a heap", .{});
    const heap = try allocSized(caps.Frame, .@"256KiB");
    try new_vmem.map(
        heap,
        heap_bottom,
        .{ .writable = true },
        .{},
    );

    // log.info("creating a new thread", .{});
    const new_thread: caps.Thread = try alloc(caps.Thread);

    try new_thread.setVmem(new_vmem);
    try new_thread.transferCap(new_vmem.cap);
    try new_thread.setPrio(0);
    try new_thread.writeRegs(&.{
        .arg0 = sender.cap, // set RDI to
        .arg2 = new_vmem.cap, // set RSI to the self Vmem cap
        .user_instr_ptr = header.entry,
        .user_stack_ptr = 0x7FFF_FFF4_0000 - 0x100,
    });
    try new_thread.transferCap(sender.cap);

    // log.info("ip=0x{x} sp=0x{x}", .{ header.entry, 0x7FFF_FFF4_0000 });

    log.info("everything ready, exec", .{});
    try new_thread.start();

    return new_thread;
}

pub extern var __stack_end: u8;
pub extern var __thread_stack_end: u8;

pub export fn _start() linksection(".text._start") callconv(.Naked) noreturn {
    asm volatile (
        \\ jmp zigMain
        :
        : [sp] "{rsp}" (&__stack_end),
    );
}

export fn zigMain() noreturn {
    // switch to a bigger stack (256KiB, because the initfs deflate takes up over 128KiB on its own)
    mapStack() catch |err| {
        std.debug.panic("not enough memory for a stack: {}", .{err});
    };

    asm volatile (
        \\ call zigMainRealstack
        :
        : [sp] "{rsp}" (STACK_TOP),
    );

    abi.sys.stop();
}

fn mapStack() !void {
    const frame = try allocSized(abi.caps.Frame, .@"256KiB");
    // log.info("256KiB stack frame allocated", .{});
    try map(
        frame,
        STACK_BOTTOM,
        .{ .writable = true },
        .{},
    );
    // log.info("stack mapping complete 0x{x}..0x{x}", .{ STACK_BOTTOM, STACK_TOP });
}

export fn zigMainRealstack() noreturn {
    main() catch |err| {
        std.debug.panic("{}", .{err});
    };
    abi.sys.stop();
}
