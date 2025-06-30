const std = @import("std");

const abi = @import("lib.zig");
const caps = @import("caps.zig");
const util = @import("util.zig");

//

const volat = util.volat;

//

pub fn CachePadded(comptime T: type) type {
    return extern struct {
        val: T,
        _pad: [std.atomic.cache_line - @sizeOf(T) % std.atomic.cache_line]u8 = undefined,
    };
}

pub const Error = error{
    InvalidState,
    Full,
};

/// single reader and single writer fixed size ring buffer
///
/// multiple concurrent readers or multiple concurrent writers cause data corruption within the Frame
///
/// reading and writing at the same time is allowed
pub fn Ring(comptime T: type) type {
    return struct {
        frame: caps.Frame,
        self_vmem: caps.Vmem,
        capacity: usize,
        mapped_data: []volatile u8,

        const Self = @This();

        pub fn new(capacity: usize) !Self {
            const size_bytes = sizeOf(capacity);
            const frame = try caps.Frame.create(size_bytes);
            errdefer frame.close();

            return try fromShared(frame, size_bytes, capacity);
        }

        pub fn fromShared(frame: caps.Frame, frame_size: ?usize, capacity: usize) !Self {
            const size_bytes = frame_size orelse try frame.getSize();

            if (size_bytes < sizeOf(capacity))
                return Error.InvalidState;

            const self_vmem = try caps.Vmem.self();
            errdefer self_vmem.close();

            const addr = try self_vmem.map(
                frame,
                0,
                0,
                size_bytes,
                .{ .writable = true },
                .{},
            );

            return .{
                .frame = frame,
                .self_vmem = self_vmem,
                .capacity = capacity,
                .mapped_data = @as([*]volatile u8, @ptrFromInt(addr))[0..size_bytes],
            };
        }

        pub fn share(self: Self) !struct { caps.Frame, usize } {
            return .{ try self.frame.clone(), self.capacity };
        }

        pub fn deinit(self: Self) void {
            defer self.self_vmem.close();
            defer self.frame.close();

            self.self_vmem.unmap(
                @intFromPtr(self.mapped_data.ptr),
                self.mapped_data.len,
            ) catch unreachable;
        }

        const storage_offset: usize = std.mem.alignForward(
            usize,
            @sizeOf(Marker),
            @alignOf(T),
        );

        pub fn sizeOf(capacity: usize) usize {
            const size_bytes_raw = storage_offset + @sizeOf(T) * capacity;
            return std.mem.alignForward(usize, size_bytes_raw, 0x1000);
        }

        // pub fn capacityOf(size_bytes: usize) usize {
        //     const storage_bytes: usize = size_bytes - storage_offset;
        //     return storage_bytes / @sizeOf(T);
        // }

        pub fn marker(self: *Self) *Marker {
            return @ptrCast(self.mapped_data.ptr);
        }

        pub fn storage(self: *Self) []volatile T {
            return @as([*]volatile T, @ptrCast(std.mem.alignForward(
                usize,
                @intFromPtr(self.mapped_data.ptr) + @sizeOf(Marker),
                @alignOf(T),
            )))[0..self.capacity];
        }

        pub fn canWrite(self: *Self, n: usize) Error!bool {
            return try self.marker().acquire(n, self.capacity) != null;
        }

        pub fn canRead(self: *Self, n: usize) Error!bool {
            return try self.marker().consume(n, self.capacity) != null;
        }

        pub fn push(self: *Self, v: T) Error!void {
            const m = self.marker();
            const s = self.storage();

            const slot = m.acquire(1) orelse
                return error.Full;

            volat(&s[slot.first]).* = v;

            m.produce(slot);
        }

        pub fn pop(self: *Self) ?T {
            const m = self.marker();
            const s = self.storage();

            const slot = try m.consume(1, self.capacity) orelse
                return null;

            const val = volat(&s[slot.first]).*;
            volat(&s[slot.first]).* = undefined; // debug

            m.release(slot, self.capacity);
            return val;
        }

        pub fn write(self: *Self, v: []const T) Error!void {
            const m = self.marker();
            const s = self.storage();

            const slot = try m.acquire(v.len, self.capacity) orelse return error.Full;
            const slices = slot.slices(T, s[0..]);

            util.copyForwardsVolatile(T, slices[0], v[0..slices[0].len]);
            util.copyForwardsVolatile(T, slices[1], v[slices[0].len..]);

            m.produce(slot, self.capacity);
        }

        pub fn read(self: *Self, buf: []T) ?[]T {
            const m = self.marker();
            const s = self.storage();

            const slot = try m.consume(buf.len) orelse return null;
            const slices = slot.slices(T, s[0..]);

            util.copyForwardsVolatile(T, buf[0..slices[0].len], slices[0]);
            util.copyForwardsVolatile(T, buf[slices[0].len..], slices[1]);

            m.release(slot, self.capacity);
            return buf[0..slot.len];
        }
    };
}

pub const Slot = struct {
    first: usize,
    len: usize,

    const Self = @This();

    pub fn take(self: Self, n: usize) ?Self {
        if (n > self.len) return null;
        return Self{ .first = self.first, .len = n };
    }

    pub fn min(self: Self, n: usize) Self {
        return Self{ .first = self.first, .len = @min(n, self.len) };
    }

    pub fn slices(self: Self, comptime T: type, storage: []T) [2][]T {
        std.debug.assert(self.len <= storage.len);

        if (self.first + self.len <= storage.len) {
            return .{ storage[self.first .. self.first + self.len], &.{} };
        } else {
            const first = storage[self.first..];
            return .{ first, storage[0 .. self.len - first.len] };
        }
    }
};

pub const Marker = extern struct {
    read_end: CachePadded(std.atomic.Value(usize)) = .{ .val = .{ .raw = 0 } },
    write_end: CachePadded(std.atomic.Value(usize)) = .{ .val = .{ .raw = 0 } },

    const Self = @This();

    pub fn uninitSlot(self: *Self, capacity: usize) Error!Slot {
        const write = self.write_end.val.load(.acquire);
        const read = self.read_end.val.load(.acquire);

        if (write >= capacity or read >= capacity)
            return Error.InvalidState;

        // read end - 1 is the limit, the number of available spaces can only grow
        // read=write would be ambiguous so read=write always means that the whole buf is empty
        // => write of self.len to an empty buffer is not possible (atm)
        const avail = if (write < read)
            read - write
        else
            capacity - write + read;
        if (avail > capacity)
            return Error.InvalidState;

        return Slot{
            .first = write,
            .len = @max(avail, 1) - 1,
        };
    }

    pub fn initSlot(self: *Self, capacity: usize) Error!Slot {
        const read = self.read_end.val.load(.acquire);
        const write = self.write_end.val.load(.acquire);

        if (write >= capacity or read >= capacity)
            return Error.InvalidState;

        // write end is the limit, the number of available items can only grow
        const avail = if (write >= read)
            write - read
        else
            capacity - read + write;
        if (avail > capacity)
            return Error.InvalidState;

        return Slot{
            .first = read,
            .len = avail,
        };
    }

    pub fn acquire(self: *Self, n: usize, capacity: usize) Error!?Slot {
        if (n > capacity) return null;
        return (try self.uninitSlot(capacity)).take(n);
    }

    pub fn acquireUpTo(self: *Self, n: usize, capacity: usize) Error!?Slot {
        return (try self.uninitSlot(capacity)).min(n);
    }

    pub fn produce(self: *Self, acquired_slot: Slot, capacity: usize) Error!void {
        const new_write_end = (acquired_slot.first + acquired_slot.len) % capacity;
        const old = self.write_end.val.swap(new_write_end, .release);
        if (old != acquired_slot.first)
            return Error.InvalidState;
    }

    pub fn consume(self: *Self, n: usize, capacity: usize) Error!?Slot {
        if (n > capacity) return null;
        return (try self.initSlot(capacity)).take(n);
    }

    pub fn consumeUpTo(self: *Self, n: usize, capacity: usize) Error!?Slot {
        return (try self.initSlot(capacity)).min(n);
    }

    pub fn release(self: *Self, consumed_slot: Slot, capacity: usize) Error!void {
        const new_read_end = (consumed_slot.first + consumed_slot.len) % capacity;
        const old = self.read_end.val.swap(new_read_end, .release);
        if (old != consumed_slot.first)
            return Error.InvalidState;
    }
};
