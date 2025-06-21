const std = @import("std");
const abi = @import("abi");

const caps = @import("caps.zig");

const Error = abi.sys.Error;

//

pub const Slice = struct {
    bytes: ?[]u8,

    pub fn fromSingle(ptr: anytype) @This() {
        return .{ .bytes = std.mem.asBytes(ptr) };
    }

    pub fn fromSlice(bytes: []const u8) @This() {
        return .{ .bytes = bytes };
    }

    pub fn next(self: *@This()) error{}!?[]u8 {
        defer self.bytes = &.{};
        return self.bytes;
    }

    pub fn deinit(_: *@This()) void {}
};

pub const SliceConst = struct {
    bytes: ?[]const u8,

    pub fn fromSingle(ptr: anytype) @This() {
        return .{ .bytes = std.mem.asBytes(ptr) };
    }

    pub fn fromSlice(bytes: []const u8) @This() {
        return .{ .bytes = bytes };
    }

    pub fn next(self: *@This()) error{}!?[]const u8 {
        defer self.bytes = &.{};
        return self.bytes;
    }

    pub fn deinit(_: *@This()) void {}
};

pub fn tryInterAddressSpaceCopy(
    _src: anytype,
    _dst: anytype,
    _bytes: usize,
    progress: *usize,
) Error!void {
    var src = _src;
    var dst = _dst;
    var bytes = _bytes;

    const Src = @typeInfo(
        @typeInfo(
            @typeInfo(
                @TypeOf(@typeInfo(
                    @TypeOf(src),
                ).pointer.child.next),
            ).@"fn".return_type.?,
        ).error_union.payload,
    ).optional.child;

    const Dst = @typeInfo(
        @typeInfo(
            @typeInfo(
                @TypeOf(@typeInfo(
                    @TypeOf(dst),
                ).pointer.child.next),
            ).@"fn".return_type.?,
        ).error_union.payload,
    ).optional.child;

    var src_cur: Src = &.{};
    var dst_cur: Dst = &.{};

    while (true) {
        if (bytes == 0) break;

        if (src_cur.len == 0)
            src_cur = (try src.next()) orelse return Error.InvalidAddress;
        if (dst_cur.len == 0)
            dst_cur = (try dst.next()) orelse return Error.InvalidAddress;
        if (src_cur.len == 0 or dst_cur.len == 0) return Error.InvalidAddress;

        const limit = @min(bytes, src_cur.len, dst_cur.len);
        bytes -= limit;
        progress.* += limit;

        @memcpy(dst_cur[0..limit], src_cur[0..limit]);
        dst_cur = dst_cur[limit..];
        src_cur = src_cur[limit..];
    }
}

test {
    const a: []const u8 = "hello";
    var b: u64 = 0;

    var src = SliceConst.fromSlice(a);
    defer src.deinit();
    var dst = Slice.fromSingle(&b);
    defer dst.deinit();

    var progress: usize = 0;
    try tryInterAddressSpaceCopy(&src, &dst, 4, &progress);

    if (progress != 4)
        return error.ExpectEqual1;
    if (b != 0x6c6c6568)
        return error.ExpectEqual2;
}

test {
    const a: []const u8 = "hello";
    var b: [8]u8 = [_]u8{0} ** 8;

    var src = SliceConst.fromSlice(a);
    defer src.deinit();
    var dst = Slice.fromSingle(&b);
    defer dst.deinit();

    var progress: usize = 0;
    if (Error.InvalidAddress != tryInterAddressSpaceCopy(&src, &dst, 6, &progress))
        return error.ExpectEqual1;

    if (progress != 5)
        return error.ExpectEqual2;
    if (!std.mem.eql(u8, &b, "hello\x00\x00\x00"))
        return error.ExpectEqual3;
}
