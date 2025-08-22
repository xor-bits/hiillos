const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;

//

const log = std.log.scoped(.vfs);
const Error = abi.sys.Error;
pub const log_level = .info;

//

pub export var manifest = abi.loader.Manifest.new(.{
    .name = "vfs",
});

pub export var export_vfs = abi.loader.Resource.new(.{
    .name = "hiillos.vfs.ipc",
    .ty = .receiver,
});

pub export var import_vfs = abi.loader.Resource.new(.{
    .name = "hiillos.vfs.ipc",
    .ty = .sender,
});

pub export var import_initfs = abi.loader.Resource.new(.{
    .name = "hiillos.initfsd.ipc",
    .ty = .sender,
});

pub export var import_hpet = abi.loader.Resource.new(.{
    .name = "hiillos.hpet.ipc",
    .ty = .sender,
});

//

var global_root: *DirNode = undefined;
var fs_root: *DirNode = undefined;
var initfs_root: *DirNode = undefined;
var vmem: caps.Vmem = .{};

//

pub fn main() !void {
    log.info("hello from vfs", .{});

    if (abi.conf.IPC_BENCHMARK) {
        const start_nanos = abi.time.nanoTimestampWith(.{ .cap = import_hpet.handle });

        const recv = caps.Receiver{ .cap = export_vfs.handle };
        var msg = try recv.recv();
        var i: usize = 1;
        while (true) : (i +%= 1) {
            msg = try recv.replyRecv(msg);
            if (i % 0x80_0000 == 0) {
                @branchHint(.cold);
                // nanoTimestampWith is an IPC call itself,
                // but does a bit more than the normal empty round trip
                i += 1;
                const now_nanos = abi.time.nanoTimestampWith(.{ .cap = import_hpet.handle });
                const elapsed_nanos = now_nanos -| start_nanos;
                const rtt_nanos = elapsed_nanos / i;
                const per_second = if (elapsed_nanos == 0) 0 else @as(u128, i) * 1_000_000_000 / elapsed_nanos;

                // log.info("{}", .{i});
                log.info("{} calls (~{}ns RTT) (~{}Hz)", .{
                    i,
                    rtt_nanos,
                    per_second,
                });
            }
        }
    }

    const initfsd = abi.FsProtocol.Client().init(.{ .cap = import_initfs.handle });
    const initfs_root_inode: u128 = (try initfsd.call(.root, {})).@"0";

    vmem = try caps.Vmem.self();

    global_root = try DirNode.create(null, 0);

    fs_root = try DirNode.create(global_root.clone(), 0);
    initfs_root = try DirNode.create(global_root.clone(), initfs_root_inode);
    initfs_root.device = .init(.{ .cap = import_initfs.handle });

    try putDir(global_root, "fs", fs_root);
    try putDir(global_root, "initfs", initfs_root);

    try printTreeRec(global_root);

    // inform the root that vfs is ready
    log.debug("vfs ready", .{});

    abi.lpc.daemon(Server{
        .recv = .{ .cap = export_vfs.handle },
        .send = .{ .cap = import_vfs.handle },
    });
}

const Server = struct {
    recv: caps.Receiver,
    send: caps.Sender,

    pub const routes = .{
        openFile,
        openDir,
        symlink,
        link,
        newSender,
        connect,
    };
    pub const Request = abi.VfsProtocol.Request;
};

fn openFile(
    _: *abi.lpc.Daemon(Server),
    handler: abi.lpc.Handler(abi.VfsProtocol.OpenFileRequest),
) !void {
    if (openFileInner(handler)) |ok| {
        handler.reply.send(.{ .ok = ok });
    } else |err| {
        handler.reply.send(.{ .err = abi.sys.errorToEnum(err) });
    }
}

fn openFileInner(
    handler: abi.lpc.Handler(abi.VfsProtocol.OpenFileRequest),
) !caps.Frame {
    const uri = try handler.req.path.getMap();
    defer uri.deinit();

    const path = try partsFromUri(uri.p);

    // TODO: restrict access using the ctx.uid

    const namespace = try global_root.clone()
        .getDir(path.scheme, .use_existing);

    const file = try getFile(
        namespace,
        path.path,
        handler.req.open_opts.dir_policy,
        handler.req.open_opts.file_policy,
    );
    defer file.destroy();

    return try file.getFrame();
}

fn openDir(
    _: *abi.lpc.Daemon(Server),
    handler: abi.lpc.Handler(abi.VfsProtocol.OpenDirRequest),
) !void {
    if (openDirInner(handler)) |ok| {
        handler.reply.send(.{ .ok = ok });
    } else |err| {
        handler.reply.send(.{ .err = abi.sys.errorToEnum(err) });
    }
}

fn openDirInner(
    handler: abi.lpc.Handler(abi.VfsProtocol.OpenDirRequest),
) !abi.fs.Dir {
    const uri = try handler.req.path.getMap();
    defer uri.deinit();

    const path = try partsFromUri(uri.p);

    const namespace = try global_root.clone()
        .getDir(path.scheme, .use_existing);

    const dir = try getDir(
        namespace,
        path.path,
        handler.req.open_opts.dir_policy,
        handler.req.open_opts.file_policy,
    );
    defer dir.destroy();

    dir.cache_lock.lock();
    defer dir.cache_lock.unlock();
    try dir.lazyLoadLocked();

    var frame_size: usize = 0;

    var it = dir.entries.iterator();
    while (it.next()) |entry| {
        frame_size += @sizeOf(abi.fs.DirEntRawNoName) + entry.key_ptr.len + 1;
    }

    const frame = try caps.Frame.create(@max(frame_size, 0x1000));
    errdefer frame.close();
    frame_size = 0;

    var frame_stream = frame.stream();
    var frame_buffered_stream = std.io.bufferedWriter(frame_stream.writer());
    var frame_writer = frame_buffered_stream.writer();
    it = dir.entries.iterator();
    while (it.next()) |entry| {
        const header = abi.fs.DirEntRawNoName{
            .entry_size = @intCast(@sizeOf(abi.fs.DirEntRawNoName) + entry.key_ptr.len + 1),
            .type = entry.value_ptr.entryType(),
        };
        try frame_writer.writeAll(std.mem.asBytes(&header));
        try frame_writer.writeAll(entry.key_ptr.*);
        try frame_writer.writeAll(&.{0});
    }
    try frame_buffered_stream.flush();

    return .{
        .data = frame,
        .count = dir.entries.count(),
    };
}

fn symlink(
    _: *abi.lpc.Daemon(Server),
    handler: abi.lpc.Handler(abi.VfsProtocol.SymlinkRequest),
) !void {
    if (symlinkInner(handler)) |ok| {
        handler.reply.send(.{ .ok = ok });
    } else |err| {
        handler.reply.send(.{ .err = abi.sys.errorToEnum(err) });
    }
}

fn symlinkInner(
    handler: abi.lpc.Handler(abi.VfsProtocol.SymlinkRequest),
) !void {
    const old_uri = try handler.req.oldpath.getMap();
    defer old_uri.deinit();
    const old_path = try partsFromUri(old_uri.p);

    const new_uri = try handler.req.newpath.getMap();
    defer new_uri.deinit();
    const new_path = try partsFromUri(new_uri.p);

    const new_path_parent = std.fs.path.dirname(new_path.path) orelse
        return Error.NotFound;
    const new_path_entry = std.fs.path.basename(new_path.path);

    const old_namespace = try global_root.clone()
        .getDir(old_path.scheme, .use_existing);
    const old_entry = try get(
        old_namespace,
        old_path.path,
        .use_existing,
        .use_existing,
    );

    const new_namespace = try global_root.clone()
        .getDir(new_path.scheme, .use_existing);
    const new_parent_dir = try getDir(
        new_namespace,
        new_path_parent,
        .use_existing,
        .use_existing,
    );
    defer new_parent_dir.destroy();

    try new_parent_dir.add(new_path_entry, old_entry);
}

fn link(
    _: *abi.lpc.Daemon(Server),
    handler: abi.lpc.Handler(abi.VfsProtocol.LinkRequest),
) !void {
    if (linkInner(handler)) |ok| {
        handler.reply.send(.{ .ok = ok });
    } else |err| {
        handler.reply.send(.{ .err = abi.sys.errorToEnum(err) });
    }
}

fn linkInner(
    handler: abi.lpc.Handler(abi.VfsProtocol.LinkRequest),
) !void {
    errdefer handler.req.socket.close();

    const uri = try handler.req.path.getMap();
    defer uri.deinit();
    const path = try partsFromUri(uri.p);

    const path_parent = std.fs.path.dirname(path.path) orelse
        return Error.NotFound;
    const path_entry = std.fs.path.basename(path.path);

    const namespace = try global_root.clone()
        .getDir(path.scheme, .use_existing);
    const parent_dir = try getDir(
        namespace,
        path_parent,
        .use_existing,
        .use_existing,
    );
    defer parent_dir.destroy();

    const socket_node = try SocketNode.create(parent_dir, handler.req.socket);
    try parent_dir.add(path_entry, .{ .socket = socket_node });
}

fn connect(
    _: *abi.lpc.Daemon(Server),
    handler: abi.lpc.Handler(abi.VfsProtocol.ConnectRequest),
) !void {
    if (connectInner(handler)) |ok| {
        handler.reply.send(.{ .ok = ok });
    } else |err| {
        handler.reply.send(.{ .err = abi.sys.errorToEnum(err) });
    }
}

fn connectInner(
    handler: abi.lpc.Handler(abi.VfsProtocol.ConnectRequest),
) !caps.Handle {
    const uri = try handler.req.path.getMap();
    defer uri.deinit();

    const path = try partsFromUri(uri.p);

    // TODO: restrict access using the ctx.uid

    const namespace = try global_root.clone()
        .getDir(path.scheme, .use_existing);

    const socket = try getSocket(
        namespace,
        path.path,
        .use_existing,
        .use_existing,
    );
    defer socket.destroy();

    return try socket.getHandle();
}

fn newSender(
    daemon: *abi.lpc.Daemon(Server),
    handler: abi.lpc.Handler(abi.VfsProtocol.NewSenderRequest),
) !void {
    if (handler.stamp != 0) {
        handler.reply.send(.{ .err = .permission_denied });
        return;
    }

    errdefer handler.reply.send(.{ .err = .internal });

    const sender = try daemon.ctx.send.stampFinal(handler.req.uid);
    handler.reply.send(.{ .ok = sender });
}

//

fn partsFromUri(uri: []const u8) Error!struct {
    scheme: []const u8,
    path: []const u8,
} {
    log.debug("partsFromUri({s})", .{uri});

    if (std.mem.startsWith(u8, uri, "/")) return .{
        .scheme = "fs:///",
        .path = uri,
    };

    var it = std.mem.splitSequence(u8, uri, "://");
    const scheme = it.next() orelse
        return Error.NotFound;
    const path = it.rest();
    log.debug(" - scheme = {s}", .{scheme});
    log.debug(" - path = {s}", .{path});

    return .{
        .scheme = scheme,
        .path = path,
    };
}

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

// will take ownership of `namespace` and returns an owned `DirEntry`
fn get(
    namespace: *DirNode,
    path: []const u8,
    missing_dir_policy: abi.fs.OpenOptions.MissingPolicy,
    missing_entry_policy: abi.fs.OpenOptions.MissingPolicy,
) !DirEntry {
    const parent_path = std.fs.path.dirname(path);
    const entry_name = std.fs.path.basename(path);
    log.debug(" - parent_path = {s}", .{parent_path orelse "<null>"});
    log.debug(" - entry_name = {s}", .{entry_name});

    var current = namespace;
    if (parent_path) |_parent_path| {
        var it = abi.fs.path.absolutePartIterator(_parent_path);
        while (it.next()) |part| {
            current = try current.getDir(
                part.name,
                missing_dir_policy,
            );
        }
    }

    if (entry_name.len == 0) {
        return .{ .dir = current };
    }

    return current.get(entry_name, missing_entry_policy);
}

// will take ownership of `namespace` and returns an owned `*DirNode`
fn getDir(
    namespace: *DirNode,
    path: []const u8,
    missing_dir_policy: abi.fs.OpenOptions.MissingPolicy,
    missing_entry_policy: abi.fs.OpenOptions.MissingPolicy,
) !*DirNode {
    const node = try get(
        namespace,
        path,
        missing_dir_policy,
        missing_entry_policy,
    );
    errdefer node.destroy();

    if (node != .dir) return Error.NotFound;
    return node.dir;
}

// will take ownership of `namespace` and returns an owned `*FileNode`
fn getFile(
    namespace: *DirNode,
    path: []const u8,
    missing_dir_policy: abi.fs.OpenOptions.MissingPolicy,
    missing_entry_policy: abi.fs.OpenOptions.MissingPolicy,
) !*FileNode {
    const node = try get(
        namespace,
        path,
        missing_dir_policy,
        missing_entry_policy,
    );
    errdefer node.destroy();

    if (node != .file) return Error.NotFound;
    return node.file;
}

// will take ownership of `namespace` and returns an owned `*SocketNode`
fn getSocket(
    namespace: *DirNode,
    path: []const u8,
    missing_dir_policy: abi.fs.OpenOptions.MissingPolicy,
    missing_entry_policy: abi.fs.OpenOptions.MissingPolicy,
) !*SocketNode {
    const node = try get(
        namespace,
        path,
        missing_dir_policy,
        missing_entry_policy,
    );
    errdefer node.destroy();

    if (node != .socket) return Error.NotFound;
    return node.socket;
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

        try self.dir.lazyLoadLocked();

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

const SocketNode = struct {
    refcnt: abi.epoch.RefCnt = .{},

    parent: *DirNode,

    cap: caps.Handle,

    /// takes ownership of `parent`
    pub fn create(parent: *DirNode, cap: caps.Handle) !*@This() {
        socket_node_allocator_lock.lock();
        defer socket_node_allocator_lock.unlock();

        const node = try socket_node_allocator.create();
        node.* = .{
            .parent = parent,
            .cap = cap,
        };
        return node;
    }

    /// does not take ownership of `self` but returns an owned one
    pub fn clone(self: *@This()) *@This() {
        self.refcnt.inc();
        return self;
    }

    /// takes ownership of `self` and might or might not delete the data
    pub fn destroy(self: *@This()) void {
        if (!self.refcnt.dec()) return;

        self.parent.destroy();

        self.cap.close();

        socket_node_allocator_lock.lock();
        defer socket_node_allocator_lock.unlock();
        socket_node_allocator.destroy(self);
    }

    /// does not take ownership of `self`, returns an owned Handle
    pub fn getHandle(self: *@This()) Error!caps.Handle {
        return try self.cap.clone();
    }
};

const FileNode = struct {
    refcnt: abi.epoch.RefCnt = .{},

    parent: *DirNode,

    /// inode of the file in the correct device
    inode: u128,

    cache_lock: abi.thread.Mutex = .{},

    /// all cached pages
    frame: caps.Frame = .{},

    /// takes ownership of `parent`
    pub fn create(parent: *DirNode, inode: u128) !*@This() {
        file_node_allocator_lock.lock();
        defer file_node_allocator_lock.unlock();

        const node = try file_node_allocator.create();
        node.* = .{
            .parent = parent,
            .inode = inode,
        };
        return node;
    }

    /// does not take ownership of `self` but returns an owned one
    pub fn clone(self: *@This()) *@This() {
        self.refcnt.inc();
        return self;
    }

    /// takes ownership of `self` and might or might not delete the data
    pub fn destroy(self: *@This()) void {
        if (!self.refcnt.dec()) return;

        self.parent.destroy();

        if (self.frame.cap != 0) self.frame.close();

        file_node_allocator_lock.lock();
        defer file_node_allocator_lock.unlock();
        file_node_allocator.destroy(self);
    }

    /// does not take ownership of `self`, returns an owned Frame
    pub fn getFrame(self: *@This()) Error!caps.Frame {
        self.cache_lock.lock();
        defer self.cache_lock.unlock();

        if (self.frame.cap != 0) return self.frame.clone();

        const mount_point = self
            .parent
            .clone()
            .findDevice() orelse unreachable; // VFS error if there is a cached file without a filesystem
        defer mount_point.destroy();

        errdefer self.frame = .{};
        const res: Error!void, self.frame = try mount_point
            .device
            .call(.openFile, .{self.inode});
        try res;

        return self.frame.clone();
    }
};

const DirEntry = union(enum) {
    // TODO: could be packed into a single pointer,
    // and its lower bit (because of alignment) can
    // be used to tell if it is a file or a dir
    socket: *SocketNode,
    file: *FileNode,
    dir: *DirNode,

    fn entryType(self: @This()) abi.fs.EntType {
        return switch (self) {
            .socket => .socket,
            .file => .file,
            .dir => .dir,
        };
    }

    fn clone(self: @This()) @This() {
        switch (self) {
            inline else => |v| v.refcnt.inc(),
        }
        return self;
    }

    fn destroy(self: @This()) void {
        switch (self) {
            inline else => |v| v.destroy(),
        }
    }
};

const DirNode = struct {
    refcnt: abi.epoch.RefCnt = .{},

    parent: *DirNode,
    /// optional mounted device
    device: abi.FsProtocol.Client() = .init(.{}),

    /// inode of the directory in the correct device
    inode: u128,

    cache_lock: abi.thread.Mutex = .{},

    /// all cached subdirectories and files in this directory
    entries: std.StringHashMap(DirEntry) = .init(abi.mem.slab_allocator),
    uninitialized: bool = true,

    /// takes ownership of `parent`
    /// `parent == null` makes the directory its own parent, like `/../../ == /../ == /`
    pub fn create(parent: ?*DirNode, inode: u128) !*@This() {
        dir_node_allocator_lock.lock();
        defer dir_node_allocator_lock.unlock();

        const node: *@This() = try dir_node_allocator.create();
        node.* = .{
            .parent = parent orelse node,
            .inode = inode,
        };
        return node;
    }

    /// does not take ownership of `self` but returns an owned one
    pub fn clone(self: *@This()) *@This() {
        self.refcnt.inc();
        return self;
    }

    /// takes ownership of `self` and might or might not delete the data
    pub fn destroy(self: *@This()) void {
        if (!self.refcnt.dec()) return;

        if (self.parent != self) self.parent.destroy();

        var it = self.entries.iterator();
        while (it.next()) |entry| {
            abi.mem.slab_allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.destroy();
        }
        self.entries.deinit();

        dir_node_allocator_lock.lock();
        defer dir_node_allocator_lock.unlock();

        dir_node_allocator.destroy(self);
    }

    /// takes ownership of `self` and returns an owned `*DirNode`
    pub fn getDir(
        self: *@This(),
        part: []const u8,
        missing_policy: abi.fs.OpenOptions.MissingPolicy,
    ) Error!*DirNode {
        const next = try self.get(part, missing_policy);
        errdefer next.destroy();

        if (next != .dir) return Error.NotFound;
        return next.dir;
    }

    /// takes ownership of `self` and returns an owned `*FileNode`
    pub fn getFile(
        self: *@This(),
        part: []const u8,
        missing_policy: abi.fs.OpenOptions.MissingPolicy,
    ) Error!*FileNode {
        const next = try self.get(part, missing_policy);
        errdefer next.destroy();

        if (next != .file) return Error.NotFound;
        return next.file;
    }

    /// takes ownership of `self` and returns an owned `*SocketNode`
    pub fn getSocket(
        self: *@This(),
        part: []const u8,
        missing_policy: abi.fs.OpenOptions.MissingPolicy,
    ) Error!*SocketNode {
        const next = try self.get(part, missing_policy);
        errdefer next.destroy();

        if (next != .socket) return Error.NotFound;
        return next.socket;
    }

    /// takes ownership of `self` and returns an owned `DirEntry`
    pub fn get(
        self: *@This(),
        part: []const u8,
        missing_policy: abi.fs.OpenOptions.MissingPolicy,
    ) Error!DirEntry {
        defer self.destroy();

        self.cache_lock.lock();
        defer self.cache_lock.unlock();

        try self.lazyLoadLocked();

        // TODO: missing_policy, requres real filesystems
        _ = missing_policy;

        log.debug("looking up part '{s}'", .{part});

        const next = self.entries.get(part) orelse
            return Error.NotFound;
        return next.clone();
    }

    /// takes ownership of `entry` but NOT `self`
    pub fn add(self: *@This(), name: []const u8, entry: DirEntry) Error!void {
        self.cache_lock.lock();
        defer self.cache_lock.unlock();

        try self.addLocked(name, entry);
    }

    /// takes ownership of `self` and returns an owned `*DirNode`
    pub fn getParent(self: *@This()) *DirNode {
        defer self.destroy();
        return self.parent.clone();
    }

    /// takes ownership of `self` and returns an owned `*DirNode`
    /// find the first ancestor that has a mounted device
    pub fn findDevice(self: *@This()) ?*DirNode {
        var cur = self;
        // defer cur.destroy();

        while (true) {
            if (cur.device.tx.cap != 0) {
                // found a device
                return cur;
            }

            if (cur.parent == cur) {
                // found the root
                cur.destroy();
                return null;
            }

            // keep going
            cur = cur.getParent();
        }
    }

    /// does not take ownership of `self`
    pub fn lazyLoadLocked(self: *@This()) Error!void {
        if (self.uninitialized) {
            @branchHint(.cold);
            self.uninitialized = false;
        } else {
            return;
        }

        log.debug("lazy loading directory contents", .{});

        const mount_point = self
            .clone()
            .findDevice() orelse return;
        defer mount_point.destroy();

        const real_dir = try mount_point.loadRealDir(self.inode);
        const real_dir_frame_size = try real_dir.frame.getSize();

        const addr = try vmem.map(
            real_dir.frame,
            0,
            0,
            real_dir_frame_size,
            .{},
        );
        defer vmem.unmap(addr, real_dir_frame_size) catch unreachable;

        if (real_dir.entries >= 0x1_0000_0000) {
            log.err("filesystem returned too many directory entries", .{});
            return Error.Internal;
        }

        if (real_dir_frame_size < real_dir.entries * @sizeOf(abi.Stat)) {
            log.err("filesystem returned invalid directory data", .{});
            return Error.Internal;
        }

        const entries = @as(
            [*]const volatile abi.Stat,
            @ptrFromInt(addr),
        )[0..real_dir.entries];
        const strings = @as(
            [*]const u8,
            @ptrFromInt(addr),
        )[real_dir.entries * @sizeOf(abi.Stat) .. real_dir_frame_size];
        var strings_it = std.mem.splitScalar(u8, strings, 0);

        // FIXME: clone the provided Frame with copy-on-write,
        // to prevent the filesystem server from modifying the data while it is used here

        for (entries) |*entry| {
            const stat = @as(*const volatile abi.Stat, entry).*;
            const name = strings_it.next() orelse {
                log.err("filesystem returned invalid directory entry names", .{});
                return Error.Internal;
            };

            if (abi.conf.IS_DEBUG) {
                if (std.mem.containsAtLeastScalar(
                    u8,
                    name,
                    1,
                    '/',
                )) {
                    log.err("filesystem returned a path instead of a dir entry name for a dir entry: {s}", .{name});
                    return Error.Internal;
                }

                if (std.mem.eql(
                    u8,
                    name,
                    ".",
                ) or std.mem.eql(
                    u8,
                    name,
                    "..",
                )) {
                    log.err("filesystem returned a '{s}' as a dir entry", .{name});
                    return Error.Internal;
                }
            }

            try self.addEntryLocked(stat, name);
        }
    }

    /// does not take ownership of `self`
    fn loadRealDir(self: *@This(), inode: u128) Error!struct {
        frame: caps.Frame,
        entries: usize,
    } {
        const res: Error!void, const entries_frame: caps.Frame, const entries = try self
            .device
            .call(.openDir, .{inode});
        try res;

        return .{ .frame = entries_frame, .entries = entries };
    }

    fn addEntryLocked(self: *@This(), stat: abi.Stat, name: []const u8) Error!void {
        const entry: DirEntry = switch (stat.mode.type) {
            .dir => .{ .dir = try DirNode.create(self.clone(), stat.inode) },
            .file => .{ .file = try FileNode.create(self.clone(), stat.inode) },
            else => {
                log.err("ignoring unimplemented dir entry type: {}", .{stat.mode.type});
                return;
            },
        };

        try self.addLocked(name, entry);
    }

    /// takes ownership of `entry` but NOT `self`
    fn addLocked(self: *@This(), name: []const u8, entry: DirEntry) Error!void {
        errdefer entry.destroy();

        const s = try abi.mem.slab_allocator.dupe(u8, name);
        errdefer abi.mem.slab_allocator.free(s);

        const result = try self.entries.getOrPut(s);
        if (result.found_existing) {
            log.err("filesystem returned duplicate directory entries: {s}", .{s});
            entry.destroy();
            abi.mem.slab_allocator.free(s);
            return;
        }
        result.value_ptr.* = entry;
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

var socket_node_allocator: std.heap.MemoryPool(SocketNode) = std.heap.MemoryPool(SocketNode).init(abi.mem.server_page_allocator);
var socket_node_allocator_lock: abi.thread.Mutex = .{};
var file_node_allocator: std.heap.MemoryPool(FileNode) = std.heap.MemoryPool(FileNode).init(abi.mem.server_page_allocator);
var file_node_allocator_lock: abi.thread.Mutex = .{};
var dir_node_allocator: std.heap.MemoryPool(DirNode) = std.heap.MemoryPool(DirNode).init(abi.mem.server_page_allocator);
var dir_node_allocator_lock: abi.thread.Mutex = .{};
