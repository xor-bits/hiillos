const abi = @import("abi");
const std = @import("std");

const apic = @import("apic.zig");
const arch = @import("arch.zig");
const fb = @import("fb.zig");
const lazy = @import("lazy.zig");
const main = @import("main.zig");
const pmem = @import("pmem.zig");
const uart = @import("uart.zig");

const conf = abi.conf;

//

pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = .debug,
};

//

pub fn print(
    comptime force_uart: bool,
    comptime force_fb: bool,
    comptime fmt: []const u8,
    args: anytype,
) void {
    log_lock.lock();
    defer log_lock.unlock();

    printLocked(force_uart, force_fb, fmt, args);
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    @branchHint(.cold);

    // kill other CPUs too
    for (0..255) |i| {
        apic.interProcessorInterrupt(@truncate(i), apic.IRQ_IPI_PANIC);
    }

    // fill with red
    if (conf.KERNEL_PANIC_RSOD)
        fb.clear();

    // TODO: maybe `std.debug.Dwarf.ElfModule` contains everything?

    var iter = std.debug.StackIterator.init(
        @returnAddress(),
        @frameAddress(),
    );
    abi.debug.printPanic(
        pmem.page_allocator,
        panic_printer,
        "kernel",
        msg,
        &iter,
        getSelfDwarf(),
        &source_files,
    ) catch {};

    panic_printer.writeAll("\n") catch {};
    arch.hcf();
}

pub const Addr2Line = struct {
    addr: usize,

    pub fn format(self: Addr2Line, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        var dwarf = getSelfDwarf() catch |err| {
            try std.fmt.format(writer, "failed to open DWARF info: {}\n", .{err});
            return;
        };
        defer dwarf.deinit(pmem.page_allocator);
        try abi.debug.printSourceAtAddress(
            pmem.page_allocator,
            writer,
            &dwarf,
            self.addr,
            &source_files,
        );
    }
};

//

fn printLocked(
    comptime force_uart: bool,
    comptime force_fb: bool,
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (abi.conf.ENABLE_UART_LOG or force_uart)
        uart.print(fmt, args);
    if (abi.conf.ENABLE_FB_LOG or force_fb)
        fb.print(fmt, args);
}

fn logFn(comptime message_level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    const level_txt = comptime message_level.asText();
    const scope_txt = if (scope == .default) "" else " " ++ @tagName(scope);
    const level_col = comptime switch (message_level) {
        .debug => "\x1B[96m",
        .info => "\x1B[92m",
        .warn => "\x1B[93m",
        .err => "\x1B[91m",
    };

    log_lock.lock();
    defer log_lock.unlock();

    if (arch.cpuIdSafe()) |id| {
        printLocked(
            false,
            conf.KERNEL_PANIC_RSOD and scope == .panic,
            "\x1B[90m[ " ++ level_col ++ level_txt ++ "\x1B[90m" ++ scope_txt ++ " #{} ]: \x1B[0m",
            .{id},
        );
        printLocked(
            false,
            conf.KERNEL_PANIC_RSOD and scope == .panic,
            format ++ "\n",
            args,
        );
    } else {
        printLocked(
            false,
            conf.KERNEL_PANIC_RSOD and scope == .panic,
            "\x1B[90m[ " ++ level_col ++ level_txt ++ "\x1B[90m" ++ scope_txt ++ " #? ]: \x1B[0m" ++ format ++ "\n",
            args,
        );
    }
}

var log_lock: abi.lock.SpinMutex = .{};

const panic_printer = struct {
    pub const Error = error{};

    pub fn writeAll(_: @This(), lit: []const u8) Error!void {
        log_lock.lock();
        defer log_lock.unlock();
        uart.print("{s}", .{lit});
        if (conf.KERNEL_PANIC_RSOD)
            fb.print("{s}", .{lit});
    }

    pub fn writeBytesNTimes(self: @This(), bytes: []const u8, n: usize) Error!void {
        for (0..n) |_| {
            try self.writeAll(bytes);
        }
    }

    pub fn print(self: @This(), comptime fmt: []const u8, args: anytype) Error!void {
        try std.fmt.format(self, fmt, args);
    }
}{};

const sources = @import("sources");
const source_files: [sources.sources.len]abi.debug.SourceFile = b: {
    var files: [sources.sources.len]abi.debug.SourceFile = undefined;
    for (sources.sources, 0..) |path, i| {
        // opening from here because @embedFile would not
        // work in 'sources.zig', because it doesn't have access
        files[i] = open(path);
    }
    break :b files;
};

fn open(comptime path: []const u8) abi.debug.SourceFile {
    return .{
        .path = path,
        .contents = @embedFile(path),
    };
}

fn getSelfDwarf() !std.debug.Dwarf {
    const kernel_file = @import("args.zig").kernel_file.response orelse return error.NoKernelFile;
    const elf_bin = kernel_file.kernel_file.data();

    return try abi.debug.getSelfDwarf(pmem.page_allocator, elf_bin);
}
