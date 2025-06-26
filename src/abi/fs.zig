const std = @import("std");

const caps = @import("caps.zig");
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
    mode: Mode = .read_write,
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
