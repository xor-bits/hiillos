const std = @import("std");
const abi = @import("abi");

const Glyph = @import("font").Glyph;

const log = std.log.scoped(.util);

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

pub const Parser = struct {
    bytes: []const u8,

    pub fn init(bytes: []const u8) Parser {
        return .{ .bytes = bytes };
    }

    pub fn read(self: *Parser, comptime T: type) !T {
        switch (@typeInfo(T)) {
            .Int => return try self.readInt(T),
            .Array => return try self.readArray(T),
            .Struct => return try self.readStruct(T),
            else => @compileError("unsupported type"),
        }
    }

    pub fn readInt(self: *Parser, comptime T: type) !T {
        const size = @sizeOf(T);
        if (self.bytes.len <= size) {
            return error.UnexpectedEof;
        }

        const value: *align(1) const T = @ptrCast(self.bytes);
        self.bytes = self.bytes[size..];

        return value.*;
    }

    pub fn readArray(self: *Parser, comptime T: type) !T {
        if (self.bytes.len <= @sizeOf(T)) {
            return error.UnexpectedEof;
        }

        const array = @typeInfo(T).Array;

        var instance: [array.len]array.child = undefined;

        inline for (0..array.len) |i| {
            instance[i] = try self.read(array.child);
        }

        return instance;
    }

    pub fn readStruct(self: *Parser, comptime T: type) !T {
        if (self.bytes.len <= @sizeOf(T)) {
            return error.UnexpectedEof;
        }

        const fields = @typeInfo(T).Struct.fields;

        var instance: T = undefined;

        inline for (fields) |field| {
            @field(instance, field.name) = try self.read(field.type);
        }

        return instance;
    }

    pub fn bytesLeft(self: *const Parser) []const u8 {
        return self.bytes;
    }
};

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
                abi.util.copyForwardsVolatile(u8, to_row_slice, from_row_slice);
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
    };
}

const Pixel = struct {
    red: u8,
    green: u8,
    blue: u8,
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

pub fn AsVolatile(comptime T: type) type {
    var ptr = @typeInfo(T);
    ptr.pointer.is_volatile = true;
    return @Type(ptr);
}

pub fn volat(ptr: anytype) AsVolatile(@TypeOf(ptr)) {
    return ptr;
}
