const abi = @import("abi");
const std = @import("std");
const sources = @import("sources");

const apic = @import("apic.zig");
const arch = @import("arch.zig");
const fb = @import("fb.zig");
const lazy = @import("lazy.zig");
const main = @import("main.zig");
const pmem = @import("pmem.zig");
const spin = @import("spin.zig");
const uart = @import("uart.zig");

const conf = abi.conf;

//

pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = .debug,
};

//

pub fn init() !void {
    if (!conf.DWARF_INFO_EARLY_INIT) return;

    _ = try getSelfDwarf();
}

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
    const log = std.log.scoped(.panic);

    // kill other CPUs too
    for (0..255) |i| {
        apic.interProcessorInterrupt(@truncate(i), apic.IRQ_IPI_PANIC);
    }

    // fill with red
    if (conf.KERNEL_PANIC_RSOD)
        fb.clear();

    // TODO: maybe `std.debug.Dwarf.ElfModule` contains everything?

    log.err("kernel panic: {s}", .{msg});

    dwarf_info_lock.lock();
    defer dwarf_info_lock.unlock();

    var iter = std.debug.StackIterator.init(@returnAddress(), @frameAddress());
    if (getSelfDwarf()) |dwarf| {
        while (iter.next()) |r_addr| {
            printSourceAtAddress(panic_printer, dwarf, r_addr) catch {};
        }
    } else |err| {
        log.err("failed to open DWARF info: {}", .{err});

        while (iter.next()) |r_addr| {
            std.fmt.format(panic_printer, "  \x1B[90m0x{x:0>16}\x1B[0m\n", .{r_addr}) catch {};
        }
    }

    std.fmt.format(panic_printer, "\n", .{}) catch {};

    arch.hcf();
}

pub const Addr2Line = struct {
    addr: usize,

    pub fn format(self: Addr2Line, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        if (!conf.DWARF_INFO_EARLY_INIT) return;

        dwarf_info_lock.lock();
        defer dwarf_info_lock.unlock();

        if (getSelfDwarf()) |dwarf| {
            try printSourceAtAddress(writer, dwarf, self.addr);
        } else |err| {
            try std.fmt.format(writer, "failed to open DWARF info: {}\n", .{err});
        }
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

var log_lock: spin.Mutex = .{};

const panic_printer = struct {
    pub const Error = error{};

    pub fn writeAll(_: *const @This(), lit: []const u8) Error!void {
        log_lock.lock();
        defer log_lock.unlock();
        uart.print("{s}", .{lit});
        if (conf.KERNEL_PANIC_RSOD)
            fb.print("{s}", .{lit});
    }

    pub fn writeBytesNTimes(self: *const @This(), bytes: []const u8, n: usize) Error!void {
        for (0..n) |_| {
            try self.writeAll(bytes);
        }
    }
}{};

fn printSourceAtAddress(writer: anytype, debug_info: *std.debug.Dwarf, address: usize) !void {
    const sym = debug_info.getSymbol(pmem.page_allocator, address) catch {
        try std.fmt.format(writer, "\x1B[90m0x{x}\x1B[0m\n", .{address});
        return;
    };
    defer if (sym.source_location) |loc| pmem.page_allocator.free(loc.file_name);

    try std.fmt.format(writer, "\x1B[1m", .{});

    if (sym.source_location) |*sl| {
        try std.fmt.format(
            writer,
            "{s}:{d}:{d}",
            .{ sl.file_name, sl.line, sl.column },
        );
    } else {
        try std.fmt.format(writer, "???:?:?", .{});
    }

    try std.fmt.format(
        writer,
        "\x1B[0m: \x1B[90m0x{x} in {s} ({s})\x1B[0m\n",
        .{ address, sym.name, sym.compile_unit_name },
    );

    // std.debug.printSourceAtAddress(debug_info: *SelfInfo, out_stream: anytype, address: usize, tty_config: io.tty.Config)

    const loc = sym.source_location orelse return;
    const source_file = findSourceFile(loc.file_name) orelse return;

    var source_line: []const u8 = "<out-of-bounds>";
    var lines_iter = std.mem.splitScalar(u8, source_file.contents, '\n');
    for (0..loc.line) |_| {
        source_line = lines_iter.next() orelse "<out-of-bounds>";
    }

    try std.fmt.format(writer, "{s}\n", .{source_line});

    const space_needed = @as(usize, @intCast(@max(loc.column, 1) - 1));

    try writer.writeBytesNTimes(" ", space_needed);
    try writer.writeAll("\x1B[92m^\x1B[0m\n");
}

fn findSourceFile(path: []const u8) ?SourceFile {
    if (!conf.KERNEL_PANIC_SOURCE_INFO)
        return null;

    for_loop: for (source_files) |s| {
        // b path is a full absolute path,
        // while a is relative to the git repo

        var a = std.fs.path.componentIterator(s.path) catch
            continue;
        var b = std.fs.path.componentIterator(path) catch
            continue;

        const a_last = a.last() orelse continue;
        const b_last = b.last() orelse continue;

        if (!std.mem.eql(u8, a_last.name, b_last.name)) continue;

        while (a.previous()) |a_part| {
            const b_part = b.previous() orelse continue :for_loop;
            if (!std.mem.eql(u8, a_part.name, b_part.name)) continue :for_loop;
        }

        return s;
    }

    return null;
}

const SourceFile = struct {
    path: []const u8,
    contents: []const u8,

    fn open(comptime path: []const u8) SourceFile {
        return .{
            .path = path,
            .contents = @embedFile(path),
        };
    }
};

const source_files: [sources.sources.len]SourceFile = b: {
    var files: [sources.sources.len]SourceFile = undefined;
    for (sources.sources, 0..) |path, i| {
        // opening from here because @embedFile would not
        // work in 'sources.zig', because it doesn't have access
        files[i] = .open(path);
    }
    break :b files;
};

var dwarf_info: ?anyerror!std.debug.Dwarf = null;
var dwarf_info_lock: spin.Mutex = .{};

/// `dwarf_info_lock` needs to be held
fn getSelfDwarf() !*std.debug.Dwarf {
    return &(try (dwarf_info orelse {
        dwarf_info = openSelfDwarf();
        return &(try (dwarf_info.?));
    }));
}

fn openSelfDwarf() !std.debug.Dwarf {
    if (!conf.STACK_TRACE) return error.StackTracesDisabled;

    const kernel_file = @import("args.zig").kernel_file.response orelse return error.NoKernelFile;
    const elf_bin = kernel_file.kernel_file.data();
    var elf = std.io.fixedBufferStream(elf_bin);

    const header = try std.elf.Header.read(&elf);

    var sections = std.debug.Dwarf.null_section_array;

    for (sectionsHeaders(elf_bin, header)) |shdr| {
        const name = getString(elf_bin, header, shdr.sh_name);
        // std.log.info("shdr: {s}", .{name});

        if (std.mem.eql(u8, name, ".debug_info")) {
            sections[@intFromEnum(std.debug.Dwarf.Section.Id.debug_info)] = .{
                .data = getSectionData(elf_bin, shdr),
                .owned = false,
            };
        } else if (std.mem.eql(u8, name, ".debug_abbrev")) {
            sections[@intFromEnum(std.debug.Dwarf.Section.Id.debug_abbrev)] = .{
                .data = getSectionData(elf_bin, shdr),
                .owned = false,
            };
        } else if (std.mem.eql(u8, name, ".debug_str")) {
            sections[@intFromEnum(std.debug.Dwarf.Section.Id.debug_str)] = .{
                .data = getSectionData(elf_bin, shdr),
                .owned = false,
            };
        } else if (std.mem.eql(u8, name, ".debug_line")) {
            sections[@intFromEnum(std.debug.Dwarf.Section.Id.debug_line)] = .{
                .data = getSectionData(elf_bin, shdr),
                .owned = false,
            };
        } else if (std.mem.eql(u8, name, ".debug_ranges")) {
            sections[@intFromEnum(std.debug.Dwarf.Section.Id.debug_ranges)] = .{
                .data = getSectionData(elf_bin, shdr),
                .owned = false,
            };
        } else if (std.mem.eql(u8, name, ".eh_frame")) {
            sections[@intFromEnum(std.debug.Dwarf.Section.Id.eh_frame)] = .{
                .data = getSectionData(elf_bin, shdr),
                .owned = false,
            };
        } else if (std.mem.eql(u8, name, ".eh_frame_hdr")) {
            sections[@intFromEnum(std.debug.Dwarf.Section.Id.eh_frame_hdr)] = .{
                .data = getSectionData(elf_bin, shdr),
                .owned = false,
            };
        }
    }

    var dwarf: std.debug.Dwarf = .{
        .endian = .little,
        .sections = sections,
        .is_macho = false,
    };

    try dwarf.open(pmem.page_allocator);

    return dwarf;
}

fn getString(bin: []const u8, header: std.elf.Header, off: u32) []const u8 {
    const strtab = getSectionData(
        bin,
        sectionsHeaders(bin, header)[header.shstrndx],
    );
    return std.mem.sliceTo(@as([*:0]const u8, @ptrCast(strtab.ptr + off)), 0);
}

fn getSectionData(bin: []const u8, shdr: std.elf.Elf64_Shdr) []const u8 {
    return bin[shdr.sh_offset..][0..shdr.sh_size];
}

fn sectionsHeaders(bin: []const u8, header: std.elf.Header) []const std.elf.Elf64_Shdr {
    // FIXME: bounds checking maybe
    const section_headers: [*]const std.elf.Elf64_Shdr = @alignCast(@ptrCast(bin.ptr + header.shoff));
    return section_headers[0..header.shnum];
}

fn sectionFromSym(start: *const u8, end: *const u8) std.debug.Dwarf.Section {
    const size = @intFromPtr(end) - @intFromPtr(start);
    const addr = @as([*]const u8, @ptrCast(start));
    return .{
        .data = addr[0..size],
        .owned = false,
    };
}
