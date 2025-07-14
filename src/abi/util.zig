const std = @import("std");

const abi = @import("lib.zig");
const caps = @import("caps.zig");
const sys = @import("sys.zig");

const log = std.log.scoped(.util);
const Glyph = abi.font.Glyph;
const Error = sys.Error;

//

pub fn fillVolatile(comptime T: type, dest: []volatile T, val: T) void {
    for (dest) |*d| d.* = val;
}

pub fn copyForwardsVolatile(comptime T: type, dest: []volatile T, source: []const T) void {
    for (dest[0..source.len], source) |*d, s| d.* = s;
}

pub fn AsVolatile(comptime T: type) type {
    var ptr = @typeInfo(T);
    ptr.pointer.is_volatile = true;
    return @Type(ptr);
}

pub fn volat(ptr: anytype) AsVolatile(@TypeOf(ptr)) {
    return ptr;
}

//

pub const Base = enum {
    binary,
    decimal,
};

pub fn NumberPrefix(comptime T: type, comptime base: Base) type {
    return struct {
        num: T,

        pub const Self = @This();

        pub fn new(num: T) Self {
            return Self{
                .num = num,
            };
        }

        // format(actual_fmt, options, writer);
        pub fn format(self: Self, comptime _: []const u8, opts: std.fmt.FormatOptions, writer: anytype) !void {
            var num = self.num;
            const prec = opts.precision orelse 1;
            switch (base) {
                .binary => {
                    const table: [10][]const u8 = .{ "", "Ki", "Mi", "Gi", "Ti", "Pi", "Ei", "Zi", "Yi", "Ri" };
                    for (table) |scale| {
                        if (num < 1024 * prec) {
                            return std.fmt.format(writer, "{d} {s}", .{ num, scale });
                        }
                        num /= 1024;
                    }
                    return std.fmt.format(writer, "{d} Qi", .{num});
                },
                .decimal => {
                    const table: [10][]const u8 = .{ "", "K", "M", "G", "T", "P", "E", "Z", "Y", "R" };
                    for (table) |scale| {
                        if (num < 1000 * prec) {
                            return std.fmt.format(writer, "{d} {s}", .{ num, scale });
                        }
                        num /= 1000;
                    }
                    return std.fmt.format(writer, "{d} Q", .{num});
                },
            }
        }
    };
}

pub const Hex = struct {
    bytes: []const u8,

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        if (self.bytes.len == 0) return;

        try std.fmt.format(writer, "{x:0>2}", .{self.bytes[0]});
        for (self.bytes[1..]) |b| {
            try std.fmt.format(writer, " {x:0>2}", .{b});
        }
    }
};

pub fn hex(bytes: []const u8) Hex {
    return .{ .bytes = bytes };
}

/// print the offset of each field in hex
pub fn debugFieldOffsets(comptime T: type) void {
    const s = @typeInfo(T).Struct;

    const v: T = undefined;

    log.info("struct {any} field offsets:", .{T});
    inline for (s.fields) |field| {
        const offs = @intFromPtr(&@field(&v, field.name)) - @intFromPtr(&v);
        log.info(" - 0x{x}: {s}", .{ offs, field.name });
    }
}

// less effort than spamming align(1) on every field,
// since zig packed structs are not like in every other language
pub fn pack(comptime T: type) type {
    var s = comptime @typeInfo(T).Struct;
    const n_fields = comptime s.fields.len;

    var fields: [n_fields]std.builtin.Type.StructField = undefined;
    inline for (0..n_fields) |i| {
        fields[i] = s.fields[i];
        fields[i].alignment = 1;
    }
    s.fields = fields[0..];

    return @Type(std.builtin.Type{ .Struct = s });
}

pub fn Image(storage: type) type {
    return struct {
        width: u32,
        height: u32,
        pitch: u32,
        bits_per_pixel: u16,
        pixel_array: storage,

        const Self = @This();

        pub fn debug(self: *const Self) void {
            std.log.debug("addr: {*}, size: {d}", .{ self.pixel_array, self.height * self.pitch });
        }

        pub fn subimage(self: *const Self, x: u32, y: u32, w: u32, h: u32) error{OutOfBounds}!Image(@TypeOf(self.pixel_array[0..])) {
            if (self.width < x + w or self.height < y + h) {
                return error.OutOfBounds;
            }

            const offs = x * self.bits_per_pixel / 8 + y * self.pitch;

            return .{
                .width = w,
                .height = h,
                .pitch = self.pitch,
                .bits_per_pixel = self.bits_per_pixel,
                .pixel_array = @ptrCast(self.pixel_array[offs..]),
            };
        }

        pub fn intersection(
            self: *const Self,
            self_x: u32,
            self_y: u32,
            other: anytype,
            other_x: u32,
            other_y: u32,
        ) ?struct { Self, @TypeOf(other) } {
            const self_xmin: usize = self_x;
            const self_xmax: usize = self_x + self.width;
            const self_ymin: usize = self_y;
            const self_ymax: usize = self_y + self.height;

            const other_xmin: usize = other_x;
            const other_xmax: usize = other_x + other.width;
            const other_ymin: usize = other_y;
            const other_ymax: usize = other_y + other.height;

            const xmin: usize = @max(self_xmin, other_xmin);
            const xmax: usize = @min(self_xmax, other_xmax);
            const ymin: usize = @max(self_ymin, other_ymin);
            const ymax: usize = @min(self_ymax, other_ymax);

            if (xmin > xmax or ymin > ymax) return null;

            const w: u32 = @intCast(xmax - xmin);
            const h: u32 = @intCast(ymax - ymin);
            const a = self.subimage(
                @intCast(xmin - self_x),
                @intCast(ymin - self_y),
                w,
                h,
            ) catch unreachable;
            const b = other.subimage(
                @intCast(xmin - other_x),
                @intCast(ymin - other_y),
                w,
                h,
            ) catch unreachable;

            return .{ a, b };
        }

        pub fn fill(self: *const Self, col: u32) void {
            const pixel_size = self.bits_per_pixel / 8;

            for (0..self.height) |y| {
                for (0..self.width) |x| {
                    const dst: *volatile [4]u8 = @ptrCast(&self.pixel_array[x * pixel_size + y * self.pitch]);
                    dst.* = @as([4]u8, @bitCast(col));
                }
            }
        }

        pub fn fillGlyph(self: *const Self, glyph: *const Glyph, fg: u32, bg: u32) void {
            // if (self.width != 16) {
            //     return
            // }

            const pixel_size = self.bits_per_pixel / 8;

            for (0..self.height) |y| {
                for (0..self.width) |x| {
                    const bit: u8 = @truncate((glyph.img[y] >> @intCast(x)) & 1);
                    const dst: *volatile [4]u8 = @ptrCast(&self.pixel_array[x * pixel_size + y * self.pitch]);
                    dst.* = @as([4]u8, @bitCast(if (bit == 0) bg else fg));
                }
            }
        }

        pub fn copyTo(from: *const Self, to: anytype) error{ SizeMismatch, BppMismatch }!void {
            if (from.width != to.width or from.height != to.height) {
                return error.SizeMismatch;
            }

            if (from.bits_per_pixel != to.bits_per_pixel) {
                return error.BppMismatch;
            }

            const from_row_width = from.width * from.bits_per_pixel / 8;
            const to_row_width = to.width * to.bits_per_pixel / 8;

            for (0..to.height) |y| {
                const from_row = y * from.pitch;
                const to_row = y * to.pitch;
                const from_row_slice = from.pixel_array[from_row .. from_row + from_row_width];
                const to_row_slice = to.pixel_array[to_row .. to_row + to_row_width];
                @memcpy(to_row_slice, from_row_slice);
            }
        }

        pub fn copyPixelsTo(from: *const Self, to: anytype) error{SizeMismatch}!void {
            if (from.width != to.width or from.height != to.height) {
                return error.SizeMismatch;
            }

            if (from.bits_per_pixel == to.bits_per_pixel) {
                return copyTo(from, to) catch unreachable;
            }

            const from_pixel_size = from.bits_per_pixel / 8;
            const to_pixel_size = to.bits_per_pixel / 8;

            for (0..to.height) |y| {
                for (0..to.width) |x| {
                    const from_idx = x * from_pixel_size + y * from.pitch;
                    const from_pixel: *const volatile Pixel = @ptrCast(&from.pixel_array[from_idx]);

                    const to_idx = x * to_pixel_size + y * to.pitch;
                    const to_pixel: *volatile Pixel = @ptrCast(&to.pixel_array[to_idx]);

                    // print("loc: {d},{d}", .{ x, y });
                    // print("from: {*} to: {*}", .{ from_pixel, to_pixel });

                    to_pixel.* = from_pixel.*;
                }
            }
        }

        pub fn blitTo(from: *const Self, to: anytype) error{SizeMismatch}!void {
            if (from.width != to.width or from.height != to.height) {
                return error.SizeMismatch;
            }

            const from_pixel_size = from.bits_per_pixel / 8;
            const to_pixel_size = to.bits_per_pixel / 8;

            for (0..to.height) |y| {
                for (0..to.width) |x| {
                    const from_idx = x * from_pixel_size + y * from.pitch;
                    const from_pixel: *const volatile Pixel = @ptrCast(&from.pixel_array[from_idx]);

                    const to_idx = x * to_pixel_size + y * to.pitch;
                    const to_pixel: *volatile Pixel = @ptrCast(&to.pixel_array[to_idx]);

                    // if (x == 0 and y == 0) {
                    //     log.debug("from = {}, to = {}", .{ from_pixel.*, to_pixel.* });
                    // }

                    const alpha_blending = false;
                    if (alpha_blending) {
                        const f255 = @Vector(3, f32){ 255.0, 255.0, 255.0 };
                        const f1 = @Vector(3, f32){ 1.0, 1.0, 1.0 };

                        const from_rgb = @Vector(3, f32){
                            @floatFromInt(from_pixel.red),
                            @floatFromInt(from_pixel.green),
                            @floatFromInt(from_pixel.blue),
                        } / f255;
                        const from_a = @as(f32, @floatFromInt(from_pixel.alpha)) / 255.0;
                        const from_av = @Vector(3, f32){ from_a, from_a, from_a };
                        const to_rgb = @Vector(3, f32){
                            @floatFromInt(to_pixel.red),
                            @floatFromInt(to_pixel.green),
                            @floatFromInt(to_pixel.blue),
                        } / f255;
                        const to_a = @as(f32, @floatFromInt(to_pixel.alpha)) / 255.0;
                        const to_av = @Vector(3, f32){ to_a, to_a, to_a };

                        const final = (from_rgb * from_av + to_rgb * to_av * (f1 - from_av)) * f255;
                        const final_a = (from_a + to_a * (1.0 - from_a)) * 255.0;

                        to_pixel.* = .{
                            .red = @intFromFloat(final[0]),
                            .green = @intFromFloat(final[1]),
                            .blue = @intFromFloat(final[2]),
                            .alpha = @intFromFloat(final_a),
                        };
                    } else {
                        const _to = to_pixel.*;
                        const _from = from_pixel.*;
                        const alpha: u1 = @intFromBool(_from.alpha != 0);

                        to_pixel.* = .{
                            .red = _from.red * alpha + _to.red * (1 - alpha),
                            .green = _from.green * alpha + _to.green * (1 - alpha),
                            .blue = _from.blue * alpha + _to.blue * (1 - alpha),
                            .alpha = 255,
                        };
                    }

                    // if (x == 0 and y == 0) {
                    //     log.debug("final = {}", .{to_pixel.*});
                    // }
                }
            }
        }
    };
}

pub const Pixel = extern struct {
    blue: u8,
    green: u8,
    red: u8,
    alpha: u8 = 0xff,
};

//

pub fn Queue(
    comptime T: type,
    comptime next_field: []const u8,
    comptime prev_field: []const u8,
) type {
    return struct {
        head: ?*T = null,
        tail: ?*T = null,

        pub fn pushBack(self: *@This(), new: *T) void {
            if (self.tail) |tail| {
                @field(new, prev_field) = tail;
                @field(tail, next_field) = new;
            } else {
                @field(new, prev_field) = null;
                @field(new, next_field) = null;
                self.head = new;
            }

            self.tail = new;
        }

        pub fn pushFront(self: *@This(), new: *T) void {
            if (self.head) |head| {
                @field(new, next_field) = head;
                @field(head, prev_field) = new;
            } else {
                @field(new, next_field) = null;
                @field(new, prev_field) = null;
                self.tail = new;
            }

            self.head = new;
        }

        pub fn popBack(self: *@This()) ?*T {
            const head = self.head orelse return null;
            const tail = self.tail orelse return null;

            if (head == tail) {
                self.head = null;
                self.tail = null;
            } else {
                self.tail = @field(tail, prev_field).?; // assert that its not null
            }

            return tail;
        }

        pub fn popFront(self: *@This()) ?*T {
            const head = self.head orelse return null;
            const tail = self.tail orelse return null;

            if (head == tail) {
                self.head = null;
                self.tail = null;
            } else {
                self.head = @field(head, next_field).?; // assert that its not null
            }

            return head;
        }
    };
}

// TODO: automatically convert tuples with just one item into that item
// TODO: check extra caps count when deserializing
// TODO: check cap types when deserializing
/// this fucking monstrosity converts a simple specification type
/// into a Client and Server based on the hiillos IPC system
/// look at `VmProtocol` for an example
pub fn Protocol(comptime spec: type) type {
    const info = comptime @typeInfo(spec);
    if (info != .@"struct")
        @compileError("Protocol input has to be a struct");

    if (info.@"struct".is_tuple)
        @compileError("Protocol input has to be a struct");

    const Variant = struct {
        /// the tuple input
        input_ty: type,
        /// the tuple output
        output_ty: type,

        /// struct containing `serialize` and `deserialize` fns
        /// to convert `input_ty` to a message
        /// and message to `input_ty`
        input_converter: type,
        /// struct containing `serialize` and `deserialize` fns
        /// to convert `output_ty` to a message
        /// and message to `output_ty`
        output_converter: type,

        handler: []const u8,
        // handler: fn (msg: *sys.Message) void,
    };

    var variants: [info.@"struct".fields.len]Variant = undefined;

    var handlers_fields: [info.@"struct".fields.len]std.builtin.Type.StructField = undefined;

    var message_variant_fields: [info.@"struct".fields.len]std.builtin.Type.EnumField = undefined;
    var message_variant_field_idx = 0;
    for (&message_variant_fields, info.@"struct".fields) |*enum_field, *spec_field| {
        enum_field.* = .{
            .name = spec_field.name,
            .value = message_variant_field_idx,
        };
        message_variant_field_idx += 1;
    }
    const _message_variant_enum = std.builtin.Type{ .@"enum" = std.builtin.Type.Enum{
        .tag_type = if (message_variant_fields.len == 0) void else u8,
        .fields = &message_variant_fields,
        .decls = &.{},
        .is_exhaustive = true,
    } };
    const MessageVariant: type = @Type(_message_variant_enum);

    inline for (info.@"struct".fields, 0..) |field, i| {
        // RPC call param serializer/deserializer
        var input_msg: MessageUsage = .{};
        // RPC call result serializer/deserializer
        var output_msg: MessageUsage = .{};

        // the arg "0" is an enum of the call type
        _ = input_msg.addType(MessageVariant);

        const field_info = comptime @typeInfo(field.type);
        if (field_info != .@"fn")
            @compileError("Protocol input struct fields have to be of type fn");

        if (field_info.@"fn".is_generic)
            @compileError("Protocol input functions cannot be generic");

        const return_ty = @typeInfo(field_info.@"fn".return_type.?);
        if (return_ty == .@"struct" and return_ty.@"struct".is_tuple) {
            for (return_ty.@"struct".fields) |f| {
                _ = output_msg.addType(f.type);
            }
        } else {
            _ = output_msg.addType(field_info.@"fn".return_type.?);
        }

        inline for (field_info.@"fn".params) |param| {
            if (param.is_generic)
                @compileError("Protocol input functions cannot be generic");

            const param_ty = param.type orelse
                @compileError("Protocol input function parameters have to have types");

            _ = input_msg.addType(param_ty);
        }

        input_msg.finish(true);
        output_msg.finish(false);

        // if (true)
        //     @compileError(std.fmt.comptimePrint("input_ty={}", .{input_msg.MakeIo()}));

        const input_converter = input_msg.makeConverter();
        const output_converter = output_msg.makeConverter();
        const input_ty = input_msg.MakeIo();
        const output_ty = output_msg.MakeIo();

        variants[i] = Variant{
            .input_converter = input_converter,
            .output_converter = output_converter,
            .input_ty = input_ty,
            .output_ty = output_ty,
            .handler = field.name,
        };

        handlers_fields[i] = std.builtin.Type.StructField{
            .name = field.name,
            .type = fn (ctx: anytype, sender: u32, req: TupleWithoutFirst(input_ty)) output_ty,
            .default_value_ptr = null,
            .alignment = @alignOf(field.type),
            .is_comptime = false,
        };
    }

    const variants_const = variants; // ok zig randomly doesnt like accessing vars from nested things

    const Handlers = @Type(.{ .@"struct" = std.builtin.Type.Struct{
        .layout = .auto,
        .backing_integer = null,
        .fields = &handlers_fields,
        .decls = &.{},
        .is_tuple = false,
    } });
    _ = Handlers;

    return struct {
        fn ReturnType(comptime id: MessageVariant) type {
            return info.@"struct".fields[@intFromEnum(id)].type;
        }

        fn VariantOf(comptime id: MessageVariant) Variant {
            return variants_const[@intFromEnum(id)];
        }

        pub fn replyTo(rx: caps.Reply, comptime id: MessageVariant, output: VariantOf(id).output_ty) sys.Error!void {
            var msg: sys.Message = undefined;
            try variants_const[@intFromEnum(id)].output_converter.serialize(&msg, output);
            try rx.reply(msg);
        }

        pub fn Client() type {
            return struct {
                tx: caps.Sender,

                pub fn init(tx: caps.Sender) @This() {
                    return .{ .tx = tx };
                }

                pub fn call(self: @This(), comptime id: MessageVariant, args: TupleWithoutFirst(VariantOf(id).input_ty)) sys.Error!VariantOf(id).output_ty {
                    const variant = VariantOf(id);

                    var msg: sys.Message = undefined;
                    const inputs = if (@TypeOf(args) == void) .{id} else .{id} ++ args;
                    try variant.input_converter.serialize(&msg, inputs);
                    // std.log.info("send <- msg={}", .{msg});
                    msg = try self.tx.call(msg);
                    // std.log.info("call -> msg={}", .{msg});
                    return (try variant.output_converter.deserialize(&msg)).?; // FIXME:
                }
            };
        }

        pub const ServerConfig = struct {
            Context: type = void,
            scope: ?@TypeOf(.enum_literal) = null,
        };

        pub fn Server(comptime config: ServerConfig, comptime handlers: anytype) type {
            return struct {
                rx: caps.Receiver,
                ctx: config.Context,
                comptime logger: ?@TypeOf(.enum_literal) = config.scope,
                comptime handlers: @TypeOf(handlers) = handlers,

                pub fn init(ctx: config.Context, rx: caps.Receiver) @This() {
                    return .{ .ctx = ctx, .rx = rx };
                }

                pub fn process(self: @This(), msg: *sys.Message) Error!void {
                    const variant = variants_const[0].input_converter.deserializeVariant(msg).?; // FIXME:
                    if (self.logger) |s|
                        std.log.scoped(s).debug("handling {s}", .{@tagName(variant)});
                    defer if (self.logger) |s|
                        std.log.scoped(s).debug("handling {s} done", .{@tagName(variant)});

                    // hopefully gets converted into a switch
                    switch (variant) {
                        inline else => |s| {
                            const v = variants_const[@intFromEnum(s)];

                            const sender = msg.cap_or_stamp;
                            const input = try v.input_converter.deserialize(msg) orelse {
                                // FIXME: handle invalid input
                                std.log.err("invalid input", .{});
                                return;
                            };

                            const handler = @field(self.handlers, v.handler);
                            // @compileLog(@TypeOf(tuplePopFirst(input)));
                            const output = handler(self.ctx, sender, tuplePopFirst(input));

                            try v.output_converter.serialize(msg, output);
                        },
                    }
                }

                pub fn reply(rx: caps.Receiver, comptime id: MessageVariant, output: VariantOf(id).output_ty) sys.Error!void {
                    var msg: sys.Message = undefined;
                    variants_const[@intFromEnum(id)].output_converter.serialize(&msg, output);
                    // std.log.info("reply <- msg={}", .{msg});
                    try rx.reply(msg);
                }

                pub fn run(self: @This()) Error!void {
                    var msg: sys.Message = try self.rx.recv();
                    while (true) {
                        // std.log.info("recv -> msg={}", .{msg});
                        try self.process(&msg);
                        msg = try self.rx.replyRecv(msg);
                    }
                }
            };
        }
    };
}

const MessageUsage = struct {
    // number of capabilities in the extra regs that the single message transfers
    caps: u7 = 0,
    // number of raw data registers that the single message transfers
    // (over 5 regs starts using extra regs)
    data: [200]DataEntry = undefined,
    data_cnt: u8 = 0,

    finished: ?type = null,

    const DataEntry = struct {
        name: [:0]const u8,
        type: type,
        fake_type: type,
        encode_type: DataEntryEnc,
    };

    const DataEntryEnc = enum {
        raw,
        cap,
        err,
        tagged_enum,
    };

    /// adds a named (named the returned number) field of type to this struct builder
    fn addType(comptime self: *@This(), comptime ty: type) usize {
        if (self.finished != null)
            @compileError("already finished");

        var real_ty: type = undefined;
        var enc: DataEntryEnc = undefined;

        switch (ty) {
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
            => {
                real_ty = u32;
                enc = .cap;
            },
            abi.sys.Rights,
            abi.sys.MapFlags,
            f64,
            f32,
            f16,
            usize,
            u128,
            u64,
            u32,
            u16,
            u8,
            isize,
            i128,
            i64,
            i32,
            i16,
            i8,
            void,
            => {
                real_ty = ty;
                enc = .raw;
            },
            sys.Error!void => {
                real_ty = usize;
                enc = .err;
            },
            else => {
                const info = @typeInfo(ty);
                if (info == .@"enum") {
                    real_ty = info.@"enum".tag_type;
                    enc = .tagged_enum;
                } else if (info == .array) {
                    real_ty = ty;
                    enc = .raw;
                } else {
                    @compileError(std.fmt.comptimePrint("unknown type {}", .{ty}));
                }
            },
        }

        self.data[self.data_cnt] = .{
            .name = std.fmt.comptimePrint("{}", .{self.data_cnt}),
            .type = real_ty,
            .fake_type = ty,
            .encode_type = enc,
        };
        self.data_cnt += 1;
        return self.data_cnt;
    }

    /// reorder fields to compact the data
    fn finish(comptime self: *@This(), comptime is_union: bool) void {
        if (self.finished != null)
            @compileError("already finished");

        // make message register use more efficient
        // sorts everything except leaves the union tag (enum) as the first thing, because it has to
        std.sort.pdq(DataEntry, self.data[@intFromBool(is_union)..self.data_cnt], {}, struct {
            fn lessThanFn(_: void, lhs: DataEntry, rhs: DataEntry) bool {
                return @sizeOf(lhs.type) < @sizeOf(rhs.type);
            }
        }.lessThanFn);

        const size_without_padding = @sizeOf(self.MakeStruct());
        const size_with_padding = std.mem.alignForward(usize, size_without_padding, @sizeOf(usize));

        const padding = @Type(std.builtin.Type{ .array = std.builtin.Type.Array{
            .len = size_with_padding - size_without_padding,
            .child = u8,
            .sentinel_ptr = null,
        } });
        self.data[self.data_cnt] = .{
            .name = "_padding",
            .type = padding,
            .fake_type = padding,
            .encode_type = .raw,
        };
        self.data_cnt += 1;
        self.finished = self.MakeStruct();
    }

    fn MakeStruct(comptime self: @This()) type {
        var fields: [self.data_cnt]std.builtin.Type.StructField = undefined;
        for (self.data[0..self.data_cnt], 0..) |s, i| {
            fields[i] = .{
                .name = s.name,
                .type = s.type,
                .default_value_ptr = &@as(s.type, undefined),
                .is_comptime = false,
                .alignment = @alignOf(s.type),
            };
        }

        const ty: std.builtin.Type = .{ .@"struct" = .{
            .layout = .@"extern",
            .backing_integer = null,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        } };

        return @Type(ty);
    }

    fn MakeIo(comptime self: @This()) type {
        var fields: [self.data_cnt - 1]std.builtin.Type.StructField = undefined;

        inline for (self.data[0 .. self.data_cnt - 1]) |data_f| {
            fields[std.fmt.parseInt(usize, data_f.name, 10) catch unreachable] = .{
                .name = data_f.name, // std.fmt.comptimePrint("{}", .{i}),
                .type = data_f.fake_type,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = @alignOf(data_f.fake_type),
            };
            // @compileLog("field", data_f.name, data_f.fake_type);
        }

        const ty: std.builtin.Type = .{ .@"struct" = .{
            .layout = .auto,
            .backing_integer = null,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = true,
        } };

        return @Type(ty);
    }

    fn makeConverter(comptime self: @This()) type {
        const Struct: type = self.finished orelse
            @compileError("not finished");
        const Io: type = self.MakeIo();
        const regs: usize = comptime @sizeOf(Struct) / @sizeOf(usize);

        // @compileLog(Io);

        return struct {
            fn extraCount() comptime_int {
                var extra_count = @max(regs, 5) - 5;

                inline for (self.data[0 .. self.data_cnt - 1]) |f| {
                    if (f.encode_type == .cap) {
                        extra_count += 1;
                    }
                }

                return extra_count;
            }

            pub fn serialize(msg: *sys.Message, inputs: Io) Error!void {
                var data: Struct = std.mem.zeroes(Struct);
                msg.* = .{};

                // std.log.info("serialize inputs={}", .{inputs});

                // const input_fields: []const std.builtin.Type.StructField = @typeInfo(@TypeOf(inputs));
                inline for (self.data[0 .. self.data_cnt - 1]) |f| {
                    // copy every (non cap and non padding) field of `data` from `input`
                    // @compileLog(std.fmt.comptimePrint("name={s} ty={} fakety={} encty={}", .{
                    //     f.name,
                    //     f.type,
                    //     f.fake_type,
                    //     f.encode_type,
                    // }));

                    if (f.encode_type == .err) {
                        @field(data, f.name) =
                            sys.encodeVoid(@field(inputs, f.name));
                    } else if (f.encode_type == .raw) {
                        @field(data, f.name) =
                            @field(inputs, f.name);
                    } else if (f.encode_type == .tagged_enum) {
                        @field(data, f.name) =
                            @intFromEnum(@field(inputs, f.name));
                    }
                }

                // std.log.info("serialize data={}", .{data});

                const data_as_regs: [regs]u64 = @bitCast(data);

                var extra_idx: u7 = 0;

                inline for (self.data[0 .. self.data_cnt - 1]) |f| {
                    if (f.encode_type == .cap) {
                        const cap_id = @field(inputs, f.name).cap;
                        try sys.selfSetExtra(extra_idx, cap_id, cap_id != 0);
                        extra_idx += 1;
                    }
                }

                inline for (data_as_regs[0..], 0..) |reg, i| {
                    if (i == 0) {
                        msg.arg0 = reg;
                    } else if (i == 1) {
                        msg.arg1 = reg;
                    } else if (i == 2) {
                        msg.arg2 = reg;
                    } else if (i == 3) {
                        msg.arg3 = reg;
                    } else if (i == 4) {
                        msg.arg4 = reg;
                    } else {
                        try sys.selfSetExtra(extra_idx, reg, false);
                        extra_idx += 1;
                    }
                }

                std.debug.assert(extra_idx == extraCount());
                msg.extra = extra_idx;
            }

            pub fn deserializeVariant(msg: *const sys.Message) ?self.data[0].fake_type {
                var data_as_regs: [regs]u64 = undefined;
                data_as_regs[0] = msg.arg0;
                const data: Struct = @bitCast(data_as_regs);
                return std.meta.intToEnum(
                    self.data[0].fake_type,
                    @field(data, self.data[0].name),
                ) catch null;
            }

            pub fn deserialize(msg: *const sys.Message) Error!?Io {
                if (msg.extra != extraCount())
                    return null;

                var ret: Io = undefined;

                var extra_idx: u7 = 0;
                inline for (self.data[0 .. self.data_cnt - 1]) |f| {
                    if (f.encode_type == .cap) {
                        const data = try sys.selfGetExtra(extra_idx);
                        if (!data.is_cap) return null;

                        @field(ret, f.name) = .{ .cap = @truncate(data.val) };
                        extra_idx += 1;
                    }
                }

                var data_as_regs: [regs]u64 = undefined;
                inline for (data_as_regs[0..], 0..) |*reg, i| {
                    if (i == 0) {
                        reg.* = msg.arg0;
                    } else if (i == 1) {
                        reg.* = msg.arg1;
                    } else if (i == 2) {
                        reg.* = msg.arg2;
                    } else if (i == 3) {
                        reg.* = msg.arg3;
                    } else if (i == 4) {
                        reg.* = msg.arg4;
                    } else {
                        const data = try sys.selfGetExtra(extra_idx);
                        if (data.is_cap) return null;

                        reg.* = data.val;
                        extra_idx += 1;
                    }
                }
                const data: Struct = @bitCast(data_as_regs);

                inline for (self.data[0 .. self.data_cnt - 1]) |f| {
                    if (f.encode_type == .err) {
                        @field(ret, f.name) =
                            sys.decodeVoid(@field(data, f.name));
                    } else if (f.encode_type == .raw) {
                        @field(ret, f.name) =
                            @field(data, f.name);
                    } else if (f.encode_type == .tagged_enum) {
                        @field(ret, f.name) =
                            @enumFromInt(@field(data, f.name));
                        // std.meta.intToEnum(f.fake_type, @field(data, f.name)) orelse return null;
                    }
                }
                return ret;
            }
        };
    }
};

fn TupleWithoutFirst(comptime tuple: type) type {
    // if (@typeInfo(tuple) != .@"struct")
    //     return void;

    var s = @typeInfo(tuple).@"struct";
    if (s.fields.len == 0)
        @compileError("cannot pop the first field from an empty struct");
    if (s.fields.len == 1)
        return void;
    // if (s.fields.len == 2)
    //     return s.fields[1].type;

    var fields: [s.fields.len - 1]std.builtin.Type.StructField = undefined;
    inline for (s.fields[1..], 0..) |f, i| {
        fields[i] = f;
        fields[i].name = s.fields[i].name;
    }
    s.fields = &fields;
    return @Type(.{ .@"struct" = s });
}

fn tuplePopFirst(tuple: anytype) TupleWithoutFirst(@TypeOf(tuple)) {
    // if (@typeInfo(@TypeOf(tuple)) != .@"struct")
    //     return {};

    const Result = TupleWithoutFirst(@TypeOf(tuple));

    const prev = @typeInfo(@TypeOf(tuple)).@"struct";

    if (prev.fields.len == 0)
        @compileError("cannot pop the first field from an empty struct");
    if (prev.fields.len == 1)
        return {};
    // if (prev.fields.len == 2)
    //     return tuple.@"1";

    const next = @typeInfo(Result).@"struct";

    var result: Result = undefined;
    inline for (prev.fields[1..], next.fields) |prev_f, next_f| {
        @field(result, next_f.name) = @field(tuple, prev_f.name);
    }

    return result;
}

fn UnwrappedTuple(comptime tuple: type) type {
    if (@typeInfo(tuple) != .@"struct")
        return tuple;
    const s = @typeInfo(tuple).@"struct";
    if (s.fields.len == 0)
        return void;
    if (s.fields.len == 1)
        return s.fields[0].type;
    return tuple;
}

fn unwrapTuple(tuple: anytype) UnwrappedTuple(@TypeOf(tuple)) {
    return tuplePopFirst(.{0} ++ tuple);
}

test "comptime RPC Protocol generator" {
    var compile_but_dont_run = true;
    std.mem.doNotOptimizeAway(&compile_but_dont_run);
    if (compile_but_dont_run) return;

    const Proto = Protocol(struct {
        hello1: fn (val: usize) sys.Error!void,
        hello2: fn () void,
        hello3: fn (frame: caps.Frame) struct { sys.Error!void, usize },
    });

    const client = Proto.Client().init(.{});
    const res1 = client.call(.hello1, .{5});
    const res2 = client.call(.hello2, {});
    const res3 = client.call(.hello3, .{try caps.Frame.create(0x1000)});

    try std.testing.expect(@TypeOf(res1) == sys.Error!struct { sys.Error!void });
    try std.testing.expect(@TypeOf(res2) == sys.Error!struct { void });
    try std.testing.expect(@TypeOf(res3) == sys.Error!struct { sys.Error!void, usize });

    const S = struct {
        fn hello1(_: void, _: u32, request: struct { usize }) struct { sys.Error!void } {
            std.log.info("pm hello1 request: {}", .{request});
            return .{{}};
        }

        fn hello2(_: void, _: u32, request: void) struct { void } {
            std.log.info("pm hello2 request: {}", .{request});
            return .{{}};
        }

        fn hello3(_: void, _: u32, request: struct { caps.Frame }) struct { sys.Error!void, usize } {
            std.log.info("pm hello3 request: {}", .{request});
            return .{ {}, 0 };
        }
    };

    const server = Proto.Server(.{}, .{
        .hello1 = S.hello1,
        .hello2 = S.hello2,
        .hello3 = S.hello3,
    }).init({}, .{});
    try std.testing.expectError(sys.Error.InvalidCapability, server.run());
}
