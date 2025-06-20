const std = @import("std");
const builtin = @import("builtin");
const limine = @import("limine");

const main = @import("main.zig");

pub const x86_64 = @import("arch/x86_64.zig");

//

pub usingnamespace x86_64;

var cpu_id_next = std.atomic.Value(u32).init(0);
pub fn nextCpuId() u32 {
    return cpu_id_next.fetchAdd(1, .monotonic);
}
