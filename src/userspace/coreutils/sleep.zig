const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;
const Ctx = @import("main.zig").Ctx;

//

pub fn main(ctx: Ctx) !void {
    var time = ctx.args.next() orelse {
        return try help(ctx);
    };
    if (time.len == 0) {
        return try help(ctx);
    }

    var factor: f128 = 1.0;

    const optional_suffix = time[time.len - 1];
    switch (optional_suffix) {
        's' => {
            factor = 1.0;
            time = time[0 .. time.len - 1];
        },
        'm' => {
            factor = 60.0;
            time = time[0 .. time.len - 1];
        },
        'h' => {
            factor = 3600.0;
            time = time[0 .. time.len - 1];
        },
        'd' => {
            factor = 86400.0;
            time = time[0 .. time.len - 1];
        },
        else => {},
    }

    const time_num = std.fmt.parseFloat(f128, time) catch {
        return try help(ctx);
    };

    const nanos: u128 = @intFromFloat(time_num * factor * 1_000_000_000.0);

    const hpet = abi.HpetProtocol.Client().init(caps.Sender{ .cap = 2 });
    _ = try hpet.call(.sleep, .{nanos});
}

fn help(ctx: Ctx) !void {
    try ctx.stdout_writer.print(
        \\usage: sleep NUMBER[SUFFIX]
        \\Pause for NUMBER seconds, where NUMBER is an integer or a floating-point.
        \\SUFFIX may be 's', 'm', 'h' or 'd', for seconds, minutes, hours, days.
    , .{});
}
