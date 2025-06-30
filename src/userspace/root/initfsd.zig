const std = @import("std");
const abi = @import("abi");

const main = @import("main.zig");

const log = std.log.scoped(.initfsd);
const caps = abi.caps;
const Error = abi.sys.Error;

//

// TODO: resizeable Frame
// TODO: move to abi.mem and add exponential growth
const vmm_vector = std.mem.Allocator{
    .ptr = &vmm_vector_top,
    .vtable = &.{
        .alloc = vmmVectorAlloc,
        .resize = vmmVectorResize,
        .remap = vmmVectorRemap,
        .free = vmmVectorFree,
    },
};

var vmm_vector_top: usize = 0x5000_0000_0000;

fn vmmVectorAlloc(_top: *anyopaque, len: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
    const top: *usize = @alignCast(@ptrCast(_top));
    const ptr: [*]u8 = @ptrFromInt(top.*);
    vmmVectorGrow(top, std.math.divCeil(
        usize,
        len,
        0x10000,
    ) catch return null) catch return null;
    return ptr;
}

fn vmmVectorResize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
    return false;
}

fn vmmVectorRemap(_top: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
    const top: *usize = @alignCast(@ptrCast(_top));
    const current_len = top.* - 0x5000_0000_0000;
    if (current_len < new_len) {
        vmmVectorGrow(top, std.math.divCeil(
            usize,
            new_len - current_len,
            0x10000,
        ) catch return null) catch return null;
    }

    return memory.ptr;
}

fn vmmVectorFree(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {}

fn vmmVectorGrow(top: *usize, n_pages: usize) !void {
    for (0..n_pages) |_| {
        const frame = try caps.Frame.create(0x10000);
        defer frame.close();
        _ = try caps.ROOT_SELF_VMEM.map(
            frame,
            0,
            top.*,
            0x10000,
            .{ .writable = true },
            .{ .fixed = true },
        );
        top.* += 0x10000;
    }
}

var initfs_tar: std.ArrayList(u8) = .init(vmm_vector);

//

pub fn init() !void {
    @atomicStore(u32, &initfs_ready.cap, (try caps.Notify.create()).cap, .seq_cst);

    log.info("starting initfs thread", .{});
    try abi.thread.spawnOptions(run, .{}, .{ .stack_size = 1024 * 1024 });
    log.info("yielding", .{});
    abi.sys.selfYield();
}

pub fn wait() !void {
    initfs_ready.wait();
}

pub fn getReceiver() !caps.Receiver {
    return try initfs_recv.clone();
}

pub fn getBootInfoAddr() *const volatile abi.BootInfo {
    return @ptrFromInt(boot_info_addr.load(.monotonic));
}

var initfs_ready: caps.Notify = .{};
var initfs_recv: caps.Receiver = .{};
pub var boot_info_addr: std.atomic.Value(usize) = .init(0);

fn run() !void {
    log.info("mapping boot info", .{});
    boot_info_addr.store(try abi.caps.ROOT_SELF_VMEM.map(
        abi.caps.ROOT_BOOT_INFO,
        0,
        0,
        0,
        .{},
        .{},
    ), .release);

    @atomicStore(
        u32,
        &initfs_recv.cap,
        (try caps.Receiver.create()).cap,
        .release,
    );

    log.info("decompressing", .{});
    try decompress();

    _ = initfs_ready.notify();

    log.info("initfs ready", .{});
    var server = abi.FsProtocol.Server(.{
        .scope = if (abi.conf.LOG_SERVERS) .initfs else null,
    }, .{
        .openFile = openFileHandler,
        .openDir = openDirHandler,
        .root = rootHandler,
    }).init({}, initfs_recv);
    try server.run();
}

fn decompress() !void {
    const initfs: []const u8 = getBootInfoAddr().initfsData();
    var initfs_tar_zst = std.io.fixedBufferStream(initfs);

    const buf = try abi.mem.server_page_allocator.alloc(
        u8,
        std.compress.zstd.DecompressorOptions.default_window_buffer_len,
    );
    defer abi.mem.server_page_allocator.free(buf);

    var zstd_decompressor = std.compress.zstd.decompressor(
        initfs_tar_zst.reader(),
        .{ .window_buffer = buf },
    );
    try zstd_decompressor.reader().readAllArrayList(
        &initfs_tar,
        0x2000_0000_0000,
    );
    // try std.compress.flate.inflate.decompress(.gzip, initfs_tar_gz.reader(), initfs_tar.writer(),);
    std.debug.assert(std.mem.eql(u8, initfs_tar.items[257..][0..8], "ustar\x20\x20\x00"));
    log.info("decompressed initfs size: 0x{x}", .{initfs_tar.items.len});
}

fn openFileHandler(_: void, _: u32, req: struct { u128 }) struct { Error!void, caps.Frame } {
    const frame = openFileHandlerInner(req.@"0") catch |err|
        return .{ err, .{} };

    return .{ {}, frame };
}

fn openFileHandlerInner(inode: u128) Error!caps.Frame {
    const file: []const u8 = readFile(@truncate(inode));

    const frame = try caps.Frame.create(file.len);
    errdefer frame.close();

    try frame.write(0, file);
    return frame;
}

fn openDirHandler(_: void, _: u32, req: struct { u128 }) struct { Error!void, caps.Frame, usize } {
    const dir = readHeader(@truncate(req.@"0"));
    const path: []const u8 = std.mem.sliceTo(&dir.name, 0);

    const frame, const count = openDirHandlerInner(path) catch |err|
        return .{ err, .{}, 0 };

    return .{ {}, frame, count };
}

fn entryInfo(header: *const TarEntryHeader) ?struct {
    header: *const TarEntryHeader,
    /// full file/dir path
    path: []const u8,
    /// parent dir
    dir: []const u8,
    /// filename/dirname
    name: []const u8,
} {
    if (header.ty != 0 and header.ty != '0' and header.ty != 5 and header.ty != '5')
        return null;

    const path = std.mem.sliceTo(&header.name, 0);
    const dir = std.fs.path.dirname(path) orelse
        return null;
    const name = std.fs.path.basename(path);

    return .{
        .header = header,
        .path = path,
        .dir = dir,
        .name = name,
    };
}

fn openDirHandlerInner(path: []const u8) Error!struct { caps.Frame, usize } {
    var entries: usize = 0;
    var size: usize = 0;

    var it = iterator();
    while (it.next()) |blocks| {
        const entry_info = entryInfo(@ptrCast(&blocks[0])) orelse
            continue;
        if (!abi.fs.path.eql(entry_info.dir, path))
            continue;

        entries += 1;
        size += entry_info.name.len + 1;
    }

    const text_size = size;
    size += @sizeOf(abi.Stat) * entries;

    const frame = caps.Frame.create(size) catch unreachable;

    const tmp_addr = caps.ROOT_SELF_VMEM.map(
        frame,
        0,
        0,
        size,
        .{ .writable = true },
        .{},
    ) catch unreachable;

    const frame_entries = @as([*]abi.Stat, @ptrFromInt(tmp_addr))[0..entries];
    const frame_names = @as([*]u8, @ptrFromInt(tmp_addr + @sizeOf(abi.Stat) * entries))[0..text_size];

    entries = 0;
    size = 0;

    it = iterator();
    while (it.next()) |blocks| {
        const entry_info = entryInfo(@ptrCast(&blocks[0])) orelse
            continue;
        if (!abi.fs.path.eql(entry_info.dir, path))
            continue;

        const file_size = std.fmt.parseInt(usize, std.mem.sliceTo(&entry_info.header.size, 0), 8) catch 0;
        const file_mtime = std.fmt.parseInt(usize, std.mem.sliceTo(&entry_info.header.modified, 0), 8) catch 0;
        const file_mode = std.fmt.parseInt(usize, std.mem.sliceTo(&entry_info.header.mode, 0), 8) catch 0;
        const file_uid = std.fmt.parseInt(usize, std.mem.sliceTo(&entry_info.header.uid, 0), 8) catch 0;
        const file_gid = std.fmt.parseInt(usize, std.mem.sliceTo(&entry_info.header.gid, 0), 8) catch 0;

        var mode: abi.Mode = @bitCast(@as(u32, @truncate(file_mode)));
        mode.set_uid = false;
        mode.set_gid = false;
        mode.type = if (entry_info.header.ty == '5') .dir else .file;
        mode._reserved0 = 0;
        mode._reserved1 = 0;

        @as(*volatile abi.Stat, &frame_entries[entries]).* = .{
            .atime = file_mtime,
            .mtime = file_mtime,
            .inode = inodeOf(entry_info.header),
            .uid = file_uid,
            .gid = file_gid,
            .size = file_size,
            .mode = mode,
        };
        abi.util.copyForwardsVolatile(
            u8,
            frame_names[size..],
            std.mem.sliceTo(entry_info.name, 0),
        );

        entries += 1;
        size += entry_info.name.len + 1;

        @as(*volatile u8, &frame_names[size - 1]).* = 0; // null terminator, should already be there but just making sure
    }

    caps.ROOT_SELF_VMEM.unmap(
        tmp_addr,
        size,
    ) catch unreachable;

    return .{ frame, entries };
}

fn rootHandler(_: void, _: u32, _: void) struct { u128 } {
    // log.info("looking up root", .{});
    const root_inode = openDir("./") orelse unreachable;
    // log.info("root={}", .{root_inode});
    return .{root_inode};
}

pub fn openFile(path: []const u8) ?usize {
    var it = fileIterator();
    while (it.next()) |file| {
        // log.debug("file path={s} inode={}", .{ file.path, file.inode });
        if (!abi.fs.path.eql(path, file.path)) {
            continue;
        }

        return file.inode;
    }

    return null;
}

pub fn openDir(path: []const u8) ?usize {
    var it = dirIterator();
    while (it.next()) |dir| {
        // log.debug("dir path={s} inode={}", .{ dir.path, dir.inode });
        if (!abi.fs.path.eql(path, dir.path)) {
            continue;
        }

        return dir.inode;
    }

    return null;
}

pub const FileIterator = struct {
    inner: Iterator,

    pub fn next(self: *@This()) ?struct { path: []const u8, inode: usize } {
        while (self.inner.next()) |blocks| {
            const header: *const TarEntryHeader = @ptrCast(&blocks[0]);

            // skip non files
            if (header.ty != 0 and header.ty != '0') continue;

            return .{
                .path = std.mem.sliceTo(header.name[0..100], 0),
                .inode = inodeOf(header),
            };
        }

        return null;
    }
};

pub fn fileIterator() FileIterator {
    return .{ .inner = iterator() };
}

pub const DirIterator = struct {
    inner: Iterator,

    pub fn next(self: *@This()) ?struct { path: []const u8, inode: usize } {
        while (self.inner.next()) |blocks| {
            const header: *const TarEntryHeader = @ptrCast(&blocks[0]);

            // skip non dirs
            if (header.ty != '5') continue;

            return .{
                .path = std.mem.sliceTo(header.name[0..100], 0),
                .inode = inodeOf(header),
            };
        }

        return null;
    }
};

pub fn dirIterator() DirIterator {
    return .{ .inner = iterator() };
}

pub fn inodeOf(header: *const TarEntryHeader) usize {
    const header_ptr = @intFromPtr(header);
    const blocks_ptr = @intFromPtr(initfs_tar.items.ptr);
    std.debug.assert(blocks_ptr <= header_ptr);
    std.debug.assert(header_ptr + @sizeOf(TarEntryHeader) <= blocks_ptr + initfs_tar.items.len);
    std.debug.assert((header_ptr - blocks_ptr) % 512 == 0);
    return (header_ptr - blocks_ptr) / 512;
}

pub fn readFile(header_i: usize) []const u8 {
    const size = std.fmt.parseInt(usize, std.mem.sliceTo(
        readHeader(header_i).size[0..12],
        0,
    ), 8) catch 0;
    const size_blocks = if (size % 512 == 0) size / 512 else size / 512 + 1;

    const bytes_blocks = tarBlocks()[header_i + 1 .. header_i + size_blocks + 1];
    const first_byte: [*]const u8 = @ptrCast(bytes_blocks);
    const bytes = first_byte[0..size];

    return bytes;
}

pub fn readHeader(header_i: usize) *const TarEntryHeader {
    return @ptrCast(&tarBlocks()[header_i]);
}

fn tarBlocks() []const [512]u8 {
    const Block = [512]u8;
    const len = initfs_tar.items.len / 512;
    const blocks_ptr: [*]const Block = @ptrCast(initfs_tar.items.ptr);
    return blocks_ptr[0..len];
}

const Iterator = struct {
    blocks: []const [512]u8,
    i: usize,

    pub fn next(self: *@This()) ?[]const [512]u8 {
        while (self.i < self.blocks.len) {
            const header_i = self.i;
            const header: *const TarEntryHeader = @ptrCast(&self.blocks[header_i]);
            const size = std.fmt.parseInt(usize, std.mem.sliceTo(header.size[0..12], 0), 8) catch 0;
            const size_blocks = if (size % 512 == 0) size / 512 else size / 512 + 1;

            self.i += 1; // skip the header
            if (self.i + size_blocks > self.blocks.len) {
                log.err("invalid tar file: unexpected EOF", .{});
                // broken tar file
                return null;
            }

            // skip the file data
            self.i += size_blocks;

            if (header.ty == 0) continue;

            return self.blocks[header_i..][0 .. size_blocks + 1];
        }
        return null;
    }
};

fn iterator() Iterator {
    const len = initfs_tar.items.len / 512;
    const blocks_ptr: [*]const [512]u8 = @ptrCast(initfs_tar.items.ptr);

    return .{
        .blocks = blocks_ptr[0..len],
        .i = 0,
    };
}

const TarEntryHeader = extern struct {
    name: [100]u8 align(1),
    mode: [8]u8 align(1),
    uid: [8]u8 align(1),
    gid: [8]u8 align(1),
    size: [12]u8 align(1),
    modified: [12]u8 align(1),
    checksum: u64 align(1),
    ty: u8 align(1),
    link: [100]u8 align(1),
};
