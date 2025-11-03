const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");

// pub const relocator = @import("relocator.zig");
pub const btree = @import("btree.zig");
pub const caps = @import("caps.zig");
pub const conf = @import("conf.zig");
pub const debug = @import("debug.zig");
pub const epoch = @import("epoch.zig");
pub const escape = @import("escape.zig");
pub const font = @import("font");
pub const fs = @import("fs.zig");
pub const input = @import("input.zig");
pub const io = @import("io.zig");
pub const loader = @import("loader.zig");
pub const lock = @import("lock.zig");
pub const lpc = @import("lpc.zig");
pub const mem = @import("mem.zig");
pub const process = @import("process.zig");
pub const ring = @import("ring.zig");
pub const time = @import("time.zig");
pub const rt = @import("rt.zig");
pub const sys = @import("sys.zig");
pub const thread = @import("thread.zig");
pub const util = @import("util.zig");
pub const Deque = @import("deque.zig").Deque;

//

/// where the kernel places the root binary
pub const ROOT_EXE = 0x200_0000;

//

pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = if (@hasDecl(root, "log_level")) root.log_level else .debug,
};

fn logFn(comptime message_level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    const level_txt = comptime message_level.asText();
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

    unilog(level_txt ++ prefix2 ++ format ++ "\n", args);
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    @branchHint(.cold);

    const name = if (@hasDecl(root, "manifest"))
        root.manifest.getName()
    else
        "<unknown>";

    var buffer: [256]u8 = undefined;
    var log = UnifiedLog.init(&buffer);
    const writer = &log.interface;

    var iter = std.debug.StackIterator.init(
        @returnAddress(),
        @frameAddress(),
    );
    debug.printPanic(
        mem.slab_allocator,
        writer,
        name,
        msg,
        &iter,
        getSelfDwarf(),
        &.{},
    ) catch {};
    writer.flush() catch {};

    process.exit(1);
}

var self_exe: sys.Error![]const u8 = undefined;
var self_exe_once: lock.Once(thread.Mutex) = .{};

fn getSelfDwarf() !std.debug.Dwarf {
    return debug.getSelfDwarf(mem.slab_allocator, try loadSelfExe());
}

fn loadSelfExe() sys.Error![]const u8 {
    if (self_exe_once.tryRun()) {
        self_exe = tryLoadSelfExe();
        self_exe_once.complete();
    } else {
        self_exe_once.wait();
    }

    return try self_exe;
}

fn tryLoadSelfExe() sys.Error![]const u8 {
    if (@hasDecl(root, "manifest"))
        return sys.Error.NotFound;

    const vmem = caps.Vmem.self;

    const frame = try fs.openSelfExe();
    const size = try frame.getSize();

    const addr = try vmem.map(
        frame,
        0,
        0,
        size,
        .{},
    );

    return @as([*]const u8, @ptrFromInt(addr))[0..size];
}

//

/// sorry Zig, but error union type sucks
pub fn Result(comptime Ok: type, comptime Err: type) type {
    return union(enum(u8)) {
        ok: Ok,
        err: Err,

        pub fn tryOk(self: @This()) ?Ok {
            switch (self) {
                .ok => |v| return v,
                else => return null,
            }
        }

        pub fn tryErr(self: @This()) ?Err {
            switch (self) {
                .err => |v| return v,
                else => return null,
            }
        }

        pub fn fromErrorUnion(v: sys.Error!Ok) @This() {
            comptime std.debug.assert(Err == sys.ErrorEnum);

            if (v) |ok| {
                return .{ .ok = ok };
            } else |err| {
                return .{ .err = sys.errorToEnum(err) };
            }
        }

        pub fn asErrorUnion(self: @This()) sys.Error!Ok {
            comptime std.debug.assert(Err == sys.ErrorEnum);

            switch (self) {
                .ok => |v| return v,
                .err => |v| return sys.enumToError(v),
            }
        }
    };
}

//

/// kernel object variant that a capability points to
pub const ObjectType = enum(u8) {
    /// an unallocated/invalid capability
    null = 0,
    /// capability to manage a single process
    process,
    /// capability to manage a single thread control block (TCB)
    thread,
    /// capability to the virtual memory structure
    vmem,
    /// capability to a physical memory region (sized `ChunkSize`)
    frame,
    /// capability to **the** receiver end of an endpoint,
    /// there can only be a single receiver
    receiver,
    /// capability to **a** reply object
    /// it can be saved/loaded from receiver or replied with
    reply,
    /// capability to **a** sender end of an endpoint,
    /// there can be multiple senders
    sender,
    /// capability to **a** notify object
    /// there can be multiple of them
    notify,

    /// x86 specific capability that allows allocating `x86_ioport` capabilities
    x86_ioport_allocator,
    /// x86 specific capability that gives access to one IO port
    x86_ioport,
    /// x86 specific capability that allows allocating `x86_irq` capabilities
    x86_irq_allocator,
    /// x86 specific capability that gives access to one IRQ (= interrupt request)
    x86_irq,
};

/// kernel object size in bit-width (minus 12)
pub const ChunkSize = enum(u5) {
    @"4KiB",
    @"8KiB",
    @"16KiB",
    @"32KiB",
    @"64KiB",
    @"128KiB",
    @"256KiB",
    @"512KiB",
    @"1MiB",
    @"2MiB",
    @"4MiB",
    @"8MiB",
    @"16MiB",
    @"32MiB",
    @"64MiB",
    @"128MiB",
    @"256MiB",
    @"512MiB",
    @"1GiB",

    pub fn of(n_bytes: usize) ?ChunkSize {
        // 0 = 4KiB, 1 = 8KiB, ..
        const page_size = @max(12, std.math.log2_int_ceil(usize, n_bytes)) - 12;
        if (page_size >= 18) return null;
        return @enumFromInt(page_size);
    }

    pub fn next(self: @This()) ?@This() {
        return std.meta.intToEnum(@This(), @intFromEnum(self) + 1) catch return null;
    }

    pub fn sizeBytes(self: @This()) usize {
        return @as(usize, 0x1000) << @intFromEnum(self);
    }

    pub fn alignOf(self: @This()) usize {
        if (self.sizeBytes() >= ChunkSize.@"1GiB".sizeBytes()) return ChunkSize.@"1GiB".sizeBytes();
        if (self.sizeBytes() >= ChunkSize.@"2MiB".sizeBytes()) return ChunkSize.@"2MiB".sizeBytes();
        return ChunkSize.@"4KiB".sizeBytes();
    }
};

/// data structure in the boot info frame provided to the root process
pub const BootInfo = extern struct {
    root_data: [*]u8,
    root_data_len: usize,
    root_path: [*]u8,
    root_path_len: usize,
    initfs_data: [*]u8,
    initfs_data_len: usize,
    initfs_path: [*]u8,
    initfs_path_len: usize,
    framebuffer: caps.Frame = .{},
    framebuffer_info: caps.Frame = .{},
    hpet: caps.Frame = .{},
    hpet_info: caps.Frame = .{},
    // TODO: parse ACPI tables in rm server
    mcfg: caps.Frame = .{},
    mcfg_info: caps.Frame = .{},

    pub fn rootData(self: @This()) []u8 {
        return self.root_data[0..self.root_data_len];
    }

    pub fn rootPath(self: @This()) []u8 {
        return self.root_path[0..self.root_path_len];
    }

    pub fn initfsData(self: @This()) []u8 {
        return self.initfs_data[0..self.initfs_data_len];
    }

    pub fn initfsPath(self: @This()) []u8 {
        return self.initfs_path[0..self.initfs_path_len];
    }
};

//

pub fn unilog(comptime fmt: []const u8, args: anytype) void {
    var buffer: [256]u8 = undefined;
    var log = UnifiedLog.init(&buffer);
    const writer = &log.interface;

    // FIXME: lock the log
    writer.print(fmt ++ "\n", args) catch return;
    writer.flush() catch return;
}

pub const UnifiedLog = struct {
    interface: std.io.Writer,

    const vtable: std.io.Writer.VTable = .{
        .drain = drain,
    };

    pub fn init(buffer: []u8) @This() {
        return .{ .interface = .{
            .vtable = &vtable,
            .buffer = buffer,
        } };
    }

    fn drain(
        w: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) error{WriteFailed}!usize {
        sys.log(w.buffer[0..w.end]);
        _ = io.stdout.write(w.buffer[0..w.end]) catch 0;
        w.end = 0;

        const pattern = data[data.len - 1];
        var n: usize = 0;

        for (data[0 .. data.len - 1]) |bytes| {
            sys.log(bytes);
            _ = io.stdout.write(bytes) catch 0;
            n += bytes.len;
        }
        for (0..splat) |_| {
            sys.log(pattern);
            _ = io.stdout.write(pattern) catch 0;
        }
        return n + splat * pattern.len;
    }
};

pub fn syslog(comptime fmt: []const u8, args: anytype) void {
    var buffer: [256]u8 = undefined;
    var log = SysLog.init(&buffer);
    const writer = &log.interface;

    // FIXME: lock the log
    writer.print(fmt ++ "\n", args) catch return;
    writer.flush() catch return;
}

pub const SysLog = struct {
    interface: std.Io.Writer,

    const vtable: std.Io.Writer.VTable = .{
        .drain = drain,
    };

    pub fn init(buffer: []u8) @This() {
        return .{ .interface = .{
            .vtable = &vtable,
            .buffer = buffer,
        } };
    }

    fn drain(
        w: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) error{WriteFailed}!usize {
        sys.log(w.buffer[0..w.end]);
        w.end = 0;

        const pattern = data[data.len - 1];
        var n: usize = 0;

        for (data[0 .. data.len - 1]) |bytes| {
            sys.log(bytes);
            n += bytes.len;
        }
        for (0..splat) |_| {
            sys.log(pattern);
        }
        return n + splat * pattern.len;
    }
};

//

pub const DeviceKind = enum(u8) {
    hpet,
    framebuffer,
    mcfg,
};

pub const ServerKind = enum(u8) {
    vm,
    pm,
    rm,
    vfs,
};

pub const Device = struct {
    /// the actual physical device frame
    mmio_frame: caps.Frame = .{},
    /// info about the device
    info_frame: caps.Frame = .{},
};

/// generic filesystem driver protocol
pub const FsProtocol = util.Protocol(struct {
    /// open a file from fs, copy all of its content into the returned frame
    openFile: fn (inode: u128) struct { sys.Error!void, caps.Frame },

    /// open a directory from fs, copy all of its entries into the returned frame
    /// the returned data is an array of `Stat` structs, followed by an array of null terminated strings (inilined)
    openDir: fn (inode: u128) struct { sys.Error!void, caps.Frame, usize },

    /// inode of the filesystem root directory
    root: fn () struct { u128 },
});

pub const PmProtocol = struct {
    // pub const Error = enum {
    //     file_not_found,
    //     internal,
    // };

    pub const AllStdio = struct {
        stdin: io.Stdio = .{ .none = {} },
        stdout: io.Stdio = .{ .none = {} },
        stderr: io.Stdio = .{ .none = {} },

        pub fn clone(self: @This()) sys.Error!@This() {
            return .{
                .stdin = try self.stdin.clone(),
                .stdout = try self.stdout.clone(),
                .stderr = try self.stderr.clone(),
            };
        }

        pub fn deinit(self: @This()) void {
            self.stdin.deinit();
            self.stdout.deinit();
            self.stderr.deinit();
        }
    };

    pub const Process = struct {
        process: caps.Process,
        main_thread: caps.Thread,
        pid: u32,
    };

    /// exec an elf file and return the PID
    pub const ExecElfRequest = struct {
        /// cli argument map, null terminated strings concatenated
        arg_map: caps.Frame,
        /// cli environment map, null terminated strings concatenated
        env_map: caps.Frame,
        /// standard io 'file descriptors'
        stdio: AllStdio,

        pub const Response = Result(Process, sys.ErrorEnum);
        pub const Union = Request;
    };

    /// get the process local stdio
    pub const GetStdioRequest = struct {
        pub const Response = Result(AllStdio, sys.ErrorEnum);
        pub const Union = Request;
    };

    pub const Request = lpc.Request(&.{
        ExecElfRequest, GetStdioRequest,
    });
};

pub const VfsProtocol = struct {
    pub const OpenFileRequest = struct {
        path: fs.Path,
        open_opts: fs.OpenOptions,

        pub const Response = Result(caps.Frame, sys.ErrorEnum);
        pub const Union = Request;
    };

    pub const OpenDirRequest = struct {
        path: fs.Path,
        open_opts: fs.OpenOptions,

        pub const Response = Result(fs.Dir, sys.ErrorEnum);
        pub const Union = Request;
    };

    pub const SymlinkRequest = struct {
        oldpath: fs.Path,
        newpath: fs.Path,

        pub const Response = Result(void, sys.ErrorEnum);
        pub const Union = Request;
    };

    pub const LinkRequest = struct {
        path: fs.Path,
        socket: caps.Handle,

        pub const Response = Result(void, sys.ErrorEnum);
        pub const Union = Request;
    };

    pub const ConnectRequest = struct {
        path: fs.Path,

        pub const Response = Result(caps.Handle, sys.ErrorEnum);
        pub const Union = Request;
    };

    pub const NewSenderRequest = struct {
        uid: u32,

        pub const Response = Result(caps.Sender, sys.ErrorEnum);
        pub const Union = Request;
    };

    pub const Request = lpc.Request(&.{
        OpenFileRequest, OpenDirRequest, SymlinkRequest,
        LinkRequest,     ConnectRequest, NewSenderRequest,
    });
};

pub const TtyProtocol = struct {
    pub const Seat = struct {
        fb: caps.Frame,
        fb_info: caps.Frame,
        // input: ring.SharedRing,
        input: caps.Sender,

        pub fn deinit(self: @This()) void {
            self.fb.close();
            self.fb_info.close();
            self.input.close();
        }
    };

    pub const SeatRequest = struct {
        pub const Response = Result(Seat, sys.ErrorEnum);
        pub const Union = Request;
    };

    pub const Request = lpc.Request(&.{
        SeatRequest,
    });
};

// pub const FdProtocol = util.Protocol(struct {
//     // TODO: pager backed Frames
//     /// create a (possibly shared) handle to contents of a file
//     frame: fn () struct { sys.Error!void, caps.Frame },
//     seekRelative: fn (offs: i128) struct {},
//     seekStart: fn (offs: i128) struct {},
//     seekEnd: fn (offs: i128) struct {},
//     read: fn (buf: caps.Frame, buf_offs: usize, buf_len: usize) struct { sys.Error!void, usize },
//     write: fn (buf: caps.Frame, buf_offs: usize, buf_len: usize) struct { sys.Error!void, usize },
// });

pub const HpetProtocol = util.Protocol(struct {
    /// get the current timestamp
    timestamp: fn () u128,

    /// stop the thread until the current timestamp + `nanos` is reached
    sleep: fn (nanos: u128) void,

    /// stop the thread until this timestamp is reached
    sleepDeadline: fn (nanos: u128) void,
});

pub const Ps2Protocol = struct {
    pub const Next = struct {
        pub const Response = Result(input.Event, sys.ErrorEnum);
        pub const Union = Request;
    };

    pub const Request = lpc.Request(&.{
        Next,
    });
};

pub const FramebufferInfoFrame = extern struct {
    width: usize = 0,
    height: usize = 0,
    pitch: usize = 0,
    bpp: u16 = 0,
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
};

pub const McfgInfoFrame = extern struct {
    pci_segment_group: u16,
    start_pci_bus: u8,
    end_pci_bus: u8,
};

pub const Stat = extern struct {
    atime: u128,
    mtime: u128,
    inode: u128,
    uid: u64,
    gid: u64,
    size: u64,
    mode: Mode,
};

pub const Mode = packed struct {
    other_x: bool,
    other_w: bool,
    other_r: bool,

    group_x: bool,
    group_w: bool,
    group_r: bool,

    owner_x: bool,
    owner_w: bool,
    owner_r: bool,

    set_gid: bool,
    set_uid: bool,

    type: enum(u2) {
        file,
        dir,
        file_link,
        dir_link,
    },

    _reserved0: u3 = 0,
    _reserved1: u16 = 0,
};

test {
    _ = btree;
    _ = caps;
    _ = conf;
    _ = epoch;
    _ = input;
    _ = loader;
    _ = lock;
    _ = lpc;
    _ = mem;
    _ = ring;
    _ = rt;
    _ = sys;
    _ = thread;
    _ = util;
    // _ = relocator;
    std.testing.refAllDeclsRecursive(@This());
}
