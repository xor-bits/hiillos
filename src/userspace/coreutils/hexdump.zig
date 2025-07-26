const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;
const Ctx = @import("main.zig").Ctx;

//

pub fn main(ctx: Ctx) !void {
    var row: usize = 0;
    var col: usize = 0;

    if (ctx.args.next()) |path| {
        try tryForwardPath(path, &row, &col);
    } else {
        try forward("-", &abi.io.stdin, &row, &col);
        return;
    }

    while (ctx.args.next()) |path| {
        try tryForwardPath(path, &row, &col);
    }

    if (col == 0) return;
    try abi.io.stdout.writer().print("\n", .{});
}

fn tryForwardPath(
    path: []const u8,
    row: *usize,
    col: *usize,
) !void {
    if (std.mem.eql(u8, path, "-")) {
        try forward(path, &abi.io.stdin, row, col);
    } else {
        const frame = forwardPath(path) catch |err| {
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

        try forward(path, &file, row, col);
    }
}

fn forwardPath(path: []const u8) !caps.Frame {
    const result = try abi.lpc.call(abi.VfsProtocol.OpenFileRequest, .{
        .path = try abi.fs.Path.new(path),
        .open_opts = .{ .mode = .read_only },
    }, .{
        .cap = 4,
    });
    return try result.asErrorUnion();
}

fn forward(
    path: []const u8,
    file: *abi.io.File,
    row: *usize,
    col: *usize,
) !void {
    var buf_writer = std.io.bufferedWriter(abi.io.stdout.writer());
    const out = buf_writer.writer();

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

        for (buf[0..n]) |byte| {
            if (col.* == 0)
                try out.print("{x:07}", .{row.* * 16});
            if (col.* % 2 == 0)
                try out.print(" ", .{});
            try out.print("{x:02}", .{byte});
            // try out.print(" {x:02}", .{byte});

            col.* += 1;
            if (col.* == 16) {
                col.* = 0;
                row.* += 1;
                try out.print("\n", .{});
            }
        }
    }

    try buf_writer.flush();
}
