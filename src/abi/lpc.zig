const std = @import("std");

const abi = @import("lib.zig");
const caps = @import("caps.zig");
const conf = @import("conf.zig");
const sys = @import("sys.zig");

const log = std.log.scoped(.lpc);

//

pub const Error = error{
    InvalidData,
};

//

pub fn call(
    comptime Req: type,
    msg: Req,
    sender: caps.Sender,
) sys.Error!Req.Response {
    const Union = Req.Union;
    const Response = Req.Response;

    const request = @unionInit(Union, @typeName(@TypeOf(msg)), msg);

    const sys_msg = try sender.call(try serialize(request));
    return try deserialize(Response, sys_msg);
}

pub fn daemon(ctx: anytype) noreturn {
    var d = Daemon(@TypeOf(ctx)).init(ctx);
    d.run();
}

pub fn Daemon(comptime Ctx: type) type {
    std.debug.assert(@TypeOf(Ctx.Request) == type);
    // std.debug.assert(@TypeOf(Ctx.Response) == type);

    return struct {
        ctx: Ctx,
        stamp: u32 = 0,

        pub fn init(ctx: Ctx) @This() {
            comptime std.debug.assert(@FieldType(Ctx, "recv") == caps.Receiver);
            return .{ .ctx = ctx };
        }

        pub fn run(self: *@This()) noreturn {
            comptime std.debug.assert(@FieldType(Ctx, "recv") == caps.Receiver);

            var sys_msg: ?sys.Message = null;
            while (true) {
                self.runOnce(&sys_msg) catch |err| {
                    log.err("daemon handler wrapper error: {}", .{err});
                };
            }
        }

        pub fn runOnce(self: *@This(), _sys_msg: *?sys.Message) !void {
            const sys_msg = if (_sys_msg.*) |some|
                some
            else
                try self.ctx.recv.recv();
            _sys_msg.* = null;

            self.stamp = sys_msg.cap_or_stamp;
            const msg = try Message(messageInfo(Ctx.Request)).fromSysMessage(sys_msg);
            const request = try deserializeInner(Ctx.Request, msg);

            switch (request) {
                inline else => |v| {
                    const Req = @TypeOf(v);
                    const Resp = Req.Response;

                    const handler = inline for (Ctx.routes) |handler| {
                        const HandlerTy = @typeInfo(@TypeOf(handler)).@"fn".params[1].type.?;
                        if (HandlerTy.Request == Req) break handler;
                    } else {
                        @compileError(std.fmt.comptimePrint("missing handler for {}", .{Req}));
                    };

                    // log.debug("handling {} -> {}", .{ Req, Resp });
                    // errdefer log.debug("error handling {}", .{Req});
                    // log.debug("input {}", .{v});

                    var reply: Reply(Resp) = .{};
                    errdefer if (reply.resp) |r| r.deinit();

                    const res: void = handler(self, .{ .req = v, .reply = &reply }) catch |err| {
                        log.err("daemon handler error: {}", .{err});
                    };
                    _ = res;

                    _sys_msg.* = if (reply.resp) |resp|
                        try self.ctx.recv.replyRecv(try resp.asSysMessage())
                    else
                        try self.ctx.recv.recv();
                },
            }
        }
    };
}

pub fn Handler(comptime T: type) type {
    return struct {
        req: T,
        reply: *Reply(T.Response),

        const Request = T;
    };
}

pub fn Reply(comptime T: type) type {
    return struct {
        resp: ?Message(messageInfo(T)) = null,
        detached: bool = false,

        pub fn unwrapResult(
            self: *@This(),
            comptime Ok: type,
            res: abi.Result(Ok, @FieldType(T, "err")),
        ) ?Ok {
            switch (res) {
                .ok => |v| return v,
                .err => |v| {
                    self.send(.{ .err = v });
                    return null;
                },
            }
        }

        pub fn send(self: *@This(), response: T) void {
            std.debug.assert(self.resp == null);
            if (self.detached) return;
            self.resp = serializeInner(response);
        }

        pub fn detach(self: @This()) sys.Error!DetachedReply(T) {
            self.detached = true;
            return .{ .detached = try caps.Reply.create() };
        }
    };
}

pub fn DetachedReply(comptime T: type) type {
    return struct {
        detached: caps.Reply = .{},

        pub fn send(self: *@This(), response: T) sys.Error!void {
            std.debug.assert(self.detached.cap != 0);
            try self.detached.reply(try serializeInner(response).asSysMessage());
            self.detached = .{};
        }
    };
}

pub fn Request(comptime requests: []const type) type {
    var enum_fields: [requests.len]std.builtin.Type.EnumField = undefined;
    var union_fields: [requests.len]std.builtin.Type.UnionField = undefined;
    for (requests, &enum_fields, &union_fields, 0..) |req, *enum_field, *union_field, i| {
        union_field.alignment = @alignOf(req);
        union_field.name = @typeName(req);
        union_field.type = req;
        enum_field.name = @typeName(req);
        enum_field.value = i;
    }

    const TagType = if (requests.len == 0 or requests.len == 1)
        u0
    else
        @Type(.{ .int = .{
            .bits = std.math.log2_int_ceil(usize, union_fields.len),
            .signedness = .unsigned,
        } });

    const Tag = @Type(.{ .@"enum" = std.builtin.Type.Enum{
        .tag_type = TagType,
        .decls = &.{},
        .fields = &enum_fields,
        .is_exhaustive = true,
    } });

    return @Type(.{ .@"union" = std.builtin.Type.Union{
        .layout = .auto,
        .tag_type = Tag,
        .decls = &.{},
        .fields = &union_fields,
    } });
}

pub fn typeId(comptime T: type) usize {
    return @intFromError(@field(anyerror, @typeName(T)));
}

//

// TODO: merge bits, like u1
pub fn serialize(msg: anytype) sys.Error!sys.Message {
    const sys_msg = serializeInner(msg);
    return try sys_msg.asSysMessage();
}

// TODO: merge bits, like u1
/// Error is a normal syscall error
/// null is
pub fn deserialize(comptime T: type, sys_msg: sys.Message) sys.Error!T {
    const msg = try Message(messageInfo(T)).fromSysMessage(sys_msg);
    return deserializeInner(T, msg) catch
        return sys.Error.Internal; // the other end misbehaves
}

//

pub fn serializeInner(msg: anytype) Message(messageInfo(@TypeOf(msg))) {
    const msg_info = comptime messageInfo(@TypeOf(msg));

    // special case types
    switch (@TypeOf(msg)) {
        caps.Handle,
        caps.Thread,
        caps.Process,
        caps.Vmem,
        caps.Frame,
        caps.Receiver,
        caps.Reply,
        caps.Sender,
        caps.Notify,
        caps.X86IoPortAllocator,
        caps.X86IoPort,
        caps.X86IrqAllocator,
        caps.X86Irq,
        => return Message(msg_info).handle(.{ .cap = msg.cap }),

        // use abi.sys.Result for errors and error unions
        // sys.Error,
        // => return serializeInner(sys.errorToInt(msg)),

        f64,
        f32,
        f16,
        usize,
        u128,
        u64,
        u32,
        u16,
        u8,
        u4,
        u2,
        u1,
        u0,
        isize,
        i128,
        i64,
        i32,
        i16,
        i8,
        void,
        bool,
        => return Message(msg_info).simple(std.mem.asBytes(&msg)),

        else => {},
    }

    switch (@typeInfo(@TypeOf(msg))) {
        .@"enum" => return serializeInner(@intFromEnum(msg)),
        .optional => |t| if (msg) |v| {
            return serializeInner(true).merge(serializeInner(v));
        } else {
            return serializeInner(false).merge(Message(messageInfo(t.child)){});
        },
        .pointer => {
            @compileError("TODO: pointers");
        },
        .array => {
            var res: Message(msg_info) = .{};
            for (msg, 0..) |item, i| {
                const val = serializeInner(item);
                std.mem.copyForwards(
                    u8,
                    res.data[i * val.data.len .. (i + 1) * val.data.len],
                    &val.data,
                );
                std.mem.copyForwards(
                    caps.Handle,
                    res.caps[i * val.caps.len .. (i + 1) * val.caps.len],
                    &val.caps,
                );
            }
            return res;
        },
        .@"struct" => |t| {
            var res: Message(msg_info) = .{};
            var data_i: usize = 0;
            var caps_i: usize = 0;
            inline for (t.fields) |field| {
                const val = serializeInner(@field(msg, field.name));
                std.mem.copyForwards(
                    u8,
                    res.data[data_i..],
                    &val.data,
                );
                std.mem.copyForwards(
                    caps.Handle,
                    res.caps[caps_i..],
                    &val.caps,
                );
                data_i += val.data.len;
                caps_i += val.caps.len;
            }
            return res;
        },
        .@"union" => switch (msg) {
            inline else => |v| {
                const data = serializeInner(std.meta.activeTag(msg)).merge(serializeInner(v));
                return .{
                    .data = data.data ++ [1]u8{0} ** (msg_info.in_line.data_size - data.data.len),
                    .caps = data.caps ++ [1]caps.Handle{.{}} ** (msg_info.in_line.cap_count - data.caps.len),
                };
            },
        },
        // .error_union => {
        //     if (msg) |ok| {
        //         return serializeInner(false).merge(serializeInner(ok));
        //     } else |err| {
        //         return serializeInner(true).merge(serializeInner(err));
        //     }
        // },
        // .error_set => {
        //     @compileError("TODO: error sets other than abi.sys.Error");
        // },

        else => {},
    }

    @compileError(std.fmt.comptimePrint(
        "invalid type '{}' passed to lpc.serialize/deserialize",
        .{@TypeOf(msg)},
    ));
}

test {
    const data = .{
        @as(u8, 0xc4),
        @as(u16, 0xf88f),
        @as(?u32, 0x55ddee11),
        caps.Frame{ .cap = 4 },
    };
    const msg = serializeInner(data);
    try std.testing.expect(msg.caps.len == 1);
    try std.testing.expect(msg.caps[0].cap == 4);
    try std.testing.expect(msg.data.len == 8);
    try std.testing.expect(std.mem.eql(
        u8,
        &msg.data,
        &.{ 0xc4, 0x8f, 0xf8, 0x01, 0x11, 0xee, 0xdd, 0x55 },
    ));
}

test {
    const data = .{
        @as(?caps.Frame, caps.Frame{ .cap = 4 }),
        @as([4:0]u8, [1:0]u8{44} ** 4),
    };
    const msg = serializeInner(data);
    try std.testing.expect(msg.caps.len == 1);
    try std.testing.expect(msg.caps[0].cap == 4);
    try std.testing.expect(msg.data.len == 5);
    try std.testing.expect(std.mem.eql(
        u8,
        &msg.data,
        &.{ 1, 44, 44, 44, 44 },
    ));
}

test {
    const data = .{
        @as(?caps.Frame, null),
    };
    const msg = serializeInner(data);
    try std.testing.expect(msg.caps.len == 1);
    try std.testing.expect(msg.caps[0].cap == 0);
    try std.testing.expect(msg.data.len == 1);
    try std.testing.expect(msg.data[0] == 0);
}

test {
    const data: ?u32 = 43;
    const msg = serializeInner(data);
    try std.testing.expect(msg.caps.len == 0);
    try std.testing.expect(msg.data.len == 5);
    try std.testing.expect(std.mem.eql(
        u8,
        &msg.data,
        &.{ 1, 43, 0, 0, 0 },
    ));
}

test {
    const data: ?u32 = 43;
    const msg = serializeInner(data);
    try std.testing.expect(msg.caps.len == 0);
    try std.testing.expect(msg.data.len == 5);
    try std.testing.expect(std.mem.eql(
        u8,
        &msg.data,
        &.{ 1, 43, 0, 0, 0 },
    ));
}

pub fn deserializeInner(comptime T: type, msg: Message(messageInfo(T))) Error!T {
    switch (T) {
        caps.Handle,
        caps.Thread,
        caps.Process,
        caps.Vmem,
        caps.Frame,
        caps.Receiver,
        caps.Reply,
        caps.Sender,
        caps.Notify,
        caps.X86IoPortAllocator,
        caps.X86IoPort,
        caps.X86IrqAllocator,
        caps.X86Irq,
        => return .{ .cap = msg.caps[0].cap },

        // sys.Error,
        // => return .{sys.intToError((try deserializeWrapper(u32, msg)).@"0")},

        f64,
        f32,
        f16,
        usize,
        u128,
        u64,
        u32,
        u16,
        u8,
        u0,
        isize,
        i128,
        i64,
        i32,
        i16,
        i8,
        => return @bitCast(msg.data),

        void,
        => return {},

        u4,
        u2,
        u1,
        => return @truncate(msg.data[0]),

        bool,
        => return msg.data[0] != 0,

        else => {},
    }

    switch (@typeInfo(T)) {
        .@"enum" => |t| return std.meta.intToEnum(
            T,
            try deserializeInner(t.tag_type, msg),
        ) catch return Error.InvalidData,
        .optional => |t| {
            const non_null, const data = msg.split(messageInfo(bool));
            if (try deserializeInner(bool, non_null)) {
                return try deserializeInner(t.child, data);
            } else {
                return null;
            }
        },
        .pointer => {
            @compileError("TODO: pointers");
        },
        .array => |t| {
            var res: T = undefined;
            inline for (0..t.len) |i| {
                res[i] = try deserializeInner(
                    t.child,
                    msg.nth(messageInfo(t.child), i),
                );
            }
            return res;
        },
        .@"struct" => |t| {
            var res: T = undefined;
            comptime var data_i: usize = 0;
            comptime var caps_i: usize = 0;
            inline for (t.fields) |field| {
                const field_msg_info = comptime messageInfo(field.type);
                const field_val = try deserializeInner(field.type, .{
                    .data = msg.data[data_i .. data_i + field_msg_info.in_line.data_size].*,
                    .caps = msg.caps[caps_i .. caps_i + field_msg_info.in_line.cap_count].*,
                });

                @field(res, field.name) = field_val;

                data_i += field_msg_info.in_line.data_size;
                caps_i += field_msg_info.in_line.cap_count;
            }
            return res;
        },
        .@"union" => |t| {
            const tag, const data = msg.split(messageInfo(t.tag_type.?));
            switch (try deserializeInner(t.tag_type.?, tag)) {
                inline else => |v| {
                    const field_type = @FieldType(T, @tagName(v));
                    const variant_val = try deserializeInner(
                        field_type,
                        data.split(messageInfo(field_type)).@"0",
                    );
                    return @unionInit(
                        T,
                        @tagName(v),
                        variant_val,
                    );
                },
            }
        },
        // .error_union => |t| {
        //     const non_null, const data = msg.split(messageInfo(bool));
        //     if (!(try deserializeWrapper(bool, non_null)).@"0") {
        //         return .{(try deserializeWrapper(
        //             t.payload,
        //             data.split(messageInfo(t.payload)).@"0",
        //         )).@"0"};
        //     } else {
        //         return .{(try deserializeWrapper(
        //             t.error_set,
        //             data.split(messageInfo(t.error_set)).@"0",
        //         )).@"0"};
        //     }
        // },
        // .error_set => {
        //     @compileError("TODO: error sets other than abi.sys.Error");
        // },

        else => {},
    }

    @compileError(std.fmt.comptimePrint(
        "invalid type '{}' passed to lpc.serialize/deserialize",
        .{@TypeOf(msg)},
    ));
}

test {
    const T = struct {
        a: u8 = 0,
        b: u32 = 0,
        c: ?caps.Frame = null,
        d: [2]caps.Notify = .{ .{}, .{} },
        e: [8:0]u8 = [1:0]u8{0} ** 8,
        f: enum(u8) {
            a,
            b,
            c,
            _,
        } = .a,
        g: union(enum(u8)) {
            a: u8,
            b: u32,
        } = .{ .a = 0 },
        h: sys.ErrorEnum = .bad_handle,
        i: [10]u128 = [1]u128{0} ** 10,
    };

    try std.testing.fuzz({}, struct {
        fn testOne(_: void, input: []const u8) anyerror!void {
            var input_val: T = .{};
            std.mem.copyForwards(
                u8,
                std.mem.asBytes(&input_val),
                input[0..@min(input.len, @sizeOf(T))],
            );
            if (input.len >= 1 and input[0] >= 0x80) {
                input_val.g = .{ .a = @bitCast(std.mem.asBytes(&input_val.g)[0..@sizeOf(u8)].*) };
            } else {
                input_val.g = .{ .b = @bitCast(std.mem.asBytes(&input_val.g)[0..@sizeOf(u32)].*) };
            }

            const msg = serialize(input_val) catch return;
            const output_val = deserialize(T, msg) catch return;

            try std.testing.expect(input_val.a == output_val.a);
            try std.testing.expect(input_val.b == output_val.b);
            try std.testing.expect((input_val.c != null) == (output_val.c != null));
            if (input_val.c != null) {
                try std.testing.expect(input_val.c.?.cap == output_val.c.?.cap);
            }
            try std.testing.expect(input_val.d[0].cap == output_val.d[0].cap);
            try std.testing.expect(input_val.d[1].cap == output_val.d[1].cap);
            try std.testing.expect(std.mem.eql(u8, &input_val.e, &output_val.e));
            try std.testing.expect(input_val.f == output_val.f);
            try std.testing.expect(std.meta.activeTag(input_val.g) == std.meta.activeTag(output_val.g));
            switch (input_val.g) {
                .a => |v| try std.testing.expect(v == output_val.g.a),
                .b => |v| try std.testing.expect(v == output_val.g.b),
            }
            try std.testing.expect(input_val.h == output_val.h);
            try std.testing.expect(std.mem.eql(u128, &input_val.i, &output_val.i));
        }
    }.testOne, .{});
}

pub fn Message(comptime _info: MessageInfo) type {
    const sys_msg_size = 5 * @sizeOf(usize);
    const data_size = _info.in_line.data_size;
    const cap_count = _info.in_line.cap_count;
    const extra_data_size = data_size -| sys_msg_size;
    const extra_data_regs = std.math.divCeil(usize, extra_data_size, 8) catch unreachable;

    return extern struct {
        data: [data_size]u8 = [1]u8{0} ** data_size,
        caps: [cap_count]caps.Handle = [1]caps.Handle{.{}} ** cap_count,

        const info: MessageInfo = _info;

        const Self = @This();

        pub fn simple(bytes: []const u8) Self {
            var self: Self = .{};
            std.mem.copyForwards(u8, &self.data, bytes);
            return self;
        }

        pub fn handle(cap: caps.Handle) Self {
            return .{ .caps = .{cap} };
        }

        pub fn deinit(self: Self) void {
            for (self.caps) |cap| if (cap.cap != 0) cap.close();
        }

        /// should only be called immediately before the IPC syscall
        pub fn asSysMessage(self: Self) sys.Error!sys.Message {
            var msg: sys.Message = .{};
            const small: *[sys_msg_size]u8 = @ptrCast(&msg.arg0);

            if (data_size <= sys_msg_size) {
                std.mem.copyForwards(u8, small, std.mem.asBytes(&self.data));
            } else {
                std.mem.copyForwards(u8, small, std.mem.asBytes(self.data[0..sys_msg_size]));
                var extra_regs: [extra_data_regs]u64 = [1]u64{0} ** extra_data_regs;
                std.mem.copyForwards(
                    u8,
                    std.mem.asBytes(&extra_regs),
                    self.data[sys_msg_size..],
                );

                for (extra_regs, 0..) |extra, i| {
                    // log.debug("data selfSetExtra({}, {}, false)", .{ i, extra });
                    try sys.selfSetExtra(@truncate(i), extra, false);
                }
            }

            for (self.caps, extra_data_regs..) |cap, i| {
                // log.debug("cap selfSetExtra({}, {}, {})", .{ i, cap.cap, cap.cap != 0 });
                try sys.selfSetExtra(@truncate(i), cap.cap, cap.cap != 0);
            }

            msg.extra = @as(u7, @intCast(self.caps.len + extra_data_regs));
            return msg;
        }

        pub fn fromSysMessage(msg: sys.Message) sys.Error!Self {
            var self: Self = .{};
            errdefer self.deinit();
            const small: *const [sys_msg_size]u8 = @ptrCast(&msg.arg0);

            if (msg.extra != self.caps.len + extra_data_regs)
                return sys.Error.Internal; // the other end misbehaves

            if (data_size <= sys_msg_size) {
                std.mem.copyForwards(u8, &self.data, small[0..data_size]);
            } else {
                std.mem.copyForwards(u8, self.data[0..sys_msg_size], small);
                var extra_regs: [extra_data_regs]u64 = [1]u64{0} ** extra_data_regs;
                for (&extra_regs, 0..) |*extra, i| {
                    const res = try sys.selfGetExtra(@truncate(i));
                    // log.debug("data selfGetExtra({}) => {}, {}", .{ i, res.val, res.is_cap });
                    if (res.is_cap)
                        return sys.Error.Internal; // the other end misbehaves
                    extra.* = res.val;
                }
                std.mem.copyForwards(
                    u8,
                    self.data[sys_msg_size..],
                    std.mem.asBytes(&extra_regs)[0..extra_data_size],
                );
            }

            for (&self.caps, extra_data_regs..) |*cap, i| {
                const res = try sys.selfGetExtra(@truncate(i));
                // log.debug("cap selfGetExtra({}) => {}, {}", .{ i, res.val, res.is_cap });
                if (!res.is_cap and res.val != 0)
                    return sys.Error.Internal; // the other end misbehaves
                cap.cap = @truncate(res.val);
            }

            return self;
        }

        pub fn merge(self: Self, other: anytype) Message(info.add(@TypeOf(other).info)) {
            return .{
                .data = self.data ++ other.data,
                .caps = self.caps ++ other.caps,
            };
        }

        pub fn split(self: Self, comptime first: MessageInfo) struct {
            Message(first),
            Message(info.sub(first)),
        } {
            // FIXME: replacing '(struct {
            //     Message(first),
            //     Message(info.sub(first)),
            // })' with '.' here causes the zig compiler to crash somehow
            return (struct {
                Message(first),
                Message(info.sub(first)),
            }){ .{
                .data = self.data[0..first.in_line.data_size].*,
                .caps = self.caps[0..first.in_line.cap_count].*,
            }, .{
                .data = self.data[first.in_line.data_size..].*,
                .caps = self.caps[first.in_line.cap_count..].*,
            } };
        }

        pub fn nth(self: Self, comptime subitem: MessageInfo, comptime n: usize) Message(subitem) {
            return .{
                .data = self.data[n * subitem.in_line.data_size .. (n + 1) * subitem.in_line.data_size].*,
                .caps = self.caps[n * subitem.in_line.cap_count .. (n + 1) * subitem.in_line.cap_count].*,
            };
        }
    };
}

pub const MessageInfo = struct {
    in_line: InlineMessageInfo = .{},
    // /// number of extra items 'out-of-line', aka not inlined to the message
    // out_of_line: []const InlineMessageInfo = &.{},

    const Self = @This();

    pub fn simple(bytes: u32) Self {
        return .{ .in_line = .{
            .data_size = bytes,
        } };
    }

    pub fn handle() Self {
        return .{ .in_line = .{
            .cap_count = 1,
        } };
    }

    pub fn add(self: Self, other: Self) Self {
        return .{ .in_line = .{
            .cap_count = self.in_line.cap_count + other.in_line.cap_count,
            .data_size = self.in_line.data_size + other.in_line.data_size,
        } };
    }

    pub fn sub(self: Self, other: Self) Self {
        return .{ .in_line = .{
            .cap_count = self.in_line.cap_count - other.in_line.cap_count,
            .data_size = self.in_line.data_size - other.in_line.data_size,
        } };
    }

    pub fn max(self: Self, other: Self) Self {
        return .{ .in_line = .{
            .cap_count = @max(self.in_line.cap_count, other.in_line.cap_count),
            .data_size = @max(self.in_line.data_size, other.in_line.data_size),
        } };
    }

    pub fn mul(self: Self, by: comptime_int) Self {
        return .{ .in_line = .{
            .cap_count = self.in_line.cap_count * by,
            .data_size = self.in_line.data_size * by,
        } };
    }

    pub fn append(self: *Self, comptime T: type) void {
        self.* = self.add(messageInfo(T));
    }

    pub fn overlap(self: *Self, comptime T: type) void {
        self.* = self.max(messageInfo(T));
    }
};

pub const InlineMessageInfo = struct {
    /// number of capabilities that need to use the extra regs
    cap_count: u7 = 0,
    /// number of inlined bytes in this message
    data_size: u32 = 0,
};

pub fn messageInfo(comptime T: type) MessageInfo {
    // special case types
    switch (T) {
        caps.Handle,
        caps.Thread,
        caps.Process,
        caps.Vmem,
        caps.Frame,
        caps.Receiver,
        caps.Reply,
        caps.Sender,
        caps.Notify,
        caps.X86IoPortAllocator,
        caps.X86IoPort,
        caps.X86IrqAllocator,
        caps.X86Irq,
        => return MessageInfo.handle(),

        // sys.Error,
        // => return MessageInfo.simple(@sizeOf(u32)),

        f64,
        f32,
        f16,
        usize,
        u128,
        u64,
        u32,
        u16,
        u8,
        u4,
        u2,
        u1,
        u0,
        isize,
        i128,
        i64,
        i32,
        i16,
        i8,
        void,
        bool,
        => return MessageInfo.simple(@sizeOf(T)),

        else => {},
    }

    switch (@typeInfo(T)) {
        .@"enum" => |t| return messageInfo(t.tag_type),
        .optional => |t| return messageInfo(bool).add(messageInfo(t.child)),
        .pointer => {
            @compileError("TODO: pointers");
        },
        .array => |t| return messageInfo(t.child).mul(t.len),
        .@"struct" => |t| {
            var acc = messageInfo(void);
            inline for (t.fields) |field| acc.append(field.type);
            return acc;
        },
        .@"union" => |t| {
            var acc = messageInfo(void);
            inline for (t.fields) |field| acc.overlap(field.type);
            return messageInfo(t.tag_type.?).add(acc);
        },
        // .error_union => |t| {
        //     return messageInfo(bool).add(
        //         messageInfo(t.error_set)
        //             .max(messageInfo(t.payload)),
        //     );
        // },
        // .error_set => {
        //     @compileError("TODO: error sets other than abi.sys.Error");
        // },

        else => {},
    }

    @compileError(std.fmt.comptimePrint(
        "invalid type '{}' passed to lpc.serialize/deserialize",
        .{T},
    ));
}

// pub fn call() void {}

test "encode test" {}
