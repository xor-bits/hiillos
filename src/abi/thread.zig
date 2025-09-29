const std = @import("std");

const abi = @import("lib.zig");
const caps = @import("caps.zig");
const loader = @import("loader.zig");
const lock = @import("lock.zig");
const process = @import("process.zig");
const sys = @import("sys.zig");

//

pub const Mutex = lock.Futex;

pub fn spawn(comptime function: anytype, args: anytype) !void {
    // std.process.exit(status: u8);
    try spawnOptions(function, args, .{});
}

pub fn exit(code: usize) noreturn {
    sys.threadExit(code);
}

pub const SpawnOptions = struct {
    vmem: ?caps.Vmem = null,
    proc: ?caps.Process = null,
    thread: ?caps.Thread = null,
    stack_size: usize = 1024 * 256,
};

pub fn spawnOptions(comptime function: anytype, args: anytype, opts: SpawnOptions) !void {
    if (opts.stack_size < 0x4000) @panic("stack too small");

    const vmem = opts.vmem orelse caps.Vmem.self;
    const proc = opts.proc orelse caps.Process.self;
    const thread = opts.thread orelse try caps.Thread.create(proc);
    defer if (opts.thread == null) thread.close();

    const Args = @TypeOf(args);
    const Instance = struct {
        args: Args,

        fn entryFn(raw_arg: usize) callconv(.c) noreturn {
            const self: *volatile @This() = @ptrFromInt(raw_arg);
            callFn(function, .thread, self.*.args);
        }
    };

    // map a stack
    const stack = try caps.Frame.create(opts.stack_size, .{});
    defer stack.close();
    var stack_ptr = try vmem.map(
        stack,
        0,
        0,
        opts.stack_size,
        .{ .write = true },
    );
    // FIXME: protect the stack guard region as
    // no read, no write, no exec and prevent mapping
    try vmem.unmap(stack_ptr, 0x1000);
    // std.log.info("thread stack = 0x{x}", .{stack_ptr});

    stack_ptr += opts.stack_size; // top of the stack
    stack_ptr -= @sizeOf(Instance);
    const instance_ptr = stack_ptr;
    stack_ptr -= 0x100; // some extra zeroes that zig requires
    stack_ptr = std.mem.alignBackward(usize, stack_ptr + 0x8, 0x100) - 0x8;

    const instance: *volatile Instance = @ptrFromInt(instance_ptr);
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

pub fn callFn(
    comptime function: anytype,
    comptime exit_method: enum { thread, process },
    args: anytype,
) noreturn {
    // TODO: process exit in kernel
    _ = exit_method;
    // const exit_fn = if (exit_method == .process) process.exit else exit;
    const exit_fn = exit;
    const result = @call(.auto, function, args);
    handleExitResult(exit_fn, result);
}

fn handleExitResult(
    comptime exit_fn: fn (code: usize) noreturn,
    result: anytype,
) noreturn {
    const bad_fn_ret = "expected return type of startFn to be u*, 'noreturn', '!noreturn', 'void', or '!void'";

    switch (@typeInfo(@TypeOf(result))) {
        .noreturn => {},
        .void => exit_fn(0),
        .int => |int| {
            if (int.signedness) @compileError(bad_fn_ret);
            exit_fn(@truncate(result));
        },
        .error_union => {
            const inner = result catch |err|
                abi.unilog("error: {s}\n", .{@errorName(err)});
            handleExitResult(exit_fn, inner);
        },
        else => @compileError(bad_fn_ret),
    }
}
