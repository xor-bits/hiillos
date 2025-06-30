const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;

//

pub const std_options = abi.std_options;
pub const panic = abi.panic;

const log = std.log.scoped(.pm);
const Error = abi.sys.Error;

//

pub export var manifest = abi.loader.Manifest.new(.{
    .name = "pm",
});

pub export var export_pm = abi.loader.Resource.new(.{
    .name = "hiillos.pm.ipc",
    .ty = .receiver,
});

pub export var import_vfs = abi.loader.Resource.new(.{
    .name = "hiillos.vfs.ipc",
    .ty = .sender,
});

pub export var import_hpet = abi.loader.Resource.new(.{
    .name = "hiillos.hpet.ipc",
    .ty = .sender,
});

pub export var import_ps2 = abi.loader.Resource.new(.{
    .name = "hiillos.ps2.ipc",
    .ty = .sender,
});

pub export var import_pci = abi.loader.Resource.new(.{
    .name = "hiillos.pci.ipc",
    .ty = .sender,
});

//

pub fn main() !void {
    log.info("hello from pm, export_pm={} import_vfs={}", .{
        export_pm.handle,
        import_vfs.handle,
    });

    if (abi.conf.IPC_BENCHMARK) {
        const sender = caps.Sender{ .cap = import_vfs.handle };
        while (true) {
            _ = try sender.call(.{ .arg0 = 5, .arg2 = 6 });
        }
    }

    var system: System = .{
        .recv = .{ .cap = export_pm.handle },
        .self_vmem = try caps.Vmem.self(),
    };
    defer system.self_vmem.close();

    // const init_elf = try open("initfs:///sbin/init");

    const vfs = abi.VfsProtocol.Client().init(.{ .cap = import_vfs.handle });
    const res: Error!void, const init_elf_frame: abi.caps.Frame = try vfs.call(.openFile1, .{
        ("initfs:///sbin/init" ++ .{0} ** 13).*,
        @bitCast(abi.fs.OpenOptions{
            .mode = .read_only,
            .file_policy = .use_existing,
            .dir_policy = .use_existing,
        }),
    });
    try res;

    const init_elf_size = try init_elf_frame.getSize();
    const init_elf_addr = try system.self_vmem.map(
        init_elf_frame,
        0,
        0,
        0,
        .{},
        .{},
    );

    var init_elf = try abi.loader.Elf.init(@as(
        [*]const u8,
        @ptrFromInt(init_elf_addr),
    )[0..init_elf_size]);

    // init (normal) (process)
    // all the critial system servers are running, so now "normal" Linux-like init can run
    // gets a Sender capability to access the initfs part of this root process
    // just runs normal processes according to the init configuration
    // launches stuff like the window manager and virtual TTYs
    log.info("exec init", .{});
    const init_pid = try system.exec(&init_elf, 0);
    std.debug.assert(init_pid == 1);

    const server = abi.PmProtocol.Server(.{
        .Context = *System,
        .scope = if (abi.conf.LOG_SERVERS) .vm else null,
    }, .{
        .execElf = execElfHandler,
    }).init(&system, system.recv);

    // inform the root that pm is ready
    log.debug("pm ready", .{});
    try server.run();
}

fn open(path: []const u8) Error!caps.Sender {
    const tmp_frame = try caps.Frame.create(path.len);
    defer tmp_frame.close();

    try tmp_frame.write(0, path);

    const vfs = abi.VfsProtocol.Client().init(.{ .cap = import_vfs.handle });
    const res, const handle = try vfs.call(.open, .{ tmp_frame, 0, path.len, @bitCast(abi.Vfs.OpenOptions{
        .mode = .read_only,
        .type = .file,
        .file_policy = .use_existing,
        .dir_policy = .use_existing,
    }) });
    try res;

    return handle;
}

pub const Process = struct {
    vmem: caps.Vmem,
    proc: caps.Process,
    thread: caps.Thread,
};

pub const System = struct {
    recv: caps.Receiver,
    self_vmem: caps.Vmem,

    processes: std.ArrayList(?Process) = .init(abi.mem.slab_allocator),
    // empty process ids into ↑
    free_slots: std.fifo.LinearFifo(u32, .Dynamic) = .init(abi.mem.slab_allocator),

    pub fn exec(
        system: *System,
        elf: *abi.loader.Elf,
        as_uid: u32,
    ) !u32 {
        const pid = try system.allocPid();
        std.debug.assert(pid != 0);
        errdefer system.freePid(pid) catch |err| {
            log.err("could not deallocate PID because another error occurred: {}", .{err});
        };

        const slot = &system.processes.items[pid - 1];
        std.debug.assert(slot.* == null);

        const vmem = try caps.Vmem.create();
        errdefer vmem.close();
        const proc = try caps.Process.create(vmem);
        errdefer proc.close();
        const thread = try caps.Thread.create(proc);
        errdefer thread.close();

        const entry = try elf.loadInto(system.self_vmem, vmem);
        try abi.loader.prepareSpawn(vmem, thread, entry);

        var id: u32 = 0;
        id = try proc.giveHandle(try caps.Sender.create(system.recv, pid));
        std.debug.assert(id == 1);
        id = try proc.giveHandle(try (caps.Sender{ .cap = import_hpet.handle }).clone());
        std.debug.assert(id == 2);
        id = try proc.giveHandle(try (caps.Sender{ .cap = import_ps2.handle }).clone());
        std.debug.assert(id == 3);

        const vfs = abi.VfsProtocol.Client().init(.{ .cap = import_vfs.handle });
        const res: Error!void, const vfs_ipc: caps.Sender = try vfs.call(.newSender, .{as_uid});
        try res;
        id = try proc.giveHandle(vfs_ipc);
        std.debug.assert(id == 4);

        try thread.start();

        slot.* = .{
            .vmem = vmem,
            .proc = proc,
            .thread = thread,
        };

        return pid;
    }

    pub fn allocPid(system: *@This()) !u32 {
        if (system.free_slots.readItem()) |pid| {
            return pid;
        } else {
            const pid = system.processes.items.len + 1;
            if (pid > std.math.maxInt(u32))
                return error.TooManyActiveProcesses;

            try system.processes.append(null);
            return @intCast(pid);
        }
    }

    pub fn freePid(system: *@This(), pid: u32) !void {
        try system.free_slots.writeItem(pid);
    }
};

fn execElfHandler(ctx: *System, sender: u32, req: struct { [32:0]u8 }) struct { Error!void, usize } {
    _ = ctx;
    _ = sender;
    _ = req;

    return .{ Error.PermissionDenied, 0 };
}

fn growHeapHandler(ctx: *System, sender: u32, req: struct { usize }) struct { Error!void, usize } {
    const by = req.@"0";
    for (ctx.processes[1..]) |proc| {
        const process = proc orelse continue;
        if (process.pm_endpoint != sender) continue;

        const res, const addr = ctx.vm_client.call(.mapAnon, .{
            process.vmem_handle,
            by,
            abi.sys.Rights{ .writable = true },
            abi.sys.MapFlags{},
        }) catch |err| {
            log.err("failed to grow heap: {}", .{err});
            return .{ Error.Internal, 0 };
        };
        res catch |err| {
            log.err("failed to grow heap: {}", .{err});
            return .{ Error.Internal, 0 };
        };

        return .{ {}, addr };
    }

    return .{ Error.PermissionDenied, 0 };
}

fn mapFrameHandler(
    ctx: *System,
    sender: u32,
    req: struct { caps.Frame, abi.sys.Rights, abi.sys.MapFlags },
) struct { Error!void, usize, caps.Frame } {
    const frame = req.@"0";
    const rights = req.@"1";
    const flags = req.@"2";

    // TODO: give each sender some id that the sender itself cannot change
    for (ctx.processes[1..]) |proc| {
        const process = proc orelse continue;
        if (process.pm_endpoint != sender) continue;

        const res, const addr, _ = ctx.vm_client.call(.mapFrame, .{
            process.vmem_handle,
            frame,
            rights,
            flags,
        }) catch |err| {
            log.err("failed to map a frame: {}", .{err});
            return .{ Error.Internal, 0, frame };
        };
        res catch |err| {
            log.err("failed to map a frame: {}", .{err});
            return .{ Error.Internal, 0, frame };
        };

        return .{ {}, addr, .{} };
    }

    return .{ Error.PermissionDenied, 0, frame };
}

fn mapDeviceFrameHandler(
    ctx: *System,
    sender: u32,
    req: struct { caps.DeviceFrame, abi.sys.Rights, abi.sys.MapFlags },
) struct { Error!void, usize, caps.DeviceFrame } {
    const frame = req.@"0";
    const rights = req.@"1";
    const flags = req.@"2";

    // TODO: give each sender some id that the sender itself cannot change
    for (ctx.processes[1..]) |proc| {
        const process = proc orelse continue;
        if (process.pm_endpoint != sender) continue;

        const res, const addr, _ = ctx.vm_client.call(.mapDeviceFrame, .{
            process.vmem_handle,
            frame,
            rights,
            flags,
        }) catch |err| {
            log.err("failed to map a device frame: {}", .{err});
            return .{ Error.Internal, 0, frame };
        };
        res catch |err| {
            log.err("failed to map a device frame: {}", .{err});
            return .{ Error.Internal, 0, frame };
        };

        return .{ {}, addr, .{} };
    }

    return .{ Error.PermissionDenied, 0, frame };
}

fn newSenderHandler(ctx: *System, sender: u32, _: void) struct { Error!void, caps.Sender } {
    if (ctx.root_endpoint != sender)
        return .{ Error.PermissionDenied, .{} };

    const pm_sender = ctx.recv.subscribe() catch |err| {
        log.err("failed to subscribe: {}", .{err});
        return .{ err, .{} };
    };

    return .{ {}, pm_sender };
}

comptime {
    abi.rt.installRuntime();
}
