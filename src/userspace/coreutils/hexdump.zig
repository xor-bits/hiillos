const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;
const Ctx = @import("main.zig").Ctx;

//

pub fn main(ctx: Ctx) !void {
    var buffer: [256]u8 = undefined;
    var hex_writer: HexdumpWriter = .{
        .writer = ctx.stdout,
        .row = 0,
        .col = 0,
        .interface = .{
            .buffer = &buffer,
            .vtable = &.{
                .drain = HexdumpWriter.drain,
            },
        },
    };

    if (ctx.args.next()) |path| {
        try tryForwardPath(ctx, path, &hex_writer.interface);
    } else {
        try forward(ctx, "-", ctx.stdin, &hex_writer.interface);
        return;
    }

    while (ctx.args.next()) |path| {
        try tryForwardPath(ctx, path, &hex_writer.interface);
    }

    try hex_writer.interface.flush();
    if (hex_writer.col == 0) return;
    try ctx.stdout.writeByte('\n');
}

fn tryForwardPath(
    ctx: Ctx,
    path: []const u8,
    out: *std.Io.Writer,
) !void {
    if (std.mem.eql(u8, path, "-")) {
        try forward(
            ctx,
            "-",
            ctx.stdin,
            out,
        );
    } else {
        const frame = abi.fs.openFileAbsolute(path, .{}) catch |err| {
            try ctx.stderr.print(
                "cannot open {s}: {}\n",
                .{ path, err },
            );
            return;
        };
        var file = abi.io.File{ .file = .{
            .frame = frame,
            .cursor = .init(0),
            .limit = try frame.getSize(),
        } };
        var buffer: [0x1000]u8 = undefined;
        var file_reader = file.reader(&buffer);

        try forward(
            ctx,
            path,
            &file_reader.interface,
            out,
        );
    }
}

fn forward(
    ctx: Ctx,
    path: []const u8,
    in: *std.Io.Reader,
    out: *std.Io.Writer,
) !void {
    _ = in.streamRemaining(out) catch |err| return switch (err) {
        error.ReadFailed => try ctx.stderr.print(
            "cannot read from {s}: {}\n",
            .{ path, err },
        ),
        error.WriteFailed => try ctx.stderr.print(
            "cannot write to stdout: {}\n",
            .{err},
        ),
    };
}

const HexdumpWriter = struct {
    writer: *std.Io.Writer,
    row: usize,
    col: usize,
    interface: std.Io.Writer,

    fn write(
        self: *@This(),
        bytes: []const u8,
    ) error{WriteFailed}!void {
        for (bytes) |byte| {
            if (self.col == 0)
                try self.writer.print("{x:07}", .{self.row * 16});
            if (self.col % 2 == 0)
                try self.writer.print(" ", .{});
            try self.writer.print("{x:02}", .{byte});
            // try self.writer.print(" {x:02}", .{byte});

            self.col += 1;
            if (self.col == 16) {
                self.col = 0;
                self.row += 1;
                try self.writer.print("\n", .{});
            }
        }
        try self.writer.flush();
    }

    fn drain(
        w: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) error{WriteFailed}!usize {
        const self: *@This() = @fieldParentPtr("interface", w);

        try self.write(w.buffer[0..w.end]);
        w.end = 0;

        const pattern = data[data.len - 1];
        var n: usize = 0;

        for (data[0 .. data.len - 1]) |bytes| {
            try self.write(bytes);
            n += bytes.len;
        }
        for (0..splat) |_| {
            try self.write(pattern);
        }
        return n + splat * pattern.len;
    }
};
