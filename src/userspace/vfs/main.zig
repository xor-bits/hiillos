const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;

//

pub const std_options = abi.std_options;
pub const panic = abi.panic;

const log = std.log.scoped(.vfs);
const Error = abi.sys.Error;

var main_thread_locals: abi.epoch.Locals = .{};
pub fn epoch_locals() *abi.epoch.Locals {
    return &main_thread_locals;
}

//

pub export var manifest = abi.loader.Manifest.new(.{
    .name = "vfs",
});

pub export var export_vfs = abi.loader.Resource.new(.{
    .name = "hiillos.vfs.ipc",
    .ty = .receiver,
});

pub export var import_initfs = abi.loader.Resource.new(.{
    .name = "hiillos.initfsd.ipc",
    .ty = .sender,
});

//

var global_root: *DirNode = undefined;
var fs_root: *DirNode = undefined;
var initfs_root: *DirNode = undefined;

//

pub fn main() !void {
    log.info("hello from vfs", .{});

    if (abi.conf.IPC_BENCHMARK) {
        const recv = caps.Receiver{ .cap = export_vfs.handle };
        var msg = try recv.recv();
        var i: usize = 0;
        while (true) : (i +%= 1) {
            msg = try recv.replyRecv(msg);
            if (i % 1_000_000 == 0) {
                log.info("{} calls", .{i});
            }
        }
    }

    global_root = try DirNode.create();

    fs_root = try DirNode.create();
    initfs_root = try DirNode.create();

    const initfs = abi.InitfsProtocol.Client().init(.{ .cap = import_initfs.handle });
    const res, const entries_frame, const entries = try initfs.call(.list, {});
    try res;

    const vmem = try caps.Vmem.self();
    defer vmem.close();

    const addr = try vmem.map(
        entries_frame,
        0,
        0,
        0,
        .{},
        .{},
    );

    try putDir(global_root, "initfs://", initfs_root);
    try putDir(global_root, "fs://", fs_root);

    log.info("mounting initfs to initfs:///", .{});

    var byte: usize = 0;
    for (0..entries) |i| {
        const stat = @as(*const volatile abi.Stat, @ptrFromInt(addr + i * @sizeOf(abi.Stat))).*;
        const path = @as([*:0]const u8, @ptrFromInt(addr + entries * @sizeOf(abi.Stat) + byte));
        const path_name: []const u8 = std.mem.span(path);
        byte += 1 + path_name.len;

        if (stat.mode.type != .dir) continue;

        // FIXME: sort directories

        initfs_root.clone();
        try createDir(initfs_root, path_name, try DirNode.create());
    }

    byte = 0;
    for (0..entries) |i| {
        const stat = @as(*const volatile abi.Stat, @ptrFromInt(addr + i * @sizeOf(abi.Stat))).*;
        const path = @as([*:0]const u8, @ptrFromInt(addr + entries * @sizeOf(abi.Stat) + byte));
        const path_name: []const u8 = std.mem.span(path);
        byte += 1 + path_name.len;

        if (stat.mode.type != .file) continue;

        const new_file = try FileNode.create();
        new_file.inode = stat.inode;

        initfs_root.clone();
        try createFile(initfs_root, path_name, new_file);
    }

    try printTreeRec(global_root);

    // inform the root that vfs is ready
    log.debug("vfs ready", .{});

    const server = abi.VfsProtocol.Server(.{}, .{
        .open = openHandler,
    }).init({}, .{ .cap = export_vfs.handle });
    try server.run();
}

fn openHandler(_: void, _: u32, req: struct { caps.Frame, usize, usize, u8 }) struct { Error!void, caps.Sender } {
    const frame = req.@"0";
    const frame_path_offs = req.@"1";
    const path_len = req.@"2";
    const open_opts: abi.Vfs.OpenOptions = @bitCast(req.@"3");

    defer frame.close();

    var buf: [0x1000]u8 = undefined;
    const path = buf[0..path_len];
    frame.read(frame_path_offs, path) catch |err| {
        log.err("could not read from a frame: {}", .{err});
        return .{ Error.Internal, .{} };
    };

    log.info("opening `{s}` with `{}`", .{ path, open_opts });

    return .{ {}, .{} };
}

//

// will take ownership of `namespace` and `new_file`
fn createFile(namespace: *DirNode, relative_path: []const u8, new_file: *FileNode) !void {
    return createAny(
        namespace,
        relative_path,
        .{ .file = new_file },
    );
}

// will take ownership of `namespace` and `new_dir`
fn createDir(namespace: *DirNode, relative_path: []const u8, new_dir: *DirNode) !void {
    return createAny(
        namespace,
        relative_path,
        .{ .dir = new_dir },
    );
}

// will take ownership of `namespace` and `new`
fn createAny(namespace: *DirNode, relative_path: []const u8, new: DirEntry) !void {
    var parent = namespace;
    defer parent.destroy();

    // TODO: give real errors
    const basename = std.fs.path.basename(relative_path);
    // log.info("basename({s}) = {s}", .{ relative_path, basename });
    if (std.fs.path.dirname(relative_path)) |parent_path| {
        // log.info("dirname({s}) = {s}", .{ relative_path, parent_path });
        parent = try getDir(parent, parent_path);
    } else if (std.mem.eql(u8, basename, ".")) {
        new.destroy();
        return;
    }

    return putAny(parent, basename, new);
}

// will take ownership of `new` but not `dir`
fn putFile(dir: *DirNode, basename: []const u8, new_file: *FileNode) !void {
    return putAny(dir, basename, .{ .file = new_file });
}

// will take ownership of `new` but not `dir`
fn putDir(dir: *DirNode, basename: []const u8, new_dir: *DirNode) !void {
    return putAny(dir, basename, .{ .dir = new_dir });
}

// will take ownership of `new` but not `dir`
fn putAny(dir: *DirNode, basename: []const u8, new: DirEntry) !void {
    const get_or_put = try dir.entries.getOrPut(basename);
    if (get_or_put.found_existing) return Error.AlreadyMapped; // TODO: real error

    const basename_copy = try abi.mem.slab_allocator.alloc(u8, basename.len);
    std.mem.copyForwards(u8, basename_copy, basename);

    // `key_ptr` isn't supposed to be written,
    // but I just replace it with the same data in a new pointer,
    // because `relative_path` is temporary data
    get_or_put.key_ptr.* = basename_copy;
    get_or_put.value_ptr.* = new;
}

// will take ownership of `namespace` and returns an owned `*DirNode`
fn getDir(namespace: *DirNode, relative_path: []const u8) !*DirNode {
    var current = namespace;

    var it = try std.fs.path.componentIterator(relative_path);
    while (it.next()) |part| {
        // TODO: '..' parts
        if (std.mem.eql(u8, part.name, ".")) continue;
        // log.debug("looking up part '{s}'", .{part.name});

        var next: DirEntry = undefined;
        {
            defer current.destroy();
            current.cache_lock.lock();
            defer current.cache_lock.unlock();

            next = current.entries.get(part.name) orelse return Error.NotFound;
            if (next == .file) return Error.NotFound;

            next.dir.clone();
        }

        current = next.dir;
    }

    return current;
}

fn printTreeRec(dir: *DirNode) !void {
    log.info("\n{}", .{
        PrintTreeRec{ .dir = dir, .depth = 0 },
    });
}

const PrintTreeRec = struct {
    dir: *DirNode,
    depth: usize,

    pub fn format(
        self: @This(),
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        self.dir.cache_lock.lock();
        defer self.dir.cache_lock.unlock();

        var it = self.dir.entries.iterator();
        while (it.next()) |entry| {
            for (0..self.depth) |_| {
                try std.fmt.format(writer, "  ", .{});
            }

            try std.fmt.format(writer, "- '{s}': {s}\n", .{
                entry.key_ptr.*,
                @tagName(entry.value_ptr.*),
            });

            switch (entry.value_ptr.*) {
                .dir => |dir| try std.fmt.format(writer, "{}", .{
                    PrintTreeRec{ .dir = dir, .depth = self.depth + 1 },
                }),
                else => {},
            }
        }
    }
};

//

const FileNode = struct {
    refcnt: RefCnt = .{},

    /// inode of the file in the correct device
    inode: u128 = 0,

    cache_lock: abi.lock.YieldMutex = .{},

    /// all cached pages
    pages: []caps.Frame = &.{},

    pub fn create() !*@This() {
        file_node_allocator_lock.lock();
        defer file_node_allocator_lock.unlock();
        const node = try file_node_allocator.create();
        node.* = .{};
        return node;
    }

    pub fn clone(self: *@This()) void {
        self.refcnt.inc();
    }

    pub fn destroy(self: *@This()) void {
        if (self.refcnt.dec()) {
            @branchHint(.cold);

            file_node_allocator_lock.lock();
            defer file_node_allocator_lock.unlock();
            file_node_allocator.destroy(self);
        }
    }
};

const DirEntry = union(enum) {
    // TODO: could be packed into a single pointer,
    // and its lower bit (because of alignment) can
    // be used to tell if it is a file or a dir
    file: *FileNode,
    dir: *DirNode,

    fn destroy(self: @This()) void {
        switch (self) {
            .dir => |dir| dir.destroy(),
            .file => |file| file.destroy(),
        }
    }
};

const DirNode = struct {
    refcnt: RefCnt = .{},

    /// inode of the directory in the correct device
    inode: u128 = 0,

    cache_lock: abi.lock.YieldMutex = .{},

    /// all cached subdirectories and files in this directory
    entries: std.StringHashMap(DirEntry),

    pub fn create() !*@This() {
        dir_node_allocator_lock.lock();
        defer dir_node_allocator_lock.unlock();
        const node = try dir_node_allocator.create();
        node.* = .{
            .entries = .init(abi.mem.slab_allocator),
        };
        return node;
    }

    pub fn clone(self: *@This()) void {
        self.refcnt.inc();
    }

    pub fn destroy(self: *@This()) void {
        if (self.refcnt.dec()) {
            @branchHint(.cold);

            dir_node_allocator_lock.lock();
            defer dir_node_allocator_lock.unlock();
            dir_node_allocator.destroy(self);
        }
    }

    pub const GetResult = union(enum) {
        none: void,
        file: *FileNode,
        dir: *DirNode,
    };

    // pub fn get(self: *@This(), entry_name: []const u8) GetResult {}

    // pub fn subdirs(self: *@This()) []const *DirNode {
    //     return @ptrCast(self.entries[0..self.dir_entries]);
    // }

    // pub fn files(self: *@This()) []const *FileNode {
    //     return @ptrCast(self.entries[self.dir_entries..][0..self.file_entries]);
    // }
};

const RefCnt = struct {
    refcnt: std.atomic.Value(usize) = .init(1),

    pub fn inc(self: *@This()) void {
        // log.info("inc refcnt", .{});
        const old = self.refcnt.fetchAdd(1, .monotonic);
        if (old >= std.math.maxInt(isize)) @panic("too many ref counts");
    }

    pub fn dec(self: *@This()) bool {
        // log.info("dec refcnt", .{});
        const old_cnt = self.refcnt.fetchSub(1, .release);
        std.debug.assert(old_cnt < std.math.maxInt(isize));
        std.debug.assert(old_cnt != 0);

        if (old_cnt == 1) {
            @branchHint(.cold);
        } else {
            return false;
        }

        // fence
        _ = self.refcnt.load(.acquire);

        return true;
    }
};

var file_node_allocator: std.heap.MemoryPool(FileNode) = std.heap.MemoryPool(FileNode).init(abi.mem.server_page_allocator);
var file_node_allocator_lock: abi.lock.YieldMutex = .{};
var dir_node_allocator: std.heap.MemoryPool(DirNode) = std.heap.MemoryPool(DirNode).init(abi.mem.server_page_allocator);
var dir_node_allocator_lock: abi.lock.YieldMutex = .{};

//

comptime {
    abi.rt.installRuntime();
}
