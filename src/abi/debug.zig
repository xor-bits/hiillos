const std = @import("std");

const caps = @import("caps.zig");
const fs = @import("fs.zig");
const lock = @import("lock.zig");
const mem = @import("mem.zig");
const sys = @import("sys.zig");
const thread = @import("thread.zig");

//

pub fn getDebugInfoAllocator() std.mem.Allocator {
    return mem.server_page_allocator;
}

pub const SelfInfo = struct {
    pub const init: SelfInfo = .{};
    pub const can_unwind = false;
    pub const UnwindContext = struct {
        // pub fn init(p: anytype) @This() {
        //     return .{};
        // }
    };

    // debug_info.getSymbols(
    //     io,
    //     symbol_allocator,
    //     text_arena.allocator(),
    //     options.address,
    //     options.resolve_inline_callers,
    //     &symbols,
    // ) catch |err| {

    pub fn getModuleName(
        _: *const SelfInfo,
        _: std.Io,
        address: usize,
    ) error{Unsupported}![]const u8 {
        _ = address;
        // std.debug;
        return error.Unsupported;
    }

    pub fn getSymbols(
        _: *const SelfInfo,
        _: std.Io,
        symbol_allocator: std.mem.Allocator,
        text_arena: std.mem.Allocator,
        address: usize,
        resolve_inline_callers: bool,
        symbols: *std.ArrayList(std.debug.Symbol),
    ) std.debug.SelfInfoError!void {
        self_dwarf_lock.lock();
        defer self_dwarf_lock.unlock();
        const di = try load();

        try di.getSymbols(
            symbol_allocator,
            text_arena,
            .native,
            address,
            resolve_inline_callers,
            symbols,
        );
    }

    var once: lock.Once(thread.Mutex) = .{};
    var self_dwarf: error{ReadFailed}!std.debug.Dwarf = undefined;
    var self_dwarf_lock: lock.Futex = .unlocked;

    fn load() error{ReadFailed}!*std.debug.Dwarf {
        if (once.tryRun()) {
            defer once.complete();
            self_dwarf = trySelfDwarf() catch error.ReadFailed;
        } else {
            once.wait();
        }

        return &try self_dwarf;
    }

    fn trySelfDwarf() anyerror!std.debug.Dwarf {
        const elf_bin = try tryLoadSelfExe();
        return getSelfDwarf(mem.slab_allocator, elf_bin);
    }

    fn tryLoadSelfExe() anyerror![]const u8 {
        if (@hasDecl(@import("root"), "manifest"))
            return error.NotFound;

        const vmem = caps.Vmem.self;

        const frame = try fs.openSelfExe();
        const size = try frame.getSize();

        const addr = try vmem.map(
            frame,
            0,
            0,
            size,
            .{},
        );

        return @as([*]const u8, @ptrFromInt(addr))[0..size];
    }
};

pub fn printPanic(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    name: []const u8,
    msg: []const u8,
    iter: *std.debug.StackIterator,
    dwarf_info: anyerror!std.debug.Dwarf,
    sources: []const SourceFile,
) !void {
    try writer.print("{s} panicked: {s}\nstack trace:\n", .{ name, msg });

    var dwarf = dwarf_info catch |err| {
        try writer.print("failed to open DWARF info: {}\n", .{err});
        while (iter.next()) |r_addr| {
            try writer.print("  \x1B[90m0x{x:0>16}\x1B[0m\n", .{r_addr});
        }
        return;
    };
    defer dwarf.deinit(allocator);

    while (iter.next()) |r_addr| {
        try printSourceAtAddress(
            allocator,
            writer,
            &dwarf,
            r_addr,
            sources,
        );
    }
}

pub fn printSourceAtAddress(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    debug_info: *std.debug.Dwarf,
    address: usize,
    sources: []const SourceFile,
) !void {
    const sym = debug_info.getSymbol(allocator, address) catch {
        try writer.print("\x1B[90m0x{x}\x1B[0m\n", .{address});
        return;
    };
    defer if (sym.source_location) |loc| allocator.free(loc.file_name);

    try writer.print("\x1B[1m", .{});

    if (sym.source_location) |*sl| {
        try writer.print(
            "{s}:{d}:{d}",
            .{ sl.file_name, sl.line, sl.column },
        );
    } else {
        try writer.print("???:?:?", .{});
    }

    try writer.print(
        "\x1B[0m: \x1B[90m0x{x} in {s} ({s})\x1B[0m\n",
        .{ address, sym.name, sym.compile_unit_name },
    );

    // std.debug.printSourceAtAddress(debug_info: *SelfInfo, out_stream: anytype, address: usize, tty_config: io.tty.Config)

    const loc = sym.source_location orelse return;
    const source_file = findSourceFile(loc.file_name, sources) orelse return;

    var source_line: []const u8 = "<out-of-bounds>";
    var lines_iter = std.mem.splitScalar(u8, source_file.contents, '\n');
    for (0..loc.line) |_| {
        source_line = lines_iter.next() orelse "<out-of-bounds>";
    }

    try writer.print("{s}\n", .{source_line});

    const space_needed = @as(usize, @intCast(@max(loc.column, 1) - 1));

    try writer.splatBytesAll(" ", space_needed);
    try writer.writeAll("\x1B[92m^\x1B[0m\n");
}

pub fn findSourceFile(
    path: []const u8,
    sources: []const SourceFile,
) ?SourceFile {
    for_loop: for (sources) |s| {
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

pub const SourceFile = struct {
    path: []const u8,
    contents: []const u8,
};

pub fn getSelfDwarf(
    allocator: std.mem.Allocator,
    elf_bin: []const u8,
) !std.debug.Dwarf {
    var elf = std.Io.Reader.fixed(elf_bin);

    const header = try std.elf.Header.read(&elf);

    var sections: std.debug.Dwarf.SectionArray = @splat(null);

    for (sectionsHeaders(elf_bin, header)) |shdr| {
        const name = getString(elf_bin, header, shdr.sh_name);
        if (name.len == 0) continue;
        // std.log.info("shdr: {s}", .{name});

        inline for (comptime std.enums.values(std.debug.Dwarf.Section.Id)) |sect_id| {
            if (std.mem.eql(u8, name[1..], @tagName(sect_id))) {
                sections[@intFromEnum(sect_id)] = .{
                    .data = getSectionData(elf_bin, shdr),
                    .owned = false,
                };
            }
        }
    }

    var dwarf: std.debug.Dwarf = .{ .sections = sections };
    try dwarf.open(allocator, .native);
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
    const section_headers: [*]const std.elf.Elf64_Shdr = @ptrCast(@alignCast(bin.ptr + header.shoff));
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
