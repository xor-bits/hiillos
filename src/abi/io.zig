const std = @import("std");

const abi = @import("lib.zig");
const caps = @import("caps.zig");
const lock = @import("lock.zig");
const lpc = @import("lpc.zig");
const ring = @import("ring.zig");
const sys = @import("sys.zig");

//

/// IPC sendable file descriptor
pub const Stdio = union(enum) {
    /// shared ringbuffer
    ring: ring.SharedRing,
    /// raw mappable file
    file: struct {
        frame: caps.Frame,
        cursor: usize,
    },
    /// special: tells the pm to use inherit the stdio fd from caller
    inherit: void,
    /// /dev/null
    none: void,

    pub fn open(self: @This()) !File {
        return switch (self) {
            .ring => |v| .{
                .ring = try ring.Ring(u8)
                    .fromShared(v, null),
            },
            .file => |v| .{ .file = .{
                .frame = v.frame,
                .cursor = .init(v.cursor),
                .limit = try v.frame.getSize(),
            } },
            .inherit => {
                sys.log("tried to open inherit stdio");
                unreachable;
            },
            .none => .{ .none = {} },
        };
    }

    pub fn clone(self: @This()) sys.Error!@This() {
        return switch (self) {
            .ring => |v| .{ .ring = try v.clone() },
            .file => |v| .{ .file = .{
                .frame = try v.frame.clone(),
                .cursor = v.cursor,
            } },
            .inherit => .{ .inherit = {} },
            .none => .{ .none = {} },
        };
    }

    pub fn deinit(self: @This()) void {
        switch (self) {
            .ring => |v| v.deinit(),
            .file => |v| v.frame.close(),
            .inherit => {},
            .none => {},
        }
    }
};

/// usable file descriptor
pub const File = union(enum) {
    /// shared ringbuffer
    ring: ring.Ring(u8),
    /// raw mappable file
    file: struct {
        frame: caps.Frame,
        cursor: std.atomic.Value(usize),
        limit: usize,
    },
    /// /dev/null
    none: void,

    const Self = @This();

    pub fn share(self: Self) sys.Error!Stdio {
        return switch (self) {
            .ring => |v| .{ .ring = try v.share() },
            .file => |v| .{ .file = .{
                .frame = v.frame,
                .cursor = v.cursor.load(.monotonic),
                .limit = try v.frame.getSize(),
            } },
            .none => .{ .none = {} },
        };
    }

    pub fn deinit(self: Self) void {
        switch (self) {
            .ring => |v| v.deinit(),
            .file => |v| v.frame.close(),
            .none => {},
        }
    }

    pub const Reader = struct {
        self: *Self,

        pub const Error = ring.RingError || sys.Error;

        pub fn read(self: @This(), buf: []u8) Error!usize {
            switch (self.self.*) {
                .ring => |*v| {
                    const got = try v.readWait(buf);
                    return got.len;
                },
                .file => |*v| {
                    // TODO: read non-zero chunks instead of everything at once
                    const cursor = v.cursor.fetchAdd(buf.len, .monotonic);
                    if (cursor >= v.limit) return 0;
                    const limit = @min(v.limit - cursor, buf.len);
                    try v.frame.read(cursor, buf[0..limit]);
                    return limit;
                },
                .none => return 0,
            }
        }

        pub fn readSingle(self: @This()) Error!u8 {
            var buf: [1]u8 = undefined;
            const c = try self.read(&buf);
            std.debug.assert(c == 1);
            // if (c == 0) return Error.ReadZero;
            return buf[0];
        }

        pub fn flush(_: @This()) Error!void {}
    };

    pub fn reader(self: *Self) Reader {
        return .{ .self = self };
    }

    pub const Writer = struct {
        self: *Self,

        pub const Error = ring.RingError || sys.Error;

        pub fn print(self: @This(), comptime fmt: []const u8, args: anytype) Error!void {
            try std.fmt.format(self, fmt, args);
        }

        pub fn write(self: @This(), buf: []const u8) Error!usize {
            try self.writeAll(buf);
            return buf.len;
        }

        pub fn writeAll(self: @This(), buf: []const u8) Error!void {
            switch (self.self.*) {
                .ring => |*v| {
                    try v.writeWait(buf);
                },
                .file => |*v| {
                    const cursor = v.cursor.fetchAdd(buf.len, .monotonic);
                    if (cursor >= v.limit) {
                        // FIXME: resize
                        return;
                    }
                    const limit = @min(v.limit - cursor, buf.len);
                    try v.frame.write(cursor, buf[0..limit]);
                },
                .none => {},
            }
        }

        pub fn writeBytesNTimes(self: @This(), bytes: []const u8, n: usize) Error!void {
            for (0..n) |_| try self.writeAll(bytes);
        }

        pub fn flush(_: @This()) Error!void {}
    };

    pub fn writer(self: *Self) Writer {
        return .{ .self = self };
    }
};

pub var stdio: abi.PmProtocol.AllStdio = undefined;
pub var stdin: File = .{ .none = {} };
pub var stdout: File = .{ .none = {} };
pub var stderr: File = .{ .none = {} };

pub fn init() !void {
    stdio = try (try lpc.call(
        abi.PmProtocol.GetStdioRequest,
        .{},
        .{ .cap = 1 },
    )).asErrorUnion();

    stdin = try stdio.stdin.open();
    stdout = try stdio.stdout.open();
    stderr = try stdio.stderr.open();

    // seqcst fence
    _ = @atomicLoad(u8, @as(*const u8, @ptrCast(&stderr)), .seq_cst);
}
