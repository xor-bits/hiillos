const std = @import("std");
const abi = @import("abi");
const gui = @import("gui");
const rbtree = @import("rbtree");

const caps = abi.caps;
const log = std.log.scoped(.game);

pub const std_options = abi.std_options;
pub const panic = abi.panic;
comptime {
    abi.rt.installRuntime();
}

var input_buffer: abi.ring.Ring(Input) = undefined;
var should_stop: std.atomic.Value(bool) = .init(false);
const max_rooms = 8;
const random_connections = 4;
const max_spawns = 8;
const spawn_attempts = 20;
// const tick_speed = 50_000_000;
const tick_speed = 500_000_000;

fn StaticArrayList(comptime T: type, comptime max: usize) type {
    return struct {
        data: [max]T = undefined,
        size: usize = 0,

        fn isFull(
            self: *const @This(),
        ) bool {
            return self.size == max;
        }

        fn push(
            self: *@This(),
            item: T,
        ) void {
            std.debug.assert(!self.isFull());
            self.data[self.size] = item;
            self.size += 1;
        }

        fn pushOverwrite(
            self: *@This(),
            item: T,
        ) void {
            if (self.isFull()) {
                @branchHint(.cold);
                self.size -= 1;
            }
            self.data[self.size] = item;
            self.size += 1;
        }

        fn pop(
            self: *@This(),
        ) ?T {
            if (self.size == 0) return null;
            self.size -= 1;
            return self.data[self.size];
        }

        fn swapRemove(self: *@This(), i: usize) T {
            const size = self.size;
            const last = self.pop().?;
            if (size - 1 == i) return last;
            defer self.data[i] = last;
            return self.data[i];
        }
    };
}

pub fn main() !void {
    try abi.rt.init();

    var stdout_buf: [0x1000]u8 = undefined;
    var stdout_writer = abi.io.stdout.writer(&stdout_buf);
    const writer = &stdout_writer.interface;

    input_buffer = try .new(0x1000);
    try abi.thread.spawn(inputReader, .{});
    try abi.thread.spawn(timeReader, .{});

    const time: u64 = @truncate(abi.time.nanoTimestamp());
    var default_prng = std.Random.DefaultPrng.init(time);
    const rng = default_prng.random();

    // abi.escape.setForeground(count: usize);
    try writer.print("{f}{f}", .{
        abi.escape.eraseInDisplay(.start_to_end),
        abi.escape.cursorPush(),
    });
    try writer.flush();

    // 8x8 grid of physical rooms
    var rooms: [max_rooms]Room = undefined;
    for (&rooms) |*room| {
        room.* = .generate(rng);
    }
    const spawn: Point = .{ .x = 1, .y = 1 };

    var state: GameState = .{
        .rooms = &rooms,
        .rng = rng,
        .open_set_alloc = .init(abi.mem.server_page_allocator),
    };
    connectRooms(&state, rng);
    state.rooms[0].state = .cleared;
    state.rooms[0].buildDoors();
    enterRoom(&state, .spawn, spawn);

    while (true) {
        if (should_stop.load(.acquire)) break;
        try draw(&state, writer);
        const input = try input_buffer.popWait();
        tick(&state, input);
    }
}

fn inputReader() !void {
    var stdin_buf: [0x1000]u8 = undefined;
    var stdin_writer = abi.io.stdin.reader(&stdin_buf);
    const reader = &stdin_writer.interface;

    while (true) {
        const key = reader.takeByte() catch |err| switch (err) {
            error.ReadFailed => return err,
            error.EndOfStream => return,
        };

        const input = switch (key) {
            'w' => Input.move_up,
            's' => Input.move_down,
            'a' => Input.move_left,
            'd' => Input.move_right,
            'i' => Input.shoot_up,
            'k' => Input.shoot_down,
            'j' => Input.shoot_left,
            'l' => Input.shoot_right,
            'q' => Input.quit,
            'r' => Input.enable_ai,
            'f' => Input.disable_ai,
            else => continue,
        };
        try input_buffer.pushWait(input);
        if (input == .quit) {
            should_stop.store(true, .release);
            break;
        }
    }
}

fn timeReader() !void {
    while (true) {
        abi.time.sleep(tick_speed);
        if (should_stop.load(.acquire)) break;
        try input_buffer.pushWait(Input.tick);
    }
}

fn connectRooms(
    state: *GameState,
    rng: std.Random,
) void {
    var connected: usize = 1;
    var gas: usize = 10000;
    while (connected != state.rooms.len) {
        gas -= 1;
        if (gas == 0) {
            log.err("failed to generate rooms", .{});
            break;
        }

        const connect_from: Room.Id = @enumFromInt(rng.intRangeLessThan(
            usize,
            0,
            connected,
        ));
        const connect_to: Room.Id = @enumFromInt(connected);
        // const connect_to: Room.Id = @enumFromInt(rng.intRangeLessThan(
        //     usize,
        //     connected,
        //     state.rooms.len,
        // ));

        connectRandomly(
            state,
            connect_from,
            connect_to,
            rng,
        ) catch continue;
        connected += 1;
        abi.syslog("mandatory connection {}-{}", .{
            @intFromEnum(connect_from),
            @intFromEnum(connect_to),
        });
    }

    for (0..random_connections) |_| {
        const connect_from: Room.Id = @enumFromInt(rng.intRangeLessThan(
            usize,
            0,
            state.rooms.len,
        ));
        const connect_to: Room.Id = @enumFromInt(rng.intRangeLessThan(
            usize,
            0,
            state.rooms.len,
        ));

        connectRandomly(
            state,
            connect_from,
            connect_to,
            rng,
        ) catch continue;
        abi.syslog("random connection {}-{}", .{
            @intFromEnum(connect_from),
            @intFromEnum(connect_to),
        });
    }

    // for (state.rooms) |*room| {
    //     room.buildDoors();
    // }
}

fn connectRandomly(
    state: *GameState,
    connect_from: Room.Id,
    connect_to: Room.Id,
    rng: std.Random,
) error{CannotConnect}!void {
    var dirs: std.EnumArray(Direction, bool) = .initUndefined();
    inline for (comptime std.enums.values(Direction)) |dir| {
        const from = state.rooms[@intFromEnum(connect_from)].doors.get(dir);
        const to = state.rooms[@intFromEnum(connect_to)].doors.get(dir.flip());
        dirs.set(dir, from.destination == .null and to.destination == .null);
    }

    const dir = randomDirection(
        rng,
        dirs,
    ) orelse return error.CannotConnect;
    Room.connect(state.rooms, connect_from, connect_to, dir);
}

fn randomDirection(
    rng: std.Random,
    dirs: std.EnumArray(Direction, bool),
) ?Direction {
    var packed_dirs: StaticArrayList(Direction, 4) = .{};
    inline for (comptime std.enums.values(Direction)) |dir| {
        if (dirs.get(dir)) packed_dirs.push(dir);
    }
    if (packed_dirs.size == 0) return null;
    const rng_idx = rng.intRangeLessThan(usize, 0, packed_dirs.size);
    return packed_dirs.data[rng_idx];
}

fn draw(
    state: *GameState,
    writer: *std.Io.Writer,
) !void {
    const room = &state.rooms[@intFromEnum(state.current_room)];

    var bg = abi.util.Colour.black;
    var fg = abi.util.Colour.white;
    try writer.print("{f}{f}{f}{f}", .{
        abi.escape.cursorPop(),
        abi.escape.setBackground(bg),
        abi.escape.setForeground(fg),
        abi.escape.eraseInDisplay(.start_to_end),
    });
    for (room.tiles, room.objects) |tile_row, object_row| {
        for (tile_row, object_row) |tile, object| {
            const new_bg = tile.color();
            if (!std.meta.eql(bg, new_bg)) {
                bg = new_bg;
                try writer.print("{f}", .{
                    abi.escape.setBackground(bg),
                });
            }

            const new_fg = object.color();
            if (new_fg != null and !std.meta.eql(fg, new_fg.?)) {
                fg = new_fg.?;
                try writer.print("{f}", .{
                    abi.escape.setForeground(fg),
                });
            }

            try writer.writeByte(object.char());
        }
        try writer.writeByte('\n');
    }
    try writer.print("ROOM: {} ; SCORE: {}\n", .{
        @intFromEnum(state.current_room), state.score,
    });
    if (state.game_over != .running) {
        const msg = switch (state.game_over) {
            .won => "WON",
            .lost => "LOST",
            .running => unreachable,
        };
        try writer.print("YOU {s}\npress Q to exit\n", .{
            msg,
        });
    }
    try writer.print("{f}", .{
        abi.escape.reset(),
    });
    try writer.flush();
}

fn tick(
    state: *GameState,
    input: Input,
) void {
    const room = &state.rooms[@intFromEnum(state.current_room)];
    // std.debug.assert(.player == room.objects[state.player_pos.y][state.player_pos.x]);
    // room.objects[state.player_pos.y][state.player_pos.x] = .player;

    for (state.bullets.data[0..state.bullets.size]) |*bullet| {
        room.objects[bullet.pos.y][bullet.pos.x] = .empty;
    }
    var updated_already: [Display.h][Display.w]bool = @splat(@splat(false));
    for (0..room.h) |y| for (0..room.w) |x| {
        const pos: Point = .{ .x = @intCast(x), .y = @intCast(y) };
        if (updated_already[pos.y][pos.x]) continue;
        if (room.tiles[y][x] == .lava) {
            room.objects[y][x] = .empty;
            continue;
        }
        if (room.objects[y][x] == .enemy) {
            std.debug.assert(y != 0);
            std.debug.assert(y + 1 != room.h);
            std.debug.assert(x != 0);
            std.debug.assert(x + 1 != room.w);

            // inline for (comptime std.enums.values(Direction)) |dir| {
            //     const neighbour = dir.move(pos);
            //     if (room.objects[neighbour.y][neighbour.x] == .player) {
            //         room.objects[y][x] = .empty;
            //         room.objects[neighbour.y][neighbour.x] = .enemy;
            //         state.game_over = .lost;
            //         continue :object_loop;
            //     }
            // }

            if (state.rng.float(f32) > 0.2) continue;

            const dir = state.player_flowfield.dirs[pos.y][pos.x];
            const new = dir.move(.{ .x = @truncate(x), .y = @truncate(y) });
            switch (room.objects[new.y][new.x]) {
                .player => {
                    room.objects[y][x] = .empty;
                    room.objects[new.y][new.x] = .enemy;
                    state.game_over = .lost;
                    updated_already[new.y][new.x] = true;
                },
                .empty => {
                    room.objects[y][x] = .empty;
                    room.objects[new.y][new.x] = .enemy;
                    updated_already[new.y][new.x] = true;
                },
                else => {},
            }

            // var dirs: std.EnumArray(Direction, bool) = .initUndefined();
            // inline for (comptime std.enums.values(Direction)) |dir| {
            //     const dst = dir.move(pos);
            //     dirs.set(dir, room.objects[dst.y][dst.x] == .empty and
            //         room.tiles[dst.y][dst.x] == .floor);
            // }
            // const dir = randomDirection(
            //     state.rng,
            //     dirs,
            // ) orelse continue;

            // const new = dir.move(.{ .x = @truncate(x), .y = @truncate(y) });
            // room.objects[y][x] = .empty;
            // room.objects[new.y][new.x] = .enemy;

        }
    };
    var i: u8 = 0;
    while (i < state.bullets.size) {
        const bullet = &state.bullets.data[i];
        const dst = bullet.dir.move(bullet.pos);
        switch (room.objects[dst.y][dst.x]) {
            .bullet => unreachable,
            .empty => {
                bullet.pos = dst;
                i += 1;
                continue;
            },
            .enemy => {
                _ = state.bullets.swapRemove(i);
                killEnemy(state, dst);
                continue;
            },
            else => {
                _ = state.bullets.swapRemove(i);
                continue;
            },
        }
        comptime unreachable;
    }
    // i = 0;
    // while (i < state.bullets.size) {
    //     const bullet = &state.bullets.data[i];
    //     if ()
    //     std.debug.assert(room.objects[bullet.pos.y][bullet.pos.x] == .empty);
    //     room.objects[bullet.pos.y][bullet.pos.x] = .bullet;
    //     i += 1;
    // }
    for (state.bullets.data[0..state.bullets.size]) |*bullet| {
        std.debug.assert(room.objects[bullet.pos.y][bullet.pos.x] == .empty);
        room.objects[bullet.pos.y][bullet.pos.x] = .bullet;
    }
    if (room.tiles[state.player_pos.y][state.player_pos.x] == .lava) {
        state.game_over = .lost;
        return;
    }

    if (state.game_over == .lost) return;
    switch (input) {
        .move_up => movePlayer(state, .north),
        .move_down => movePlayer(state, .south),
        .move_left => movePlayer(state, .west),
        .move_right => movePlayer(state, .east),
        .shoot_up => shoot(state, .north),
        .shoot_down => shoot(state, .south),
        .shoot_left => shoot(state, .west),
        .shoot_right => shoot(state, .east),
        .quit => {},
        .tick => {
            if (state.ai == .disabled) return;
            aiTick(state);
        },
        .enable_ai => state.ai = .enabled,
        .disable_ai => state.ai = .disabled,
    }
}

fn aiTick(
    state: *GameState,
) void {
    // the AI player is not allowed to know which
    // doors lead to where, it has to check them

    if (state.game_over != .running) return;

    const room = &state.rooms[@intFromEnum(state.current_room)];
    const player = state.player_pos;
    var closest_enemy: ?struct {
        pos: Point,
        dst_sqr: u16,
    } = null;
    var found_coin = false;

    // O(n²) object scan
    for (0..room.h) |y| for (0..room.w) |x| {
        if (room.objects[y][x] == .coin) found_coin = true;
        if (room.objects[y][x] != .enemy) continue;
        const pos: Point = .{ .x = @intCast(x), .y = @intCast(y) };
        const dst_sqr = player.distanceSquared(pos);
        if (closest_enemy == null or closest_enemy.?.dst_sqr > dst_sqr) {
            closest_enemy = .{ .pos = pos, .dst_sqr = dst_sqr };
        }
    };

    // O(1) shooting
    if (closest_enemy != null) {
        const shoot_dir = player.directionTo(closest_enemy.?.pos);
        abi.syslog("AI tick shoot {t}", .{shoot_dir});
        shoot(state, shoot_dir);
        return;
    }

    // O(n²) coin pathfind (here only O(1))
    if (found_coin) {
        const walk_dir = state.coin_flowfield.dirs[player.y][player.x];
        // const walk_dir = pathfindTiles(state, closest_coin.?.pos, player);
        abi.syslog("AI tick coin {t}", .{walk_dir});
        movePlayer(state, walk_dir);
        return;
    }

    // O(n²) unexplored door pathfind (here only O(1))
    for (std.enums.values(Direction)) |dir| {
        if (room.doors.get(dir).ai_explored or room.doors.get(dir).destination == .null) continue;
        const walk_dir = state.door_flowfields.get(dir).dirs[player.y][player.x];
        abi.syslog("AI tick unexplored door {t} (move {t})", .{ dir, walk_dir });
        movePlayer(state, walk_dir);
        return;
    }

    // O(n log n) unexplored room pathfind
    if (pathfindClosestUnexploredDoor(state)) |door_dir| {
        const walk_dir = state.door_flowfields.get(door_dir).dirs[player.y][player.x];
        abi.syslog("AI tick unexplored door other room {t} (move {t})", .{ door_dir, walk_dir });
        movePlayer(state, walk_dir);
        return;
    }

    abi.syslog("AI tick confused", .{});
}

// O(|E| + |V| log |V|) ≈ O(N log N) for N rooms
fn pathfindClosestUnexploredDoor(
    state: *GameState,
) ?Direction {
    defer _ = state.open_set_alloc.reset(.retain_capacity);

    var came_from: [max_rooms]Direction = undefined;
    var g_score: [max_rooms]u16 = @splat(std.math.maxInt(u16));
    var open_set: rbtree.RedBlackTree = .{};

    const start_node: *OpenSetNode = state.open_set_alloc.create() catch @panic("OOM");
    start_node.* = .{
        .f_score = 0,
        .pos = state.current_room,
    };
    std.debug.assert(open_set.put(OpenSetNode.cmp, &start_node.node) == null);
    g_score[@intFromEnum(state.current_room)] = 0;

    while (open_set.first) |first| {
        const current_ptr: *OpenSetNode = @fieldParentPtr("node", first);
        const current = current_ptr.*;

        if (state.rooms[@intFromEnum(current.pos)].hasUnexploredDoors()) {
            abi.syslog("path found from {} to {} via (reversed):", .{
                @intFromEnum(state.current_room),
                @intFromEnum(current.pos),
            });
            // abi.syslog(comptime fmt: []const u8, args: anytype)

            var reverse_path: Room.Id = current.pos;
            var first_dir: Direction = came_from[@intFromEnum(current.pos)];
            var n: usize = 0;
            while (reverse_path != state.current_room) {
                n += 1;
                if (n >= 200)
                    @panic("invalid path");

                first_dir = came_from[@intFromEnum(reverse_path)];
                abi.syslog(" - {t}", .{first_dir});
                reverse_path = state.rooms[@intFromEnum(reverse_path)]
                    .doors.get(first_dir).destination;
            }
            return first_dir.flip();
        }

        open_set.remove(first);
        state.open_set_alloc.destroy(current_ptr);

        for (std.enums.values(Direction)) |neighbour_dir| {
            const neighbour_pos = state.rooms[@intFromEnum(current.pos)].doors.get(neighbour_dir).destination;
            if (neighbour_pos == .null) continue;

            const neighbour_g_score = g_score[@intFromEnum(current.pos)] + 1;
            if (neighbour_g_score < g_score[@intFromEnum(neighbour_pos)]) {
                came_from[@intFromEnum(neighbour_pos)] = neighbour_dir.flip();
                g_score[@intFromEnum(neighbour_pos)] = neighbour_g_score;
                const node: *OpenSetNode = state.open_set_alloc.create() catch @panic("OOM");
                node.* = .{
                    .f_score = 0,
                    .pos = neighbour_pos,
                };
                if (open_set.put(OpenSetNode.cmp, &node.node)) |old| {
                    state.open_set_alloc.destroy(@fieldParentPtr("node", old));
                }
            }
        }
    }

    return null;
}

// unused A* pathfinder
// O(|E| log |V|) ≈ O(N² log N) for a grid of size N
fn pathfindTiles(
    state: *GameState,
    from: Point,
    to: Point,
) Direction {
    const room = &state.rooms[@intFromEnum(state.current_room)];

    defer _ = state.open_set_alloc.reset(.retain_capacity);

    var open_set: rbtree.RedBlackTree = .{};
    var g_score: [Display.h][Display.w]u32 = @splat(@splat(std.math.maxInt(u32)));
    // var f_score: [Display.h ][ Display.w]u32 = @splat(std.math.maxInt(u32));
    var came_from: [Display.h][Display.w]Direction = undefined;

    const start_node: *OpenSetNode = state.open_set_alloc.create() catch @panic("OOM");
    start_node.* = .{
        .f_score = from.distanceManhattan(to),
        .pos = from,
    };
    std.debug.assert(open_set.put(OpenSetNode.cmp, &start_node.node) == null);
    g_score[from.y][from.x] = 0;

    while (open_set.first) |first| {
        const current_ptr: *OpenSetNode = @fieldParentPtr("node", first);
        const current = current_ptr.*;

        if (current.pos.x == to.x and current.pos.y == to.y) {
            return came_from[to.y][to.x];
        }

        open_set.remove(first);
        state.open_set_alloc.destroy(current_ptr);

        std.debug.assert(current.pos.y != 0);
        std.debug.assert(current.pos.y + 1 != room.h);
        std.debug.assert(current.pos.x != 0);
        std.debug.assert(current.pos.x + 1 != room.w);
        for (std.enums.values(Direction)) |neighbour_dir| {
            const neighbour_pos = neighbour_dir.move(current.pos);
            if (room.objects[neighbour_pos.y][neighbour_pos.x] != .empty and
                room.objects[neighbour_pos.y][neighbour_pos.x] != .enemy and
                room.objects[neighbour_pos.y][neighbour_pos.x] != .coin and
                room.objects[neighbour_pos.y][neighbour_pos.x] != .player) continue;
            if (room.tiles[neighbour_pos.y][neighbour_pos.x] != .floor) continue;

            const neighbour_g_score = g_score[current.pos.y][current.pos.x] + 1;
            if (neighbour_g_score < g_score[neighbour_pos.y][neighbour_pos.x]) {
                came_from[neighbour_pos.y][neighbour_pos.x] = neighbour_dir;
                g_score[neighbour_pos.y][neighbour_pos.x] = neighbour_g_score;
                const node: *OpenSetNode = state.open_set_alloc.create() catch @panic("OOM");
                node.* = .{
                    .f_score = neighbour_pos.distanceManhattan(to),
                    .pos = from,
                };
                if (open_set.put(OpenSetNode.cmp, &node.node)) |old| {
                    state.open_set_alloc.destroy(@fieldParentPtr("node", old));
                }
            }
        }
    }

    return .north;
}

const OpenSetNode = struct {
    f_score: u16,
    pos: Room.Id,
    node: rbtree.RedBlackTree.Node = .{},
    fn cmp(
        lhs: *const rbtree.RedBlackTree.Node,
        rhs: *const rbtree.RedBlackTree.Node,
    ) std.math.Order {
        const _lhs: *const @This() = @fieldParentPtr("node", lhs);
        const _rhs: *const @This() = @fieldParentPtr("node", rhs);
        const ord = std.math.order(_lhs.f_score, _rhs.f_score);
        if (ord != .eq) return ord;
        return std.math.order(@intFromEnum(_lhs.pos), @intFromEnum(_rhs.pos));
    }
};

fn shoot(
    state: *GameState,
    dir: Direction,
) void {
    const room = &state.rooms[@intFromEnum(state.current_room)];
    const pos = dir.move(state.player_pos);
    if (room.objects[pos.y][pos.x] == .enemy) {
        killEnemy(state, pos);
        return;
    }
    if (room.objects[pos.y][pos.x] != .empty) return;
    state.bullets.pushOverwrite(.{ .pos = pos, .dir = dir });
    room.objects[pos.y][pos.x] = .bullet;
}

fn movePlayer(
    state: *GameState,
    dir: Direction,
) void {
    const room = &state.rooms[@intFromEnum(state.current_room)];
    const from = state.player_pos;
    const to = dir.move(from);
    std.debug.assert(.empty != room.objects[from.y][from.x]);
    const door_dir = switch (room.objects[to.y][to.x]) {
        .empty => {
            state.player_pos = to;
            room.objects[to.y][to.x] = room.objects[from.y][from.x];
            room.objects[from.y][from.x] = .empty;
            state.player_flowfield = buildFlowfield(state, .player);
            return;
        },
        .coin => {
            state.score += 10;
            state.player_pos = to;
            room.objects[to.y][to.x] = room.objects[from.y][from.x];
            room.objects[from.y][from.x] = .empty;
            rebuildFlowfields(state);
            return;
        },
        .door_north => Direction.north,
        .door_south => Direction.south,
        .door_west => Direction.west,
        .door_east => Direction.east,
        else => return,
    };
    room.objects[from.y][from.x] = .empty;
    const next_room_id = room.doors.get(door_dir).destination;
    std.debug.assert(next_room_id != .null);
    const next_room = &state.rooms[@intFromEnum(next_room_id)];
    if (state.ai == .enabled) {
        room.doors.getPtr(door_dir).ai_explored = true;
        next_room.doors.getPtr(door_dir.flip()).ai_explored = true;
    }
    var pos: Point = .{
        .x = @min(@as(u32, from.x) * next_room.w / room.w, next_room.w),
        .y = @min(@as(u32, from.y) * next_room.h / room.h, next_room.h),
    };
    switch (door_dir) {
        .north => pos.y = next_room.h - 2,
        .south => pos.y = 1,
        .west => pos.x = next_room.w - 2,
        .east => pos.x = 1,
    }
    enterRoom(state, next_room_id, pos);
}

fn enterRoom(
    state: *GameState,
    room_id: Room.Id,
    pos: Point,
) void {
    abi.syslog("moved to room {}", .{@intFromEnum(room_id)});
    const old_room = &state.rooms[@intFromEnum(state.current_room)];
    const room = &state.rooms[@intFromEnum(room_id)];

    for (0..old_room.h) |y| for (0..old_room.w) |x| {
        switch (old_room.objects[y][x]) {
            .bullet => old_room.objects[y][x] = .empty,
            .enemy => unreachable,
            else => {},
        }
    };
    state.bullets.size = 0;
    state.current_room = room_id;
    state.player_pos = pos;
    room.objects[state.player_pos.y][state.player_pos.x] = .player;
    rebuildFlowfields(state);

    if (room_id != .spawn and room.state == .cleared and state.rng.float(f32) <= 0.2) {
        room.state = .unexplored;
    }

    if (room.state == .unexplored) {
        for (0..max_spawns) |_| {
            spawnEnemy(state);
        }
    }
}

fn rebuildFlowfields(
    state: *GameState,
) void {
    state.player_flowfield = buildFlowfield(state, .player);
    state.coin_flowfield = buildFlowfield(state, .coin);
    state.door_flowfields.set(.north, buildFlowfield(state, .door_north));
    state.door_flowfields.set(.south, buildFlowfield(state, .door_south));
    state.door_flowfields.set(.west, buildFlowfield(state, .door_west));
    state.door_flowfields.set(.east, buildFlowfield(state, .door_east));
}

fn spawnEnemy(
    state: *GameState,
) void {
    const room = &state.rooms[@intFromEnum(state.current_room)];
    const player = state.player_pos;

    // if (state.enemies.isFull()) return;
    for (0..spawn_attempts) |_| {
        const x = state.rng.intRangeLessThan(u8, 1, room.w - 1);
        const y = state.rng.intRangeLessThan(u8, 1, room.h - 1);
        const xd = @abs(@as(i16, player.x) - @as(i16, x));
        const yd = @abs(@as(i16, player.y) - @as(i16, y));

        if (room.tiles[y][x] == .lava) continue;
        if (room.objects[y][x] != .empty) continue;
        if (xd * xd + yd * yd <= 30) continue;

        room.objects[y][x] = .enemy;
        state.enemies += 1;
        // state.enemies.push(.{ .pos = .{
        //     .x = x,
        //     .y = y,
        // } });
        break;
    }
}

fn killEnemy(
    state: *GameState,
    pos: Point,
) void {
    const room = &state.rooms[@intFromEnum(state.current_room)];
    std.debug.assert(room.objects[pos.y][pos.x] == .enemy);
    room.objects[pos.y][pos.x] = .empty;
    state.score += 1;
    state.enemies -= 1;
    if (state.enemies == 0) {
        room.state = .cleared;
        room.buildDoors();
        rebuildFlowfields(state);

        for (state.rooms, 0..) |other_room, i| {
            if (other_room.state != .cleared) {
                abi.syslog("room {} not cleared", .{i});
                return;
            }
        }
        state.game_over = .won;
    }
}

fn buildFlowfield(
    state: *GameState,
    dst: Object,
    // dst: Point,
) Flowfield {
    const room = &state.rooms[@intFromEnum(state.current_room)];

    var flowfield: Flowfield = .{};
    var g_score: [Display.h][Display.w]u16 = @splat(@splat(std.math.maxInt(u16)));
    var open_set: StaticArrayList(Point, Display.w * Display.h) = .{};
    var in_open_set: [Display.h][Display.w]bool = @splat(@splat(false));

    for (0..room.h) |y| for (0..room.w) |x| {
        if (room.objects[y][x] != dst) continue;
        flowfield.dirs[y][x] = .south;
        g_score[y][x] = 0;
        open_set.push(.{ .x = @intCast(x), .y = @intCast(y) });
        in_open_set[y][x] = true;
    };

    if (open_set.size == 0) {
        abi.syslog("found no objects to pathfind to ({t})", .{dst});
    }

    while (open_set.pop()) |cur| {
        in_open_set[cur.y][cur.x] = false;

        for (std.enums.values(Direction)) |dir| {
            const neighbour_pos = dir.move(cur);
            if (neighbour_pos.x == cur.x and neighbour_pos.y == cur.y) continue;
            if (neighbour_pos.y >= room.h or neighbour_pos.x >= room.w) continue;
            if (room.tiles[neighbour_pos.y][neighbour_pos.x] != .floor) continue;
            if (room.objects[neighbour_pos.y][neighbour_pos.x] != .empty and
                room.objects[neighbour_pos.y][neighbour_pos.x] != .enemy and
                room.objects[neighbour_pos.y][neighbour_pos.x] != .player) continue;

            const neighbour_g_score = g_score[cur.y][cur.x] + 1;
            if (neighbour_g_score < g_score[neighbour_pos.y][neighbour_pos.x]) {
                flowfield.dirs[neighbour_pos.y][neighbour_pos.x] = dir.flip();
                g_score[neighbour_pos.y][neighbour_pos.x] = neighbour_g_score;
                if (!in_open_set[neighbour_pos.y][neighbour_pos.x]) {
                    open_set.push(neighbour_pos);
                }
                in_open_set[neighbour_pos.y][neighbour_pos.x] = true;
            }
        }
    }

    // var msg: [Display.h * (Display.w + 1)]u8 = undefined;
    // for (0..Display.h) |y| {
    //     for (0..Display.w) |x| {
    //         msg[x + y * (Display.w + 1)] = switch (flowfield.dirs[y][x]) {
    //             .north => '^',
    //             .south => ',',
    //             .west => '<',
    //             .east => '>',
    //         };
    //     }
    //     msg[Display.w + y * (Display.w + 1)] = '\n';
    // }
    // abi.syslog("{s}", .{msg});

    return flowfield;
}

const GameState = struct {
    rooms: []Room,
    player_pos: Point = .{ .x = 1, .y = 1 },
    /// pathfinder data for enemies to navigate towards the player
    player_flowfield: Flowfield = .{},
    /// pathfinder data for ai to collect coins
    coin_flowfield: Flowfield = .{},
    /// pathfinder data for ai to find doors
    door_flowfields: std.EnumArray(Direction, Flowfield) = .initFill(.{}),
    current_room: Room.Id = .spawn,
    bullets: StaticArrayList(Bullet, 100) = .{},
    enemies: u8 = 0,
    score: usize = 10,
    // enemies: StaticArrayList(Enemy, 10) = .{},
    rng: std.Random,
    game_over: enum { won, lost, running } = .running,
    // unexplored_rooms: u8 = max_rooms,
    // unexplored_doors: u8 = 4,
    ai: enum { enabled, disabled } = .disabled,
    open_set_alloc: std.heap.MemoryPool(OpenSetNode),
};

const Flowfield = struct {
    dirs: [Display.h][Display.w]Direction = @splat(@splat(.north)),
};

const Enemy = struct {
    pos: Point,
};

const Bullet = struct {
    pos: Point,
    dir: Direction,
};

const Input = enum {
    move_up,
    move_down,
    move_left,
    move_right,
    shoot_up,
    shoot_down,
    shoot_left,
    shoot_right,
    quit,
    tick,
    enable_ai,
    disable_ai,
};

const Point = struct {
    x: u8,
    y: u8,

    fn distanceSquared(self: @This(), other: @This()) u16 {
        const xd = @abs(@as(i16, self.x) - @as(i16, other.x));
        const yd = @abs(@as(i16, self.y) - @as(i16, other.y));
        return xd * xd + yd * yd;
    }

    fn distanceManhattan(self: @This(), other: @This()) u16 {
        const xd = @abs(@as(i16, self.x) - @as(i16, other.x));
        const yd = @abs(@as(i16, self.y) - @as(i16, other.y));
        return xd + yd;
    }

    fn directionTo(self: @This(), other: @This()) Direction {
        const xd = @abs(@as(i16, self.x) - @as(i16, other.x));
        const yd = @abs(@as(i16, self.y) - @as(i16, other.y));

        if (xd < yd) {
            if (self.y < other.y) {
                return .south;
            } else {
                return .north;
            }
        } else {
            if (self.x < other.x) {
                return .east;
            } else {
                return .west;
            }
        }
    }
};

const Direction = enum {
    north,
    south,
    west,
    east,

    fn flip(
        self: @This(),
    ) @This() {
        return switch (self) {
            .north => .south,
            .south => .north,
            .west => .east,
            .east => .west,
        };
    }

    fn move(
        self: @This(),
        point: Point,
    ) Point {
        return switch (self) {
            .north => .{ .x = point.x, .y = point.y -| 1 },
            .south => .{ .x = point.x, .y = point.y +| 1 },
            .west => .{ .x = point.x -| 1, .y = point.y },
            .east => .{ .x = point.x +| 1, .y = point.y },
        };
    }
};

const Tile = enum {
    floor,
    lava,

    fn color(self: @This()) abi.util.Colour {
        return switch (self) {
            .floor => .black,
            .lava => .red,
        };
    }
};

const Object = enum {
    wall,
    door_north,
    door_south,
    door_west,
    door_east,
    empty,
    player,
    enemy,
    bullet,
    coin,

    fn char(self: @This()) u8 {
        return switch (self) {
            .wall => '#',
            .door_north => '.',
            .door_south => '.',
            .door_west => '.',
            .door_east => '.',
            .empty => ' ',
            .player => 'o',
            .enemy => 'o',
            .bullet => '*',
            .coin => '$',
        };
    }

    fn color(self: @This()) ?abi.util.Colour {
        return switch (self) {
            .wall => .white,
            .door_north => .light_grey,
            .door_south => .light_grey,
            .door_west => .light_grey,
            .door_east => .light_grey,
            .empty => null,
            .player => .green,
            .enemy => .red,
            .bullet => .yellow,
            .coin => .yellow,
        };
    }
};

const Door = struct {
    destination: Room.Id = .null,
    ai_explored: bool = false,
};

const Room = struct {
    w: u8 = 0,
    h: u8 = 0,
    doors: std.EnumArray(Direction, Door) = .initFill(.{}),
    state: enum { unexplored, cleared } = .unexplored,
    tiles: [Display.h][Display.w]Tile = @splat(@splat(.floor)),
    objects: [Display.h][Display.w]Object = @splat(@splat(.empty)),

    const Id = enum(u8) {
        spawn,
        null = std.math.maxInt(u8),
        _,
    };

    fn generate(
        rng: std.Random,
    ) @This() {
        var room: @This() = .{};
        room.w = rng.intRangeAtMost(u8, 8, Display.w);
        room.h = rng.intRangeAtMost(u8, 8, Display.h);
        @memset(room.objects[0][0..room.w], .wall);
        @memset(room.objects[room.h - 1][0..room.w], .wall);
        for (1..room.h - 1) |y| {
            room.objects[y][0] = .wall;
            room.objects[y][room.w - 1] = .wall;
        }
        // const max_dist_from_wall = @min((room.w - 1) / 2, (room.h - 1) / 2);
        if (rng.float(f32) <= 0.6) {
            for (3..room.h - 3) |y| {
                for (3..room.w - 3) |x| {
                    // const dist_from_wall = @min(@min(x, room.w - x - 3), @min(y, room.h - y - 3));
                    // const lava_chance = @as(f32, @floatFromInt(dist_from_wall)) / @as(f32, @floatFromInt(max_dist_from_wall));
                    // room.tiles[y][x] = if (rng.float(f32) <= lava_chance) .lava else .floor;
                    room.tiles[y][x] = if (rng.float(f32) <= 0.2) .lava else .floor;
                }
            }
        }
        for (2..room.h - 2) |y| {
            for (2..room.w - 2) |x| {
                if (rng.float(f32) <= 0.02 and
                    room.objects[y][x] == .empty and
                    room.tiles[y][x] == .floor)
                {
                    room.objects[y][x] = .coin;
                }
            }
        }
        return room;
    }

    fn connect(
        rooms: []@This(),
        a: Room.Id,
        b: Room.Id,
        dir: Direction,
    ) void {
        rooms[@intFromEnum(a)].doors.getPtr(dir).destination = b;
        rooms[@intFromEnum(b)].doors.getPtr(dir.flip()).destination = a;
    }

    fn buildDoors(
        self: *@This(),
    ) void {
        const door_offset = 2;
        const door_width = door_offset * 2;

        const door_offset_x = self.w / 2 - door_offset;
        const door_offset_y = self.h / 2 - door_offset;

        if (self.doors.get(.north).destination != .null) {
            self.objects[0][door_offset_x..][0..door_width].* = @splat(.door_north);
        }
        if (self.doors.get(.south).destination != .null) {
            self.objects[self.h - 1][door_offset_x..][0..door_width].* = @splat(.door_south);
        }
        if (self.doors.get(.west).destination != .null) {
            for (self.objects[door_offset_y..][0..door_width]) |*row| {
                row[0] = .door_west;
            }
        }
        if (self.doors.get(.east).destination != .null) {
            for (self.objects[door_offset_y..][0..door_width]) |*row| {
                row[self.w - 1] = .door_east;
            }
        }
    }

    fn hasUnexploredDoors(
        self: @This(),
    ) bool {
        for (std.enums.values(Direction)) |dir| {
            if (!self.doors.get(dir).ai_explored and
                self.doors.get(dir).destination != .null) return true;
        }
        return false;
    }
};

const Display = struct {
    const w: u32 = 60;
    const h: u32 = 20;
    const Buffer = [h][w]u8;

    back_buffer: Buffer = @splat(@splat(' ')),
    // front_buffer: Buffer = @splat(@splat(' ')),

    fn clear(
        self: *@This(),
    ) void {
        self.back_buffer = @splat(@splat(' '));
    }

    fn flush(
        self: *@This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{f}", .{abi.escape.cursorPop()});
        for (0..h) |y| {
            try writer.writeAll(&self.back_buffer[y]);
            try writer.writeByte('\n');
        }
        try writer.flush();
    }
};
