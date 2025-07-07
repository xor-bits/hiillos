const std = @import("std");
const root = @import("root");
const builtin = @import("builtin");

const caps = @import("caps.zig");
const sys = @import("sys.zig");
const thread = @import("thread.zig");

//

pub var root_ipc: caps.Sender = .{ .cap = 0 };
pub var vm_ipc: caps.Sender = .{ .cap = 0 };
pub var vmem_handle: usize = 0;

pub fn installRuntime() void {
    if (builtin.is_test) return;

    @export(&_start, .{
        .name = "_start",
    });
}

fn _start() callconv(.SysV) noreturn {
    thread.callFn(root.main, .{});
    sys.selfStop(0);
}
