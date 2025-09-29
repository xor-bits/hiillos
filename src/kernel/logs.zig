const abi = @import("abi");
const std = @import("std");

const apic = @import("apic.zig");
const arch = @import("arch.zig");
const boot = @import("boot.zig");
const fb = @import("fb.zig");
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
    comptime force_fb: bool,
    comptime fmt: []const u8,
    args: anytype,
) void {
    log_lock.lock();
    defer log_lock.unlock();

    printLocked(force_fb, fmt, args);
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    @branchHint(.cold);

    std.log.scoped(.logs).err("kernel panic: {s}", .{
        msg,
    });

    // kill other CPUs too
    for (0..255) |i| {
        apic.interProcessorInterrupt(@truncate(i), apic.IRQ_IPI_PANIC);
    }

    // fill with red
    if (conf.KERNEL_PANIC_RSOD)
        fb.clear();

    // TODO: maybe `std.debug.Dwarf.ElfModule` contains everything?

    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer{
        .vtable = &.{
            .drain = panic_printer_drain,
        },
        .buffer = &buffer,
    };

    var iter = std.debug.StackIterator.init(
        @returnAddress(),
        @frameAddress(),
    );
    abi.debug.printPanic(
        pmem.page_allocator,
        &writer,
        "kernel",
        msg,
        &iter,
        getSelfDwarf(),
        &source_files,
    ) catch {};

    writer.writeAll("\n") catch {};
    arch.hcf();
}

pub const Addr2Line = struct {
    addr: usize,

    pub fn format(self: Addr2Line, writer: *std.Io.Writer) !void {
        var dwarf = getSelfDwarf() catch |err| {
            try writer.print("failed to open DWARF info: {}\n", .{err});
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
    comptime force_fb: bool,
    comptime fmt: []const u8,
    args: anytype,
) void {
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

    const force_fb = conf.KERNEL_PANIC_RSOD and scope == .panic;

    if (arch.cpuIdSafe()) |id| {
        printLocked(
            force_fb,
            "\x1B[90m[ " ++ level_col ++ level_txt ++ "\x1B[90m" ++ scope_txt ++ " #{} ]: \x1B[0m",
            .{id},
        );
        printLocked(
            force_fb,
            format ++ "\n",
            args,
        );
    } else {
        printLocked(
            force_fb,
            "\x1B[90m[ " ++ level_col ++ level_txt ++ "\x1B[90m" ++ scope_txt ++ " #? ]: \x1B[0m" ++ format ++ "\n",
            args,
        );
    }
}

var log_lock: abi.lock.SpinMutex = .{};
fn panic_printer_drain(
    w: *std.Io.Writer,
    data: []const []const u8,
    splat: usize,
) error{WriteFailed}!usize {
    log_lock.lock();
    defer log_lock.unlock();

    print_to_uart_and_fb("{s}", .{w.buffer[0..w.end]});
    w.end = 0;

    const pattern = data[data.len - 1];
    var n: usize = 0;

    for (data[0 .. data.len - 1]) |bytes| {
        print_to_uart_and_fb("{s}", .{bytes});
        n += bytes.len;
    }
    for (0..splat) |_| {
        print_to_uart_and_fb("{s}", .{pattern});
    }
    return n + splat * pattern.len;
}
fn print_to_uart_and_fb(comptime fmt: []const u8, args: anytype) void {
    uart.print(fmt, args);
    if (conf.KERNEL_PANIC_RSOD)
        fb.print(fmt, args);
}

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
    const kernel_file = boot.kernel_file.response orelse return error.NoKernelFile;
    const elf_bin = kernel_file.executable_file.data();

    return try abi.debug.getSelfDwarf(pmem.page_allocator, elf_bin);
}
