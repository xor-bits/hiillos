const std = @import("std");

//

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);
    if (args.len != 3) return error.@"missing output file argument";

    const input_file = try std.fs.cwd().readFileAlloc(arena, args[1], 1_000_000);
    const glyphs = try generateGlyphs(input_file);

    var output_file = try std.fs.cwd().createFile(args[2], .{});
    defer output_file.close();

    var buffer: [0x2000]u8 = undefined;

    var output_writer = output_file.writer(&buffer);
    const output = &output_writer.interface;

    // std.fmt.format(, , )
    try output.writeAll(
        \\pub const Glyph = struct {
        \\    img: [16]u16,
        \\    wide: bool,
        \\};
        \\
        \\pub const glyphs: [256]Glyph = .{
        \\
    );
    for (glyphs) |glyph| {
        try output.writeAll("    .{");
        try output.writeAll(".wide=");
        if (glyph.wide) {
            try output.writeAll("true,");
        } else {
            try output.writeAll("false,");
        }
        try output.writeAll(".img=.{");
        for (glyph.img) |row| {
            try output.print("{d}", .{row});
            try output.writeAll(",");
        }
        try output.writeAll("}");
        try output.writeAll("},\n");
    }
    // try output.print("{any}", .{glyphs});
    try output.writeAll("};");

    try output.flush();
}

const Glyph = struct {
    img: [16]u16,
    wide: bool,
};

fn generateGlyphs(bmp: []const u8) ![256]Glyph {
    const font_raw = try parseBmp(bmp);
    // const font_raw = try parseBmp(@embedFile("./font.bmp"));

    var font = std.mem.zeroes([256]Glyph);

    for (0..16) |y| {
        for (0..256) |i| {
            for (0..16) |x| {
                // the weird for loop order is for cache locality
                const is_white: u16 =
                    @intCast(@intFromBool(255 != font_raw.pixel_array[x * 3 + i * 16 * 3 + y * font_raw.pitch]));
                font[i].img[15 - y] |= is_white << @intCast(x);
            }
        }
    }

    for (0..256) |i| {
        for (0..16) |y| {
            if (font[i].img[y] >= 0x100) {
                font[i].wide = true;
                break;
            }
        }
    }

    return font;
}

const Image = struct {
    width: u32,
    height: u32,
    pitch: u32,
    bits_per_pixel: u16,
    pixel_array: []const u8,
};

pub const BmpError = error{
    UnexpectedEof,
    InvalidIdentifier,
    UnexpectedSize,
};

pub const Parser = struct {
    bytes: []const u8,

    pub fn init(bytes: []const u8) Parser {
        return .{ .bytes = bytes };
    }

    pub fn read(self: *Parser, comptime T: type) !T {
        switch (@typeInfo(T)) {
            .int => return try self.readInt(T),
            .array => return try self.readArray(T),
            .@"struct" => return try self.readStruct(T),
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

        const array = @typeInfo(T).array;

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

        const fields = @typeInfo(T).@"struct".fields;

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

fn parseBmp(bmp: []const u8) !Image {
    var parser = Parser.init(bmp);

    const bmp_header = parser.readStruct(struct {
        ident: u16,
        bmp_header_size: u32,
        _pad: [2]u16,
        offs: u32,
    }) catch return BmpError.UnexpectedEof;

    const dib_header = parser.readStruct(struct {
        dib_header_size: u32,
        width: u32,
        height: u32,
        color_planes_len: u16,
        bits_per_pixel: u16,
        pixel_array_compression: u32,
        image_size: u32,
        pixel_per_meter_horizontal: u32,
        pixel_per_meter_vertical: u32,
        colors_len: u32,
        important_colors_len: u32,
        red_mask: u32,
        green_mask: u32,
        blue_mask: u32,
        alpha_mask: u32,
        color_space: u32,
        color_space_endpoints: [0x24]u32,
        red_gamma: u32,
        green_gamma: u32,
        blue_gamma: u32,
    }) catch return BmpError.UnexpectedEof;

    // TODO: if either is zero
    if (dib_header.width != 4096 or dib_header.height != 16) {
        return BmpError.UnexpectedSize;
    }

    if (bmp_header.ident != 0x4D42) {
        return BmpError.InvalidIdentifier;
    }

    if (bmp.len < bmp_header.offs + dib_header.image_size) {
        return BmpError.UnexpectedEof;
    }

    return .{
        .width = dib_header.width,
        .height = dib_header.height,
        .pitch = dib_header.image_size / dib_header.height,
        .bits_per_pixel = dib_header.bits_per_pixel,
        .pixel_array = @constCast(bmp[bmp_header.offs .. bmp_header.offs + dib_header.image_size]),
    };
}
