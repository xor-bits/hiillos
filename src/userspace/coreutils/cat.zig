const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;
const Ctx = @import("main.zig").Ctx;

//

pub fn main(ctx: Ctx) !void {
    if (ctx.args.next()) |path| {
        try tryForwardPath(path);
    } else {
        try forward("-", &abi.io.stdin);
        return;
    }

    while (ctx.args.next()) |path| {
        try tryForwardPath(path);
    }
}

fn tryForwardPath(path: []const u8) !void {
    if (std.mem.eql(u8, path, "-")) {
        try forward(path, &abi.io.stdin);
    } else {
        const frame = abi.fs.openFileAbsolute(path, .{}) catch |err| {
            try abi.io.stderr.writer().print(
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

        try forward(path, &file);
    }
}

fn forward(path: []const u8, file: *abi.io.File) !void {
    var buf: [0x1000]u8 = undefined;
    while (true) {
        const n = file.reader().read(&buf) catch |err| {
            try abi.io.stderr.writer().print(
                "cannot read from {s}: {}\n",
                .{ path, err },
            );
            return;
        };
        if (n == 0) break;
        try abi.io.stdout.writer().writeAll(buf[0..n]);
    }
}
