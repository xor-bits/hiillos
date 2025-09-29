const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;

//

const log = std.log.scoped(.pm);
const Error = abi.sys.Error;

pub const std_options = abi.std_options;
pub const panic = abi.panic;
comptime {
    abi.rt.installRuntime();
}

//

pub export var manifest = abi.loader.Manifest.new(.{
    .name = "pm",
});

pub export var export_pm = abi.loader.Resource.new(.{
    .name = "hiillos.pm.ipc",
    .ty = .receiver,
});

pub export var import_pm = abi.loader.Resource.new(.{
    .name = "hiillos.pm.ipc",
    .ty = .sender,
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

pub export var import_tty = abi.loader.Resource.new(.{
    .name = "hiillos.tty.ipc",
    .ty = .sender,
});

var system: System = .{};

//

pub fn main() !void {
    try abi.rt.initServer();
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

    const vmem = caps.Vmem.self;

    // const init_elf = try open("initfs:///sbin/init");

    const init_elf_frame = try abi.fs.openFileAbsoluteWith(
        "initfs:///sbin/init",
        .{},
        .{ .cap = import_vfs.handle },
    );

    const init_elf_size = try init_elf_frame.getSize();
    const init_elf_addr = try vmem.map(
        init_elf_frame,
        0,
        0,
        0,
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
        try caps.Frame.init("PATH=initfs:///sbin/"),
    );
    std.debug.assert(init_proc.pid == 1);

    log.debug("pm ready", .{});
    try abi.lpc.daemon(Context{
        .recv = .{ .cap = export_pm.handle },
    });
}

pub const Process = struct {
    proc: caps.Process,
    thread: caps.Thread,
    uid: u32,

    self_stdio: abi.PmProtocol.AllStdio,
};

const Context = struct {
    recv: caps.Receiver,

    pub const routes = .{
        execElf,
        getStdio,
    };
    pub const Request = abi.PmProtocol.Request;
};

pub const System = struct {
    lock: abi.lock.Futex = .{},
    processes: std.ArrayList(?Process) = .{},
    // empty process ids into ↑
    free_slots: abi.Deque(u32) = .{},

    pub fn exec(
        self: *System,
        elf: *abi.loader.Elf,
        as_uid: u32,
        stdio: abi.PmProtocol.AllStdio,
        args: caps.Frame,
        env: caps.Frame,
    ) !abi.PmProtocol.Process {
        self.lock.lock();
        defer self.lock.unlock();

        const pid = try self.allocPidLocked();
        std.debug.assert(pid != 0);
        errdefer self.freePidLocked(pid) catch |err| {
            log.err("could not deallocate PID because another error occurred: {}", .{err});
        };

        const slot = &self.processes.items[pid - 1];
        std.debug.assert(slot.* == null);

        const self_vmem = caps.Vmem.self;

        const vmem = try caps.Vmem.create();
        defer vmem.close();
        const proc = try caps.Process.create(vmem);
        errdefer proc.close();
        const thread = try caps.Thread.create(proc);
        errdefer thread.close();

        const entry = try elf.loadInto(self_vmem, vmem);
        try abi.loader.prepareSpawn(vmem, thread, entry);

        var id: u32 = 0;
        id = try proc.giveHandle(try (caps.Sender{ .cap = import_pm.handle }).stampFinal(pid));
        std.debug.assert(id == caps.COMMON_PM.cap);
        id = try proc.giveHandle(try (caps.Sender{ .cap = import_hpet.handle }).clone());
        std.debug.assert(id == caps.COMMON_HPET.cap);
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
        id = try proc.giveHandle(try (caps.Sender{ .cap = import_tty.handle }).clone());
        std.debug.assert(id == caps.COMMON_TTY.cap);

        const _thread = try thread.clone();
        errdefer _thread.close();

        // TODO: async wait
        try abi.thread.spawnOptions(struct {
            fn run(thread_clone: caps.Thread, pid_to_kill: u32) !void {
                defer thread_clone.close();
                try thread_clone.start();
                _ = try thread_clone.wait();
                try system.kill(pid_to_kill);
            }
        }.run, .{ _thread, pid }, .{ .stack_size = 0x40000 });

        const given_proc = try proc.clone();
        errdefer given_proc.close();
        const given_thread = try thread.clone();
        errdefer given_thread.close();

        slot.* = .{
            .proc = given_proc,
            .thread = given_thread,
            .uid = as_uid,
            .self_stdio = stdio,
        };
        // log.debug("create PID={} slot={}", .{ pid, slot.*.? });

        return .{
            .process = proc,
            .main_thread = thread,
            .pid = pid,
        };
    }

    pub fn kill(self: *@This(), pid: u32) !void {
        std.debug.assert(pid != 0);

        self.lock.lock();
        defer self.lock.unlock();

        const slot = &self.processes.items[pid - 1];
        std.debug.assert(slot.* != null);

        // log.debug("kill PID={} slot={}", .{ pid, slot.*.? });

        // TODO: send a kill signal
        slot.*.?.proc.close();
        slot.*.?.thread.close();
        slot.* = null;

        try self.freePidLocked(pid);
    }

    pub fn allocPid(self: *@This()) !u32 {
        self.lock.lock();
        defer self.lock.unlock();
        return try self.allocPidLocked();
    }

    fn allocPidLocked(self: *@This()) !u32 {
        if (self.free_slots.popFront()) |pid| {
            return pid;
        } else {
            const pid = self.processes.items.len + 1;
            if (pid > std.math.maxInt(u32))
                return error.TooManyActiveProcesses;

            try self.processes.append(abi.mem.slab_allocator, null);
            return @intCast(pid);
        }
    }

    pub fn freePid(self: *@This(), pid: u32) !void {
        std.debug.assert(pid != 0);

        self.lock.lock();
        defer self.lock.unlock();

        return try self.freePidLocked(pid);
    }

    fn freePidLocked(self: *@This(), pid: u32) !void {
        try self.free_slots.pushBack(abi.mem.slab_allocator, pid);
    }
};

fn execElf(
    _: *abi.lpc.Daemon(Context),
    handler: abi.lpc.Handler(abi.PmProtocol.ExecElfRequest),
) !void {
    errdefer handler.reply.send(.{ .err = .internal });

    // const path = try handler.req.path.getMap();
    // defer path.deinit();
    // log.info("pm got execElf path={s}", .{path.p});

    // log.info("execElf from {}", .{daemon.stamp});
    // log.info("processes {}", .{daemon.ctx.processes.items.len});

    const uid = if (handler.stamp == 0)
        0
    else b: {
        system.lock.lock();
        defer system.lock.unlock();
        break :b system.processes.items[handler.stamp - 1].?.uid;
    };

    const stdio = handler.req.stdio;
    // errdefer stdio.deinit();
    // // FIXME: ring shouldnt be cloned
    // if (stdio.stdin == .inherit) stdio.stdin = try sender.self_stdio.stdin.clone();
    // if (stdio.stdout == .inherit) stdio.stdout = try sender.self_stdio.stdout.clone();
    // if (stdio.stderr == .inherit) stdio.stderr = try sender.self_stdio.stderr.clone();
    if (stdio.stdin == .inherit or stdio.stdout == .inherit or stdio.stderr == .inherit) {
        handler.reply.send(.{ .err = .invalid_argument });
        return;
    }

    // FIXME: make the arg_map frame copy-on-write

    const vmem = caps.Vmem.self;

    const arg_map_len = try handler.req.arg_map.getSize();
    const arg_map_addr = try vmem.map(
        handler.req.arg_map,
        0,
        0,
        0,
        .{},
    );
    defer vmem.unmap(arg_map_addr, arg_map_len) catch unreachable;
    const arg_map: []const u8 = @as([*]const u8, @ptrFromInt(arg_map_addr))[0..arg_map_len];
    const cmd: []const u8 = std.mem.sliceTo(arg_map, 0);

    log.info("exec '{s}'", .{cmd});

    const file_resp = try abi.lpc.call(abi.VfsProtocol.OpenFileRequest, .{
        .path = .{ .long = .{
            .frame = try handler.req.arg_map.clone(),
            .offs = 0,
            .len = cmd.len,
        } },
        .open_opts = .{},
    }, .{ .cap = import_vfs.handle });

    const elf_file = handler.reply.unwrapResult(
        caps.Frame,
        file_resp,
    ) orelse return;

    const elf_size = try elf_file.getSize();
    const elf_bytes = try vmem.map(
        elf_file,
        0,
        0,
        0,
        .{},
    );
    defer vmem.unmap(elf_bytes, elf_size) catch unreachable;

    var elf = try abi.loader.Elf.init(@as(
        [*]const u8,
        @ptrFromInt(elf_bytes),
    )[0..elf_size]);

    // TODO: get file stats for setuid, exec rights, etc.

    const proc = try system.exec(
        &elf,
        uid,
        stdio,
        handler.req.arg_map,
        handler.req.env_map,
    );

    handler.reply.send(.{ .ok = proc });
}

fn getStdio(
    _: *abi.lpc.Daemon(Context),
    handler: abi.lpc.Handler(abi.PmProtocol.GetStdioRequest),
) !void {
    errdefer handler.reply.send(.{ .err = .internal });

    if (handler.stamp == 0) {
        handler.reply.send(.{ .err = .permission_denied });
        return;
    }

    system.lock.lock();
    defer system.lock.unlock();

    const proc = &system.processes.items[handler.stamp - 1].?;
    handler.reply.send(.{ .ok = try proc.self_stdio.clone() });
}
