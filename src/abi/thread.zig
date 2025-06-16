const std = @import("std");

const caps = @import("caps.zig");
const loader = @import("loader.zig");
const sys = @import("sys.zig");

//

pub fn spawn(comptime function: anytype, args: anytype) !void {
    const vmem = try caps.Vmem.self();
    defer vmem.close();

    const proc = try caps.Process.self();
    defer proc.close();

    const thread = try caps.Thread.create(proc);
    defer thread.close();

    const Args = @TypeOf(args);
    const Instance = struct {
        args: Args,

        fn entryFn(raw_arg: usize) callconv(.SysV) void {
            const self: *@This() = @ptrFromInt(raw_arg);
            callFn(function, self.args);
            sys.selfStop();
        }
    };

    // map a stack
    const stack = try caps.Frame.create(1024 * 256);
    defer stack.close();
    var stack_ptr = try vmem.map(
        stack,
        0,
        0,
        1024 * 256,
        .{ .writable = true },
        .{},
    );
    // FIXME: protect the stack guard region as
    // no read, no write, no exec and prevent mapping
    try vmem.unmap(stack_ptr, 0x1000);

    stack_ptr += 1024 * 256; // top of the stack
    stack_ptr -= @sizeOf(Instance);
    const instance_ptr = stack_ptr;
    stack_ptr -= 0x100; // some extra zeroes that zig requires
    stack_ptr = std.mem.alignBackward(usize, stack_ptr, 0x100);

    const instance: *Instance = @ptrFromInt(instance_ptr);
    instance.* = .{ .args = args };

    const entry_ptr = @intFromPtr(&Instance.entryFn);

    try thread.setPrio(0);
    try thread.writeRegs(&.{
        .arg0 = instance_ptr,
        .rip = entry_ptr,
        .rsp = stack_ptr,
    });

    // std.log.info("spawn ip=0x{x} sp=0x{x} arg0=0x{x}", .{
    //     entry_ptr,
    //     stack_ptr,
    //     instance_ptr,
    // });

    try thread.start();
}

pub fn yield() void {
    sys.selfYield();
}

pub fn callFn(comptime function: anytype, args: anytype) void {
    const bad_fn_ret = "expected return type of startFn to be 'u8', 'noreturn', '!noreturn', 'void', or '!void'";

    switch (@typeInfo(@typeInfo(@TypeOf(function)).@"fn".return_type.?)) {
        .noreturn => {
            @call(.auto, function, args);
        },
        .void => {
            @call(.auto, function, args);
        },
        .int => {
            @call(.auto, function, args);
            // TODO: thread exit status
        },
        .error_union => |info| {
            switch (info.payload) {
                void, noreturn => {
                    @call(.auto, function, args) catch |err| {
                        std.log.err("error: {s}", .{@errorName(err)});
                    };
                },
                else => {
                    @compileError(bad_fn_ret);
                },
            }
        },
        else => {
            @compileError(bad_fn_ret);
        },
    }
}
