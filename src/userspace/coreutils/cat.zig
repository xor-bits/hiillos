const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;
const Ctx = @import("main.zig").Ctx;

//

pub fn main(ctx: Ctx) !void {
    if (ctx.args.next()) |path| {
        try tryForwardPath(ctx, path);
    } else {
        try forward(
            ctx,
            "-",
            ctx.stdin,
            ctx.stdout,
        );
        return;
    }

    while (ctx.args.next()) |path| {
        try tryForwardPath(ctx, path);
    }
}

fn tryForwardPath(
    ctx: Ctx,
    path: []const u8,
) !void {
    if (std.mem.eql(u8, path, "-")) {
        try forward(
            ctx,
            path,
            ctx.stdin,
            ctx.stdout,
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
            ctx.stdout,
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
