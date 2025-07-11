const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;

//

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

    const file_resp = try abi.lpc.call(
        abi.VfsProtocol.OpenFileRequest,
        .{ .path = comptime abi.fs.Path.new(
            "initfs:///sbin/init",
        ) catch unreachable, .open_opts = .{
            .mode = .read_only,
            .file_policy = .use_existing,
            .dir_policy = .use_existing,
        } },
        .{ .cap = import_vfs.handle },
    );
    const init_elf_frame = try file_resp.asErrorUnion();

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
    const init_proc = try system.exec(
        &init_elf,
        0,
        .{},
        try caps.Frame.create(0x1000),
        try caps.Frame.create(0x1000),
    );
    std.debug.assert(init_proc.pid == 1);

    log.debug("pm ready", .{});
    try abi.lpc.daemon(system);
}

pub const Process = struct {
    vmem: caps.Vmem,
    proc: caps.Process,
    thread: caps.Thread,
    uid: u32,

    self_stdio: abi.PmProtocol.AllStdio,
};

pub const System = struct {
    recv: caps.Receiver,
    self_vmem: caps.Vmem,

    processes: std.ArrayList(?Process) = .init(abi.mem.slab_allocator),
    // empty process ids into ↑
    free_slots: std.fifo.LinearFifo(u32, .Dynamic) = .init(abi.mem.slab_allocator),

    pub const routes = .{
        execElf,
        getStdio,
    };
    pub const Request = abi.PmProtocol.Request;

    pub fn exec(
        system: *System,
        elf: *abi.loader.Elf,
        as_uid: u32,
        stdio: abi.PmProtocol.AllStdio,
        args: caps.Frame,
        env: caps.Frame,
    ) !abi.PmProtocol.Process {
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
        std.debug.assert(id == caps.COMMON_PM.cap);
        id = try proc.giveHandle(try (caps.Sender{ .cap = import_hpet.handle }).clone());
        std.debug.assert(id == caps.COMMON_HPET.tx.cap);
        id = try proc.giveHandle(try (caps.Sender{ .cap = import_ps2.handle }).clone());
        std.debug.assert(id == caps.COMMON_PS2.cap);

        const file_resp = try abi.lpc.call(
            abi.VfsProtocol.NewSenderRequest,
            .{ .uid = as_uid },
            .{ .cap = import_vfs.handle },
        );
        const vfs_ipc = try file_resp.asErrorUnion();

        id = try proc.giveHandle(vfs_ipc);
        std.debug.assert(id == caps.COMMON_VFS.cap);
        id = try proc.giveHandle(args);
        std.debug.assert(id == caps.COMMON_ARG_MAP.cap);
        id = try proc.giveHandle(env);
        std.debug.assert(id == caps.COMMON_ENV_MAP.cap);

        try thread.start();

        slot.* = .{
            .vmem = vmem,
            .proc = proc,
            .thread = thread,
            .uid = as_uid,
            .self_stdio = stdio,
        };

        vmem.close();

        return .{
            .process = proc,
            .main_thread = thread,
            .pid = pid,
        };
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

fn execElf(
    daemon: *abi.lpc.Daemon(System),
    handler: abi.lpc.Handler(abi.PmProtocol.ExecElfRequest),
) !void {
    errdefer handler.reply.send(.{ .err = .internal });

    // const path = try handler.req.path.getMap();
    // defer path.deinit();
    // log.info("pm got execElf path={s}", .{path.p});

    // log.info("execElf from {}", .{daemon.stamp});
    // log.info("processes {}", .{daemon.ctx.processes.items.len});

    const uid = if (daemon.stamp == 0)
        0
    else
        daemon.ctx.processes.items[daemon.stamp - 1].?.uid;

    const stdio = handler.req.stdio;
    // errdefer stdio.deinit();
    // // FIXME: ring shouldnt be cloned
    // if (stdio.stdin == .inherit) stdio.stdin = try sender.self_stdio.stdin.clone();
    // if (stdio.stdout == .inherit) stdio.stdout = try sender.self_stdio.stdout.clone();
    // if (stdio.stderr == .inherit) stdio.stderr = try sender.self_stdio.stderr.clone();

    // FIXME: make the arg_map frame copy-on-write

    const arg_map_len = try handler.req.arg_map.getSize();
    const arg_map_addr = try daemon.ctx.self_vmem.map(
        handler.req.arg_map,
        0,
        0,
        0,
        .{},
        .{},
    );
    const arg_map: []const u8 = @as([*]const u8, @ptrFromInt(arg_map_addr))[0..arg_map_len];
    const cmd: []const u8 = std.mem.sliceTo(arg_map, 0);

    log.info("exec '{s}'", .{cmd});

    const file_resp = try abi.lpc.call(abi.VfsProtocol.OpenFileRequest, .{
        .path = .{ .long = .{
            .frame = try handler.req.arg_map.clone(),
            .offs = 0,
            .len = cmd.len,
        } },
        .open_opts = .{
            .mode = .read_only,
            .file_policy = .use_existing,
            .dir_policy = .use_existing,
        },
    }, .{
        .cap = import_vfs.handle,
    });

    const elf_file = handler.reply.unwrapResult(
        caps.Frame,
        file_resp,
    ) orelse return;

    const elf_size = try elf_file.getSize();
    const elf_bytes = try daemon.ctx.self_vmem.map(elf_file, 0, 0, 0, .{}, .{});
    defer daemon.ctx.self_vmem.unmap(elf_bytes, elf_size) catch unreachable;

    var elf = try abi.loader.Elf.init(@as(
        [*]const u8,
        @ptrFromInt(elf_bytes),
    )[0..elf_size]);

    // TODO: get file stats for setuid, exec rights, etc.

    const proc = try daemon.ctx.exec(
        &elf,
        uid,
        stdio,
        handler.req.arg_map,
        handler.req.env_map,
    );

    handler.reply.send(.{ .ok = proc });
}

fn getStdio(
    daemon: *abi.lpc.Daemon(System),
    handler: abi.lpc.Handler(abi.PmProtocol.GetStdioRequest),
) !void {
    errdefer handler.reply.send(.{ .err = .internal });

    const proc = &daemon.ctx.processes.items[daemon.stamp - 1].?;
    handler.reply.send(.{ .ok = try proc.self_stdio.clone() });
}
