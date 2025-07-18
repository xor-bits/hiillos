const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;

//

pub fn main(_: @import("main.zig").Ctx) !void {
    const stdin = abi.io.stdin.reader();
    const stdout = abi.io.stdout.writer();

    try stdout.print("> ", .{});

    var command: [0x100]u8 = undefined;
    var command_len: usize = 0;

    while (true) {
        const ch = try stdin.readSingle();

        if (std.ascii.isPrint(ch) or ch == '\n') {
            try stdout.writeAll(&.{ch});
        }

        if (ch == 8) { // backspace
            if (command_len == 0) continue;
            command_len -= 1;
            command[command_len] = ' ';
            try stdout.print("{} {}", .{
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

        if (cmd.len == 0) {
            try stdout.print("\n> ", .{});
            continue;
        }

        const result = try abi.lpc.call(abi.PmProtocol.ExecElfRequest, .{
            .arg_map = try createArgMap(cmd),
            .env_map = try caps.COMMON_ENV_MAP.clone(),
            .stdio = try abi.io.stdio.clone(),
        }, .{
            .cap = 1,
        });

        const proc = result.asErrorUnion() catch |err| {
            try stdout.print(
                "unknown command: {s} ({})\n\n> ",
                .{ cmd, err },
            );
            continue;
        };

        const exit_code = try proc.main_thread.wait();

        if (exit_code == 0) {
            try stdout.print(
                "\n> ",
                .{},
            );
        } else {
            try stdout.print(
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
