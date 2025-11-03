const std = @import("std");

//

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);
    if (args.len != 2) return error.@"missing output file argument";

    var output_file = try std.fs.cwd().createFile(args[1], .{});
    defer output_file.close();

    var buffer: [0x2000]u8 = undefined;

    var output_writer = output_file.writer(&buffer);
    const output = &output_writer.interface;
    defer output.flush() catch unreachable;

    // std.fmt.format(, , )
    try output.writeAll(
        \\pub fn invokeSyscall(
        \\    comptime ic: usize,
        \\    comptime oc: usize,
        \\    id: usize,
        \\    in: *const [ic]usize,
        \\    out: *[oc]usize,
        \\) usize {
        \\
    );

    const x86_64_syscall_args_regs: [6][]const u8 = .{
        "rdi",
        "rsi",
        "rdx",
        "r8",
        "r9",
        "r10",
    };

    for (0..7) |ic| for (0..7) |oc| {
        try output.print(
            \\    if (ic == {[ic]} and oc == {[oc]}) {{
            \\
        , .{ .ic = ic, .oc = oc });

        for (0..oc) |i| {
            try output.print(
                \\        // zig cant output from asm to arbitrary places
                \\        var _out{}: usize = undefined;
                \\
            , .{i});
        }

        try output.writeAll(
            \\        const res = asm volatile ("syscall"
            \\            : [ret] "={rax}" (-> usize),
            \\
        );

        for (0..oc) |i| {
            try output.print(
                \\              [out{[i]}] "={{{[reg]s}}}" (_out{[i]}),
                \\
            , .{ .i = i, .reg = x86_64_syscall_args_regs[i] });
        }

        try output.writeAll(
            \\            : [id] "{rax}" (id),
            \\
        );

        for (0..ic) |i| {
            try output.print(
                \\              [in{[i]}] "{{{[reg]s}}}" (in[{[i]}]),
                \\
            , .{ .i = i, .reg = x86_64_syscall_args_regs[i] });
        }

        try output.writeAll(
            \\            : .{ .rcx = true, .r11 = true, .memory = true } // rcx becomes rip and r11 becomes rflags
            \\        );
            \\
        );

        for (0..oc) |i| {
            try output.print(
                \\        // zig cant output from asm to arbitrary places
                \\        out[{[i]}] = _out{[i]};
                \\
            , .{ .i = i });
        }

        try output.writeAll(
            \\        return res;
            \\    }
            \\
        );
    };

    try output.writeAll(
        \\    unreachable;
        \\}
        \\
    );
}
