const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;

//

pub fn main(ctx: @import("main.zig").Ctx) !void {
    try std.fmt.format(ctx.stdout_writer, "\n> ", .{});

    var command: [0x100]u8 = undefined;
    var command_len: usize = 0;

    while (true) {
        // const ch = try stdin.popWait();
        // try stdout.writeWait(&.{ ch, ch });

        const ch = try ctx.stdin.popWait();

        if (std.ascii.isPrint(ch) or ch == '\n') {
            try ctx.stdout_writer.writeAll(&.{ch});
        }

        if (ch == 8 and command_len != 0) { // backspace
            command_len -= 1;
            command[command_len] = ' ';
            try ctx.stdout_writer.print("{} {}", .{
                abi.escape.cursorLeft(1),
                abi.escape.cursorLeft(1),
            });
            continue;
        }

        if (ch != '\n' and command_len < command.len) {
            command[command_len] = ch;
            command_len += 1;
        }

        if (ch != '\n') continue;

        const cmd = command[0..command_len];
        command_len = 0;

        const result = try abi.lpc.call(abi.PmProtocol.ExecElfRequest, .{
            .arg_map = try createArgMap(cmd),
            .env_map = try caps.Frame.create(0x1000),
            .stdio = try @import("main.zig").stdio.clone(),
        }, .{
            .cap = 1,
        });

        const proc = result.asErrorUnion() catch |err| {
            try std.fmt.format(
                ctx.stdout_writer,
                "unknown command: {s} ({})\n\n> ",
                .{ cmd, err },
            );
            continue;
        };

        const exit_code = try proc.main_thread.wait();

        if (exit_code == 0) {
            try std.fmt.format(
                ctx.stdout_writer,
                "\n> ",
                .{},
            );
        } else {
            try std.fmt.format(
                ctx.stdout_writer,
                "\n({}) > ",
                .{exit_code},
            );
        }
    }
}

fn createArgMap(cli: []const u8) !caps.Frame {
    const args = try caps.Frame.create(0x1000);
    errdefer args.close();

    var args_stream = args.stream();
    var args_buffered_stream = std.io.bufferedWriter(args_stream.writer());
    var args_writer = args_buffered_stream.writer();

    // TODO: use $PATH instead
    try args_writer.writeAll("initfs:///sbin/");

    var input_arg_it = std.mem.splitScalar(u8, cli, ' ');
    while (input_arg_it.next()) |input_arg| {
        if (input_arg.len == 0) continue;

        try args_writer.writeAll(input_arg);
        try args_writer.writeAll(&.{0});
    }

    try args_buffered_stream.flush();

    return args;
}
