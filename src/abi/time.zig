const abi = @import("lib.zig");
const caps = @import("caps.zig");

//

pub fn sleep(
    nanoseconds: u128,
) void {
    return sleepWith(nanoseconds, caps.COMMON_HPET);
}

pub fn sleepWith(
    nanoseconds: u128,
    hpet_server: caps.Sender,
) void {
    const hpet = abi.HpetProtocol.Client().init(hpet_server);
    _ = hpet.call(.sleep, .{nanoseconds}) catch unreachable;
}

pub fn sleepDeadline(
    nanoseconds: u128,
) void {
    return sleepDeadlineWith(nanoseconds, caps.COMMON_HPET);
}

pub fn sleepDeadlineWith(
    nanoseconds: u128,
    hpet_server: caps.Sender,
) void {
    const hpet = abi.HpetProtocol.Client().init(hpet_server);
    _ = hpet.call(.sleepDeadline, .{nanoseconds}) catch unreachable;
}

pub fn nanoTimestamp() u128 {
    return nanoTimestampWith(caps.COMMON_HPET);
}

pub fn nanoTimestampWith(
    hpet_server: caps.Sender,
) u128 {
    const hpet = abi.HpetProtocol.Client().init(hpet_server);
    const result = hpet.call(.timestamp, {}) catch unreachable;
    return result.@"0";
}
