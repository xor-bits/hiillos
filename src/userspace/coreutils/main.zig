const abi = @import("abi");
const std = @import("std");

//

const log = std.log.scoped(.coreutils);
const Error = abi.sys.Error;

//

pub fn main() !void {
    std.log.info("hello from coreutils", .{});

    try abi.process.init();
    // try abi.io.init();

    const stdio = try (try abi.lpc.call(
        abi.PmProtocol.GetStdioRequest,
        .{},
        .{ .cap = 1 },
    )).asErrorUnion();

    const stdin = try abi.ring.Ring(u8)
        .fromShared(stdio.stdin.ring, null);
    const stdout = try abi.ring.Ring(u8)
        .fromShared(stdio.stdout.ring, null);

    try stdout.writeWait("\nhello from coreutils\n");

    var args = abi.process.args();
    while (args.next()) |arg| {
        try stdout.writeWait(arg);
        try stdout.pushWait(' ');
    }

    try stdout.writeWait("\n> ");

    // var command: [0x100]u8 = undefined;
    // var command_len: usize = 0;

    while (true) {
        // const ch = try stdin.popWait();
        // try stdout.writeWait(&.{ ch, ch });

        const ch = try stdin.popWait();
        if (ch == '\n') {
            try stdout.writeWait("\ncommand not found\n\n> ");
        } else {
            try stdout.pushWait(ch);
        }
    }
}
