const std = @import("std");
const root = @import("root");
const builtin = @import("builtin");

const abi = @import("lib.zig");
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

/// init for normal processes
pub fn init() !void {
    try @import("caps.zig").init();
    try @import("io.zig").init();
    try @import("process.zig").init();

    try caps.Thread.main.threadSetSigHandler(@intFromPtr(&defaultSignalHandler));
}

/// init for normal processes
pub fn initServer() !void {
    try @import("caps.zig").init();

    try caps.Thread.main.threadSetSigHandler(@intFromPtr(&defaultSignalHandler));
}

pub const SignalRegs = extern struct {
    r15: u64 = 0,
    r14: u64 = 0,
    r13: u64 = 0,
    r12: u64 = 0,
    r11: u64 = 0,
    r10: u64 = 0,
    r9: u64 = 0,
    r8: u64 = 0,
    rbp: u64 = 0,
    rsi: u64 = 0,
    rdx: u64 = 0,
    rcx: u64 = 0,
    rbx: u64 = 0,
    rax: u64 = 0,
    return_addr: u64 = 0,
};

pub fn defaultSignalHandler() callconv(.naked) noreturn {
    asm volatile (
        \\ subq $128, %rsp
        \\ pushq $0
        \\ pushq %rax
        \\ pushq %rbx
        \\ pushq %rcx
        \\ pushq %rdx
        \\ pushq %rdi
        \\ pushq %rsi
        \\ pushq %rbp
        \\ movq %rsp, %rbp
        \\ pushq %r8
        \\ pushq %r9
        \\ pushq %r10
        \\ pushq %r11
        \\ pushq %r12
        \\ pushq %r13
        \\ pushq %r14
        \\ pushq %r15
        \\
        \\ movq %rsp, %rdi
        \\ movq %rsp, %r12
        \\ andq $0xFFFFFFFFFFFFFFF0, %rsp
        // \\ subq $8, %rsp
        \\ call %[f:P]
        \\ movq %r12, %rsp
        \\
        \\ popq %r15
        \\ popq %r14
        \\ popq %r13
        \\ popq %r12
        \\ popq %r11
        \\ popq %r10
        \\ popq %r9
        \\ popq %r8
        \\ popq %rbp
        \\ popq %rsi
        \\ popq %rdi
        \\ popq %rdx
        \\ popq %rcx
        \\ popq %rbx
        \\ addq $136, %rsp
        \\ jmpq *-128(%rsp)
        \\ 
        :
        : [f] "X" (&signalHandlerWrapper),
    );
}

fn signalHandlerWrapper(regs: *SignalRegs) callconv(.c) void {
    const signal = sys.selfGetSignal() catch unreachable;
    regs.return_addr = signal.ip;

    std.debug.panic("Segmentation fault at addres: 0x{x} caused by {}", .{
        signal.target_addr,
        signal.caused_by,
    });
}

fn _start() callconv(.c) noreturn {
    thread.callFn(root.main, .process, .{});
}
