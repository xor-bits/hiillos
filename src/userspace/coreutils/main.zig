const abi = @import("abi");
const std = @import("std");

//

const log = std.log.scoped(.coreutils);
const Error = abi.sys.Error;

pub const Command = enum {
    coreutils,
    ls,
    sh,
    sleep,
};

const commands = .{
    .coreutils = @import("coreutils.zig"),
    .ls = @import("ls.zig"),
    .sh = @import("sh.zig"),
    .sleep = @import("sleep.zig"),
};

pub var stdio: abi.PmProtocol.AllStdio = undefined;

pub const Ctx = struct {
    args: *abi.process.ArgIterator,
    stdin: *const abi.ring.Ring(u8),
    stdout_writer: abi.ring.Ring(u8).Writer,
};

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
            std.log.info("coreutils {}", .{c});

            try @field(commands, @tagName(c))
                .main(Ctx{
                .args = &args,
                .stdin = &stdin,
                .stdout_writer = stdout_writer,
            });
        },
    }

    _ = .{ stdin, stdout_writer };
}
