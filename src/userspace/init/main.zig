const std = @import("std");
const abi = @import("abi");

const spinner = @import("spinner.zig");

//

pub const std_options = abi.std_options;
pub const panic = abi.panic;

const caps = abi.caps;
const log = std.log.scoped(.init);

//

pub fn main() !void {
    log.info("hello from init", .{});

    try spinner.spinnerMain();

    
}

comptime {
    abi.rt.installRuntime();
}
