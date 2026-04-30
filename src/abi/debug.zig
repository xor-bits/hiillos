const std = @import("std");

const abi = @import("lib.zig");
const caps = @import("caps.zig");
const fs = @import("fs.zig");
const lock = @import("lock.zig");
const mem = @import("mem.zig");
const process = @import("process.zig");
const sys = @import("sys.zig");
const thread = @import("thread.zig");

//

pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);

    // const name = if (@hasDecl(root, "manifest"))
    //     root.manifest.getName()
    // else
    //     "<unknown>";

    var buffer: [256]u8 = undefined;
    var log = abi.UnifiedLog.init(&buffer);
    const writer = &log.interface;
    const terminal: std.Io.Terminal = .{
        .writer = writer,
        .mode = .escape_codes,
    };

    tryPrintPanic(
        terminal,
        msg,
        first_trace_addr,
    ) catch {};
    terminal.writer.writeAll("\ndone\n") catch {};

    process.exit(1);
}

pub inline fn tryPrintPanic(
    terminal: std.Io.Terminal,
    msg: []const u8,
    first_trace_addr: ?usize,
) !void {
    const writer = terminal.writer;

    try writer.print("panic: {s}\n", .{msg});
    try writer.flush();

    if (@errorReturnTrace()) |err_trace| if (err_trace.index > 0) {
        try writer.writeAll("error return context:\n");
        try std.debug.writeErrorReturnTrace(err_trace, terminal);
        try writer.flush();

        try writer.writeAll("\nstack trace:\n");
    };

    try std.debug.writeCurrentStackTrace(.{
        .first_address = first_trace_addr orelse @returnAddress(),
        .allow_unsafe_unwind = true,
    }, terminal);
    try writer.flush();
}

pub fn getDebugInfoAllocator() std.mem.Allocator {
    return mem.server_page_allocator;
}

pub fn printLineFromFile(_: std.Io, _: *std.Io.Writer, _: std.debug.SourceLocation) !void {
    return error.Unsupported;
}

pub const SelfInfo = struct {
    pub const init: SelfInfo = .{};
    pub const can_unwind = false;
    pub const UnwindContext = std.debug.Dwarf.SelfUnwinder;

    // lock: lock.SpinMutex = .locked,

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
        _: usize,
    ) error{Unsupported}![]const u8 {
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
    var self_elf: error{ReadFailed}![]const u8 = undefined;
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
        self_elf = tryLoadSelfExe() catch error.ReadFailed;
        return getSelfDwarf(mem.slab_allocator, try self_elf);
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

pub fn findSourceFile(
    path: []const u8,
    sources: []const SourceFile,
) ?SourceFile {
    for_loop: for (sources) |s| {
        // b path is a full absolute path,
        // while a is relative to the git repo

        var a = std.fs.path.componentIterator(s.path);
        var b = std.fs.path.componentIterator(path);

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
