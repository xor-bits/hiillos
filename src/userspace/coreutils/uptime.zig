const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;
const Ctx = @import("main.zig").Ctx;

//

pub fn main(_: Ctx) !void {
    const nanos = abi.time.nanoTimestamp();

    const uptime_secs = nanos / 1_000_000_000;
    const uptime_mins = uptime_secs / 60;
    const uptime_hours = uptime_mins / 60;
    const uptime_days = uptime_hours / 60;

    // TODO: RTC clock
    try abi.io.stdout.writer().print(
        \\ 00:00:00 up {} days, {d:02}:{d:02}
        \\
    , .{ uptime_days, uptime_hours, uptime_mins });
}
