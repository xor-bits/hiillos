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
            .file => |v| .{
                .file = .{
                    .frame = v.frame,
                    .cursor = v.cursor.load(.monotonic),
                    // .limit = try v.frame.getSize(),
                },
            },
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

    pub const ReadError = ring.RingError || sys.Error;

    pub fn read(self: *Self, dst: []u8) ReadError!usize {
        switch (self.*) {
            .ring => |*v| {
                const got = try v.readWait(dst);
                return got.len;
            },
            .file => |*v| {
                // TODO: read non-zero chunks instead of everything at once
                const cursor = v.cursor.fetchAdd(dst.len, .monotonic);
                if (cursor >= v.limit) return 0;
                const limit = @min(v.limit - cursor, dst.len);
                try v.frame.read(cursor, dst[0..limit]);
                return limit;
            },
            .none => return 0,
        }
    }

    pub const WriteError = ring.RingError || sys.Error;

    pub fn write(self: *Self, src: []const u8) WriteError!usize {
        switch (self.*) {
            .ring => |*v| {
                try v.writeWait(src);
                return src.len;
            },
            .file => |*v| {
                const cursor = v.cursor.fetchAdd(src.len, .monotonic);
                if (cursor >= v.limit) {
                    // FIXME: resize
                    return 0;
                }
                const limit = @min(v.limit - cursor, src.len);
                try v.frame.write(cursor, src[0..limit]);
                return limit;
            },
            .none => return src.len,
        }
    }

    pub const Reader = struct {
        self: *Self,
        interface: std.Io.Reader,

        fn read(self: *@This(), dst: []u8) std.Io.Reader.StreamError!usize {
            const n = self.self.read(dst) catch return error.ReadFailed;
            if (n == 0) return error.EndOfStream;
            return n;
        }

        fn stream(
            r: *std.Io.Reader,
            w: *std.Io.Writer,
            limit: std.Io.Limit,
        ) std.Io.Reader.StreamError!usize {
            if (limit == .nothing) return 0;
            const self: *@This() = @fieldParentPtr("interface", r);

            const dst = limit.slice(try w.writableSliceGreedy(1));
            const n = try self.read(dst);
            w.advance(n);
            return n;
        }
    };

    pub fn reader(self: *Self, buffer: []u8) Reader {
        return .{
            .self = self,
            .interface = .{
                .buffer = buffer,
                .end = 0,
                .seek = 0,
                .vtable = &.{
                    .stream = Reader.stream,
                },
            },
        };
    }

    pub const Writer = struct {
        self: *Self,
        interface: std.Io.Writer,

        fn drain(
            w: *std.Io.Writer,
            data: []const []const u8,
            splat: usize,
        ) error{WriteFailed}!usize {
            const self: *@This() = @fieldParentPtr("interface", w);

            {
                const written = self.self.write(w.buffer[0..w.end]) catch return error.WriteFailed;
                if (written != w.end) return error.WriteFailed;
                w.end = 0;
            }

            const pattern = data[data.len - 1];
            var n: usize = 0;

            for (data[0 .. data.len - 1]) |bytes| {
                const written = self.self.write(bytes) catch return error.WriteFailed;
                if (written == 0) return n;
                n += written;
            }
            for (0..splat) |_| {
                const written = self.self.write(pattern) catch return error.WriteFailed;
                if (written == 0) return n;
                n += written;
            }
            return n;
        }
    };

    pub fn writer(self: *Self, buffer: []u8) Writer {
        return .{
            .self = self,
            .interface = .{
                .buffer = buffer,
                .vtable = &.{
                    .drain = Writer.drain,
                },
            },
        };
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
