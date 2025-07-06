const std = @import("std");
const abi = @import("abi");

//

pub fn main(
    args: *abi.process.ArgIterator,
    stdin: *const abi.ring.Ring(u8),
    stdout_writer: abi.ring.Ring(u8).Writer,
) !void {
    _ = args;
    try std.fmt.format(stdout_writer, "\n> ", .{});

    var command: [0x100]u8 = undefined;
    var command_len: usize = 0;

    while (true) {
        // const ch = try stdin.popWait();
        // try stdout.writeWait(&.{ ch, ch });

        const ch = try stdin.popWait();
        if (ch == '\n') {
            const cmd = command[0..command_len];
            command_len = 0;
            try std.fmt.format(
                stdout_writer,
                "\nunknown command: {s}\n\n> ",
                .{cmd},
            );
        } else {
            if (command_len < command.len) {
                command[command_len] = ch;
                command_len += 1;
            }
            try stdout_writer.writeAll(&.{ch});
        }
    }
}
