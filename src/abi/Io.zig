const std = @import("std");
const abi = @import("lib.zig");
const ring = @import("ring.zig");
const caps = @import("caps.zig");

pub const Threaded = @import("Io/Threaded.zig");

pub const FileDescriptor = union(enum) {
    unused: struct {
        // `fd_grow_next_alloc` with these form a free list
        next: ?u16,
    },

    /// shared ringbuffer
    ring: ring.Ring(u8),
    /// raw mappable file
    file: struct {
        frame: caps.Frame,
        size: usize,
    },
    /// like /dev/null
    none: void,

    const FdMap = [0xFFFF]FileDescriptor;
    var fd_map: ?*FdMap = null;
    var fd_grow_lock: abi.lock.Futex = .unlocked;
    var fd_grow_next_alloc: u16 = 0;
    var fd_grow_free_list_head: ?u16 = null;

    pub fn init() !void {
        const vmem = abi.caps.Vmem.self;
        const frame = try abi.caps.Frame.create(@sizeOf(FdMap));
        defer frame.close();

        const addr = try vmem.map(
            frame,
            0,
            0,
            0,
            .{ .write = true },
        );

        fd_map = @ptrFromInt(addr);
    }

    pub fn destroy(
        fd: i32,
    ) FileDescriptor {
        const id: u16 = @intCast(fd);

        fd_grow_lock.lock();
        defer fd_grow_lock.unlock();

        if (fd_grow_next_alloc -% 1 == id) {
            std.debug.assert(fd_grow_next_alloc != 0);
            fd_map.?[id] = undefined;
            fd_grow_next_alloc -= 1;
            return;
        }

        fd_map.?[id] = .{ .unused = .{
            .next = fd_grow_free_list_head,
        } };
        fd_grow_free_list_head = id;
    }

    pub fn create() error{OutOfMemory}!i32 {
        fd_grow_lock.lock();
        defer fd_grow_lock.unlock();

        if (fd_grow_free_list_head) |id| {
            fd_grow_free_list_head = fd_map.?[id].unused;
            fd_map.?[id] = undefined;
            return id;
        }

        if (fd_grow_next_alloc == std.math.maxInt(u16)) {
            @branchHint(.cold);
            return error.OutOfMemory;
        }

        defer fd_grow_next_alloc += 1;
        fd_map.?[fd_grow_next_alloc] = undefined;
        return fd_grow_next_alloc;
    }

    pub fn get(
        fd: i32,
    ) *FileDescriptor {
        const id: u16 = @intCast(fd);
        return &fd_map.?[id].used;
    }
};
