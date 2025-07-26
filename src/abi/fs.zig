const std = @import("std");

const abi = @import("lib.zig");
const caps = @import("caps.zig");
const io = @import("io.zig");
const lpc = @import("lpc.zig");
const process = @import("process.zig");
const sys = @import("sys.zig");

const Error = sys.Error;

//

pub const path = struct {
    pub fn eql(a: []const u8, b: []const u8) bool {
        var a_iter = absolutePartIterator(a);
        var b_iter = absolutePartIterator(b);

        while (true) {
            const a_part_opt = a_iter.next();
            const b_part_opt = b_iter.next();

            if ((a_part_opt == null and b_part_opt != null) or
                (a_part_opt != null and b_part_opt == null))
                return false;

            const a_part = a_part_opt orelse return true;
            const b_part = b_part_opt orelse return true;

            if (!std.mem.eql(u8, a_part.name, b_part.name))
                return false;
        }

        return true;
    }

    test {
        try std.testing.expect(eql("/absolute/path/to_dir", "/absolute/path/to_dir"));

        try std.testing.expect(!eql("/absolute/path/to_dir", "/absolute/path/to_file"));
        try std.testing.expect(!eql("/absolute/path/to_dir", "/path/to_dir"));
        try std.testing.expect(!eql("/path/to_dir", "/absolute/path/to_dir"));

        try std.testing.expect(eql("./path/to_dir", "/path/to_dir"));
        try std.testing.expect(eql("./path/to_dir", "path/to_dir"));
        try std.testing.expect(eql("./path/to_dir", "./path/to_dir"));
    }

    pub fn startsWith(p: []const u8, start: []const u8) bool {
        var path_iter = absolutePartIterator(p);
        var start_iter = absolutePartIterator(start);

        while (true) {
            const path_part_opt = path_iter.next();
            const start_part_opt = start_iter.next();

            if (path_part_opt == null and start_part_opt != null)
                return false;

            const a_part = path_part_opt orelse return true;
            const b_part = start_part_opt orelse return true;

            if (!std.mem.eql(u8, a_part.name, b_part.name))
                return false;
        }

        return true;
    }

    pub const AbsolutePartIterator = struct {
        inner: std.fs.path.NativeComponentIterator,

        pub fn next(self: *@This()) ?std.fs.path.NativeComponentIterator.Component {
            while (true) {
                const part = self.inner.next() orelse
                    return null;
                if (part.name.len == 0 or std.mem.eql(u8, part.name, "."))
                    continue;
                return part;
            }
        }
    };

    pub fn absolutePartIterator(p: []const u8) AbsolutePartIterator {
        return .{ .inner = std.fs.path.componentIterator(p) catch
            @compileError("this is unix-like") };
    }
};

pub const OpenOptions = packed struct {
    mode: Mode = .read_only,
    file_policy: MissingPolicy = .use_existing,
    dir_policy: MissingPolicy = .use_existing,
    _: u2 = 0,

    pub const Mode = enum(u2) {
        read_only = 1,
        write_only = 2,
        read_write = 3,
        _,
    };

    pub const MissingPolicy = enum(u2) {
        /// always create a new item and return an error if it already exists
        create_new = 1,
        /// always use an existing item and return an error if it doesnt exist
        use_existing = 2,
        /// use an existing item or create a new one if it doesnt already exist
        create_if_missing = 3,
        _,
    };
};

pub fn withPath1(
    ctx: anytype,
    p: *const [32:0]u8,
    comptime f: anytype,
) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
    return f(ctx, std.mem.sliceTo(p, 0));
}

pub fn withPath2(
    ctx: anytype,
    path_frame: caps.Frame,
    path_frame_offs: usize,
    path_len: usize,
    comptime f: anytype,
) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
    defer path_frame.close();

    const path_frame_size = path_frame.getSize() catch unreachable;
    if (path_len > path_frame_size)
        return Error.InvalidArgument;

    const addr = caps.ROOT_SELF_VMEM.map(
        path_frame,
        path_frame_offs,
        0,
        path_len,
        .{},
        .{},
    ) catch |err| {
        std.log.err("withPath2 failed to map frame: {}", .{err});
        return Error.Internal;
    };
    defer caps.ROOT_SELF_VMEM.unmap(addr, path_len) catch unreachable;

    const path_ptr: [*]const u8 = @ptrFromInt(addr);

    return f(ctx, std.mem.sliceTo(path_ptr[0..path_len], 0));
}

pub const Path = union(enum(u8)) {
    short: [32:0]u8,
    long: struct {
        frame: caps.Frame,
        offs: usize,
        len: usize,
    },

    pub fn new(s: []const u8) sys.Error!Path {
        if (s.len <= 32) {
            var short: [32:0]u8 = [1:0]u8{0} ** 32;
            std.mem.copyForwards(u8, &short, s);
            return .{ .short = short };
        } else {
            const frame = try caps.Frame.create(s.len);
            try frame.write(0, s);
            return .{ .long = .{
                .frame = frame,
                .offs = 0,
                .len = s.len,
            } };
        }
    }

    pub fn deinit(self: @This()) void {
        switch (self) {
            .long => |v| v.frame.close(),
            else => {},
        }
    }

    pub fn len(self: @This()) usize {
        switch (self) {
            .short => |v| return v.len,
            .long => |v| return v.len,
        }
    }

    pub fn getCopy(self: @This(), buf: []u8) sys.Error!void {
        switch (self) {
            .short => |v| std.mem.copyForwards(u8, buf, &v),
            .long => |v| try v.frame.read(v.offs, buf[0..v.len]),
        }
    }

    pub fn getMap(self: *const @This()) sys.Error!AccessiblePath {
        switch (self.*) {
            .short => |*v| return .{ .p = std.mem.sliceTo(v, 0) },
            .long => |v| {
                const vmem = try caps.Vmem.self();
                const addr = try vmem.map(
                    v.frame, // FIXME: make the v.frame copy-on-write
                    v.offs,
                    0,
                    v.len,
                    .{},
                    .{},
                );

                v.frame.close();

                return .{
                    .p = @as([*]const u8, @ptrFromInt(addr))[0..v.len],
                    .vmem = vmem,
                };
            },
        }
    }
};

pub const AccessiblePath = struct {
    p: []const u8,
    vmem: ?caps.Vmem = null,

    pub fn deinit(self: @This()) void {
        const vmem = self.vmem orelse return;

        vmem.unmap(@intFromPtr(self.p.ptr), self.p.len) catch
            unreachable;
    }
};

pub const EntType = enum(u8) {
    unknown,
    named_pipe,
    character_device,
    dir,
    block_device,
    file,
    symlink,
    socket,
};

pub const DirEnt = struct {
    type: EntType,
    name: []const u8,
};

pub const DirEntRaw = extern struct {
    entry_size: u16,
    type: EntType,
    _: u8 = 0,
    name: u8, // field address is the address of first byte of name https://github.com/ziglang/zig/issues/173
};

pub const DirEntRawNoName = extern struct {
    entry_size: u16,
    type: EntType,
    _: u8 = 0,
};

pub const Dir = struct {
    data: caps.Frame,
    count: usize,

    pub fn deinit(self: @This()) void {
        self.data.close();
    }

    pub fn iterate(self: @This()) !Iterator {
        const vmem = try caps.Vmem.self();
        errdefer vmem.close();

        // FIXME: make the frame copy-on-write

        const frame_size = try self.data.getSize();
        const addr = try vmem.map(
            self.data,
            0,
            0,
            0,
            .{},
            .{},
        );

        return .{
            .vmem = vmem,
            .entries = @as([*]const u8, @ptrFromInt(addr))[0..frame_size],
            .count = self.count,
            .idx = 0,
        };
    }

    pub const Iterator = struct {
        vmem: caps.Vmem,
        entries: []const u8,
        count: usize,
        idx: usize,

        pub fn deinit(self: @This()) void {
            self.vmem.unmap(
                @intFromPtr(self.entries.ptr),
                self.entries.len,
            ) catch unreachable;
            self.vmem.close();
        }

        pub fn next(self: *@This()) ?DirEnt {
            if (self.count == 0)
                return null;
            self.count -= 1;

            const idx = self.idx;
            if (self.entries.len < idx + @sizeOf(DirEntRaw))
                return null;

            const entry = @as(*align(1) const DirEntRaw, @ptrCast(&self.entries[idx]));
            const name: []const u8 = std.mem.sliceTo(self.entries[idx + @offsetOf(DirEntRaw, "name") ..], 0);
            self.idx += entry.entry_size;

            return .{ .type = entry.type, .name = name };
        }
    };
};

pub fn openFileAbsolute(
    absolute_path: []const u8,
    flags: OpenOptions,
) sys.Error!caps.Frame {
    return try openFileAbsoluteWith(absolute_path, flags, caps.COMMON_VFS);
}

pub fn openFileAbsoluteWith(
    absolute_path: []const u8,
    flags: OpenOptions,
    vfs_server: caps.Sender,
) sys.Error!caps.Frame {
    const file_resp = try lpc.call(
        abi.VfsProtocol.OpenFileRequest,
        .{
            .path = abi.fs.Path.new(absolute_path) catch unreachable,
            .open_opts = flags,
        },
        vfs_server,
    );
    return try file_resp.asErrorUnion();
}

pub fn openDirAbsolute(
    absolute_path: []const u8,
    flags: OpenOptions,
) sys.Error!Dir {
    return try openDirAbsoluteWith(absolute_path, flags, caps.COMMON_VFS);
}

pub fn openDirAbsoluteWith(
    absolute_path: []const u8,
    flags: OpenOptions,
    vfs_server: caps.Sender,
) sys.Error!Dir {
    const result = try abi.lpc.call(abi.VfsProtocol.OpenDirRequest, .{
        .path = try abi.fs.Path.new(absolute_path),
        .open_opts = flags,
    }, vfs_server);
    return try result.asErrorUnion();
}

pub fn openSelfExe() sys.Error!io.File {
    return try openSelfExeWith(caps.COMMON_VFS);
}

pub fn openSelfExeWith(
    vfs_server: caps.Sender,
) sys.Error!caps.Frame {
    var it = process.args();
    const self_exe_path = it.next().?;

    return openFileAbsoluteWith(self_exe_path, .{}, vfs_server);
}
