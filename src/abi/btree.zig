const std = @import("std");

const log = std.log.scoped(.btree);

//

pub const Error = std.mem.Allocator.Error;

pub const Config = struct {
    // node_len: usize = 100,
    node_size: usize = 0x1000,
    search: enum { linear, binary } = .binary,
};

pub fn BTreeMap(comptime K: type, comptime V: type, comptime cfg: Config) type {
    return struct {
        root: usize = 0,
        depth: usize = 0,

        pub const KV = struct {
            key: K,
            value: V,
        };

        pub const LeafNode = struct {
            used: usize = 0,
            keys: [MAX]K = undefined,
            vals: [MAX]V = undefined,

            pub const _MAX: usize = (cfg.node_size - @sizeOf(usize)) / (@sizeOf(K) + @sizeOf(V)) / 2 * 2;

            pub const MAX: usize = _MAX - 1;
            pub const MIN: usize = MAX / 2;
        };

        pub const BranchNode = struct {
            used: usize = 0,
            keys: [MAX]K = undefined,
            vals: [MAX]V = undefined,
            ptrs: [MAX + 1]usize = undefined,

            pub const _MAX: usize = (cfg.node_size - @sizeOf(usize) * 2) / (@sizeOf(K) + @sizeOf(V) + @sizeOf(usize)) / 2 * 2;

            pub const MAX: usize = _MAX - 1;
            pub const MIN: usize = MAX / 2;
        };

        const Node = struct {
            ptr: usize,
            used: *usize,
            keys: []K,
            vals: []V,
            ptrs: []usize,
            max: usize,
            min: usize,

            fn fromLeaf(node: *LeafNode) Node {
                return .{
                    .ptr = @intFromPtr(node),
                    .used = &node.used,
                    .keys = node.keys[0..],
                    .vals = node.vals[0..],
                    .ptrs = ([0]usize{})[0..],
                    .max = LeafNode.MAX,
                    .min = LeafNode.MIN,
                };
            }

            fn fromBranch(node: *BranchNode) Node {
                return .{
                    .ptr = @intFromPtr(node),
                    .used = &node.used,
                    .keys = node.keys[0..],
                    .vals = node.vals[0..],
                    .ptrs = node.ptrs[0..],
                    .max = BranchNode.MAX,
                    .min = BranchNode.MIN,
                };
            }
        };

        fn getNode(node_ptr: usize, depth: usize) ?Node {
            if (depth == 0) {
                const node: *LeafNode = @as(?*LeafNode, @ptrFromInt(node_ptr)) orelse return null;
                return Node.fromLeaf(node);
            } else {
                const node: *BranchNode = @as(?*BranchNode, @ptrFromInt(node_ptr)) orelse return null;
                return Node.fromBranch(node);
            }
        }

        fn insertArr(comptime T: type, arr: []T, len: usize, i: usize, val: T) void {
            std.debug.assert(i <= len and len <= arr.len);
            arr[len] = val;
            std.mem.rotate(T, arr[0 .. len + 1][i..], 1);
        }

        fn removeArr(comptime T: type, arr: []T, len: usize, i: usize) T {
            std.debug.assert(i < len and len <= arr.len);
            const val = arr[i];
            std.mem.copyForwards(T, arr[i .. len - 1], arr[i + 1 .. len]);
            return val;
        }

        comptime {
            std.debug.assert(@sizeOf(LeafNode) <= cfg.node_size);
            std.debug.assert(@sizeOf(BranchNode) <= cfg.node_size);

            if (LeafNode.MIN == 0 or BranchNode.MIN == 0)
                @compileError("node_size too small");
        }

        const IndexResult = union(enum) {
            /// the key is in `keys[i]` and its value is in `vals[i]`
            found: usize,
            /// the key and value are in a sub-tree at `ptrs[i]`
            not_found: usize,
        };

        fn indexOf(key: K, keys: []const K) IndexResult {
            var idx: usize = undefined;
            if (cfg.search == .binary) {
                idx = std.sort.lowerBound(
                    K,
                    keys,
                    key,
                    struct {
                        fn inner(ctx: K, cursor: K) std.math.Order {
                            return std.math.order(ctx, cursor);
                        }
                    }.inner,
                );
            } else {
                idx = 0;
                while (idx < keys.len and keys[idx] < key) : (idx += 1) {}
            }

            if (idx >= keys.len or keys[idx] != key) {
                return .{ .not_found = idx };
            } else {
                return .{ .found = idx };
            }
        }

        /// insert `val` at `key`, returning the old value
        pub fn insert(self: *@This(), alloc: std.mem.Allocator, key: K, val: V) Error!?V {
            // lazy init, happens only once
            if (self.root == 0) {
                @branchHint(.cold);
                const node: *LeafNode = try alloc.create(LeafNode);
                node.* = .{};

                node.keys[0] = key;
                node.vals[0] = val;
                node.used = 1;

                self.root = @intFromPtr(node);
                return null;
            }

            // split full nodes pre-emptitively
            const root = getNode(self.root, self.depth).?;
            if (root.used.* == root.max) try self.splitRoot(alloc);

            return insertRecurse(alloc, key, val, self.root, self.depth);
        }

        fn insertRecurse(
            alloc: std.mem.Allocator,
            key: K,
            val: V,
            root: usize,
            depth: usize,
        ) Error!?V {
            const node = getNode(root, depth).?;
            std.debug.assert(node.used.* != node.max);

            // replace if the slot is already in use
            var i = switch (indexOf(key, node.keys[0..node.used.*])) {
                .found => |i| {
                    const old = node.vals[i];
                    node.vals[i] = val;
                    return old;
                },
                .not_found => |i| i,
            };

            // if its a leaf node: insert
            // if its a branch node: continue
            if (depth == 0) {
                insertArr(K, node.keys[0..], node.used.*, i, key);
                insertArr(V, node.vals[0..], node.used.*, i, val);
                node.used.* += 1;
                return null;
            } else {
                // split full nodes pre-emptitively
                if (isFull(node.ptrs[i], depth - 1)) {
                    try splitNthChild(alloc, root, depth, i);
                    if (key > node.keys[i]) i += 1;
                }

                return insertRecurse(alloc, key, val, node.ptrs[i], depth - 1);
            }
        }

        pub fn debug(self: *@This()) void {
            if (self.root == 0) return;
            debugRecurse(self.root, self.depth);
        }

        fn debugRecurse(root: usize, depth: usize) void {
            const node = getNode(root, depth) orelse return;

            if (depth == 0) {
                log.info("---------\\/\\/ leaf depth={}", .{depth});
            } else {
                log.info("---------\\/\\/ branch depth={}", .{depth});
            }
            for (node.keys[0..node.used.*]) |key| {
                log.info("{}", .{key});
            }
            log.info("---------", .{});

            if (depth != 0) {
                for (node.ptrs[0 .. node.used.* + 1]) |next| {
                    debugRecurse(next, depth - 1);
                }
            }
        }

        /// insert `val` at `key`, returning it if it already exists
        pub fn tryInsert(self: *@This(), key: K, val: V) ?V {
            _ = .{ self, key, val };
            @panic("todo");
        }

        pub fn remove(self: *@This(), key: K) ?KV {
            _ = .{ self, key };
            @panic("todo");
        }

        pub fn get(self: *const @This(), key: K) ?*V {
            return getRecurse(key, self.root, self.depth);
        }

        fn getRecurse(key: K, root: usize, depth: usize) ?*V {
            const node = getNode(root, depth) orelse return null;

            const i = switch (indexOf(key, node.keys[0..node.used.*])) {
                .found => |i| return &node.vals[i],
                .not_found => |i| i,
            };

            if (depth == 0) {
                return null;
            } else {
                return getRecurse(key, node.ptrs[i], depth - 1);
            }
        }

        fn isFull(root: usize, depth: usize) bool {
            const node = getNode(root, depth).?;
            return node.used.* == node.max;
        }

        fn splitNthChild(alloc: std.mem.Allocator, root: usize, depth: usize, n: usize) Error!void {
            // log.info("splitNthChild(root={}, depth={}, n={})", .{ root, depth, n });
            if (depth == 0) unreachable;

            const parent: *BranchNode = @as(?*BranchNode, @ptrFromInt(root)).?;
            std.debug.assert(parent.used != BranchNode.MAX);

            const full_node = getNode(parent.ptrs[n], depth - 1).?;
            std.debug.assert(full_node.used.* == full_node.max);

            var new_node: Node = undefined;
            if (depth == 1) {
                const node = try alloc.create(LeafNode);
                node.* = .{};
                new_node = Node.fromLeaf(node);
            } else {
                const node = try alloc.create(BranchNode);
                node.* = .{};
                new_node = Node.fromBranch(node);
            }

            // copy the right half (maybe less than the minimum, so it becomes invalid) to the new node
            std.mem.copyForwards(K, new_node.keys[0..], full_node.keys[full_node.min + 1 ..]);
            std.mem.copyForwards(V, new_node.vals[0..], full_node.vals[full_node.min + 1 ..]);
            if (depth != 1) // move the children also if its a branch node
                std.mem.copyForwards(usize, new_node.ptrs[0..], full_node.ptrs[full_node.min + 2 ..]);
            // move the first one from the right half to the parent
            insertArr(K, parent.keys[0..], parent.used, n, full_node.keys[full_node.min]);
            insertArr(V, parent.vals[0..], parent.used, n, full_node.vals[full_node.min]);
            // add the new child
            insertArr(usize, parent.ptrs[0..], parent.used + 1, n + 1, new_node.ptr);

            full_node.used.* = full_node.min;
            new_node.used.* = full_node.max - full_node.min - 1;
            parent.used += 1;
        }

        fn splitRoot(self: *@This(), alloc: std.mem.Allocator) Error!void {
            const new_root = try alloc.create(BranchNode);
            new_root.* = .{};
            new_root.ptrs[0] = self.root;
            new_root.used = 0;

            self.root = @intFromPtr(new_root);
            self.depth += 1;
            // FIXME: recover from errors
            try splitNthChild(alloc, self.root, self.depth, 0);
        }
    };
}

// test "fuzz" {
//     std.testing.fuzz({}, struct {
//         fn testOne(_: void, _input: []const u8) anyerror!void {
//             var input = _input;

//             var treemap = BTreeMap(usize, usize, .{}){};
//             var hashmap = std.HashMap(usize, usize, {}, 80);

//             while (input.len >= 24) {
//                 const op: usize = std.mem.readInt(usize, @ptrCast(&input[0]), .little);
//                 const key: usize = std.mem.readInt(usize, @ptrCast(&input[1]), .little);
//                 const val: usize = std.mem.readInt(usize, @ptrCast(&input[2]), .little);

//                 switch (op) {
//                     0 => {
//                         try treemap.insert(std.testing.allocator, key, val);
//                         try hashmap.put(std.testing.allocator, key, val);
//                     },

//                     1 => {
//                         const v1 = treemap.remove(key);
//                         const v2 = hashmap.fetchRemove(key);
//                         v2.?.value
//                     },
//                 }
//             }

//             if (input.len <= 1)
//                 return;

//             input[0];

//             const map =
//                 BTreeMap(usize, usize, .{ .search = .linear });
//         }
//     }.testOne, .{});
// }
