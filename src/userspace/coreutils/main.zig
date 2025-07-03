const abi = @import("abi");
const std = @import("std");

//

const log = std.log.scoped(.coreutils);
const Error = abi.sys.Error;

const Command = enum {
    coreutils,
    sh,
};

const commands = .{
    .coreutils = @import("coreutils.zig"),
    .sh = @import("sh.zig"),
};

pub var stdio: abi.PmProtocol.AllStdio = undefined;

//

pub fn main() !void {
    std.log.info("hello from coreutils", .{});

    try abi.process.init();
    // try abi.io.init();

    stdio = try (try abi.lpc.call(
        abi.PmProtocol.GetStdioRequest,
        .{},
        .{ .cap = 1 },
    )).asErrorUnion();

    const stdin = try abi.ring.Ring(u8)
        .fromShared(stdio.stdin.ring, null);
    const stdout = try abi.ring.Ring(u8)
        .fromShared(stdio.stdout.ring, null);

    // const stdin_reader = stdin.reader();
    const stdout_writer = stdout.writer();

    // try std.fmt.format(stdout_writer, "\nhello from coreutils\n", .{});

    var args = abi.process.args();
    const cmd_name = std.fs.path.basename(args.next().?);
    const cmd = std.meta.stringToEnum(Command, cmd_name) orelse {
        try std.fmt.format(
            stdout_writer,
            "{s} is not part of coreutils\n",
            .{cmd_name},
        );
        return;
    };

    switch (cmd) {
        inline else => |c| {
            try @field(commands, @tagName(c))
                .main(&args, &stdin, stdout_writer);
        },
    }

    _ = .{ stdin, stdout_writer };
}
