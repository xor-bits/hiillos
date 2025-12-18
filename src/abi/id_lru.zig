const std = @import("std");

// PCID LRU cache implemented as an array and a queue

pub fn IdLru(comptime Int: type, capacity: usize) type {
    return struct {
        entries: *[capacity]LruEntry,

        first: Int,
        last: Int,

        const LruEntry = struct {
            prev: Int,
            next: Int,
        };

        pub fn init(alloc: std.mem.Allocator) std.mem.Allocator.Error!@This() {
            const entries = try alloc.create([capacity]LruEntry);

            for (0..capacity) |_i| {
                const i: Int = @truncate(_i);
                entries[i] = .{
                    .prev = i -| 1,
                    .next = i +| 1,
                };
            }

            return .{
                .entries = entries,
                .last = capacity - 1,
                .first = 0,
            };
        }

        pub fn update(self: *@This(), pcid: Int) void {
            self.remove(pcid);
            self.insertLast(pcid);
        }

        pub fn allocate(self: *@This()) Int {
            const first = self.first;
            self.remove(first);
            self.insertLast(first);
            return @intCast(first);
        }

        // fn print(self: *const @This()) void {
        //     log.info("first={} last={}", .{ self.first, self.last });
        //     for (self.entries, 0..) |entry, i| {
        //         log.info(" [{}]: prev={} next={}", .{ i, entry.prev, entry.next });
        //     }
        //     log.info("order:", .{});
        //     var cur = self.first;
        //     while (true) {
        //         log.info("{}", .{cur});
        //         if (cur == self.last) break;
        //         cur = self.entries[cur].next;
        //     }
        // }

        fn remove(self: *@This(), pcid: Int) void {
            const entry = self.entries[pcid];
            if (pcid == self.first) {
                self.first = entry.next;
            } else if (pcid == self.last) {
                self.last = entry.prev;
            } else {
                self.entries[pcid] = .{
                    .next = entry.next,
                    .prev = entry.prev,
                };
            }
        }

        fn insertLast(self: *@This(), pcid: Int) void {
            self.entries[pcid] = .{
                .prev = self.last,
                .next = undefined,
            };
            self.entries[self.last] = .{
                .prev = undefined,
                .next = pcid,
            };
            self.last = pcid;
        }
    };
}
