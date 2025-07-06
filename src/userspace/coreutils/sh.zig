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
        try ctx.stdout_writer.writeAll(&.{ch});

        if (ch != '\n' and command_len < command.len) {
            command[command_len] = ch;
            command_len += 1;
        }

        if (ch != '\n') continue;

        const cmd = command[0..command_len];
        command_len = 0;

        const args = try caps.Frame.create(0x1000);
        errdefer args.close();

        var args_stream = args.stream();
        try std.fmt.format(
            args_stream.writer(),
            "initfs:///sbin/{s}",
            .{cmd},
        );

        const result = try abi.lpc.call(abi.PmProtocol.ExecElfRequest, .{
            .arg_map = args,
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
