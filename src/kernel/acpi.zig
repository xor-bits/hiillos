const std = @import("std");
const limine = @import("limine");

const apic = @import("apic.zig");
const arch = @import("arch.zig");
const addr = @import("addr.zig");
const hpet = @import("hpet.zig");

const log = std.log.scoped(.acpi);

//

pub export var rsdp_req: limine.RsdpRequest = .{};

//

pub fn init() !void {
    if (arch.cpuId() == 0)
        log.info("init ACPI", .{});

    const rsdp_resp: *limine.RsdpResponse = rsdp_req.response orelse {
        return error.NoRsdp;
    };

    const rsdp: *const Rsdp = if (rsdp_resp.revision >= 3)
        addr.Phys.fromInt(@intFromPtr(rsdp_resp.address)).toHhdm().toPtr(*const Rsdp)
    else
        @ptrCast(rsdp_resp.address);
    log.debug("RSDP={*}", .{rsdp});
    if (!isChecksumValid(Rsdp, rsdp)) {
        return error.InvalidRsdpChecksum;
    }
    if (!std.mem.eql(u8, rsdp.signature[0..], "RSD PTR ")) {
        return error.InvalidRsdpSignature;
    }

    if (arch.cpuId() == 0)
        log.info("ACPI OEM: {s}", .{rsdp.oem_id});

    if (rsdp.revision == 0) {
        try acpiv1(rsdp);
    } else {
        log.err("no x2APIC support", .{});
        try acpiv2(rsdp);
    }
}

fn acpiv1(rsdp: *const Rsdp) !void {
    if (arch.cpuId() == 0)
        log.info("ACPI v1", .{});

    // FIXME: this is unaligned most of the time, but zig doesnt like that
    const rsdt: *const Rsdt = addr.Phys.fromInt(rsdp.rsdt_addr).toHhdm().toPtr(*const Rsdt);
    log.debug("RSDT={*}", .{rsdt});
    if (!isChecksumValid(Rsdt, rsdt)) {
        return error.InvalidRsdtChecksum;
    }
    if (!std.mem.eql(u8, rsdt.header.signature[0..], "RSDT")) {
        return error.InvalidRsdtSignature;
    }

    try walkTables(u32, rsdt.pointers());
}

fn acpiv2(rsdp: *const Rsdp) !void {
    if (arch.cpuId() == 0)
        log.info("ACPI v2", .{});

    const xsdp: *const Xsdp = @ptrCast(rsdp);
    if (!isChecksumValid(Xsdp, xsdp)) {
        return error.InvalidRsdpChecksum;
    }

    const xsdt: *const Xsdt = addr.Phys.fromInt(xsdp.xsdt_addr).toHhdm().toPtr(*const Xsdt);
    log.debug("XSDT={*}", .{xsdt});
    if (!isChecksumValid(Xsdt, xsdt)) {
        return error.InvalidXsdtChecksum;
    }
    if (!std.mem.eql(u8, xsdt.header.signature[0..], "XSDT")) {
        return error.InvalidXsdtSignature;
    }

    try walkTables(u64, xsdt.pointers());
}

fn walkTables(comptime T: type, pointers: []align(1) const T) !void {
    var maybe_apic: ?*const SdtHeader = null;
    var maybe_hpet: ?*const SdtHeader = null;

    if (arch.cpuId() == 0)
        log.info("SDT Headers:", .{});
    for (pointers) |sdt_ptr| {
        const sdt: *const SdtHeader = addr.Phys.fromInt(sdt_ptr).toHhdm().toPtr(*const SdtHeader);
        if (!isChecksumValid(SdtHeader, sdt)) {
            log.warn("skipping invalid SDT: {s}", .{sdt.signature});
            continue;
        }

        if (arch.cpuId() == 0)
            log.info(" - {s}", .{sdt.signature});

        // FIXME: load APIC always before HPET, because HPET uses APIC
        switch (SdtType.fromSignature(sdt.signature)) {
            .APIC => maybe_apic = sdt,
            .HPET => maybe_hpet = sdt,
            else => {},
        }
    }

    const apic_table = maybe_apic orelse {
        return error.ApicTableMissing;
    };
    const hpet_table = maybe_hpet orelse {
        return error.HpetTableMissing;
    };

    try apic.init(@ptrCast(apic_table));
    try hpet.init(@ptrCast(hpet_table));

    try apic.enable();
}

pub const SdtType = enum {
    FACP, // = Advanced Configuration and Power Interface
    APIC, // = MADT = Multiple (Advanced Programmable Interrupt Controller) Description Table (better PIC)
    HPET, // = High Precision Event Timer (better PIT/RTC)
    MCFG, // = PCIe configuration space
    WAET, // = Windows ACPI Emulated Devices, useless
    BGRT, // = Boot Graphics Record Table
    unknown,

    fn fromSignature(signature: [4]u8) @This() {
        const this = @typeInfo(@This()).@"enum";

        inline for (this.fields) |f| {
            if (strToU32(f.name) == signToU32(signature)) {
                return @enumFromInt(f.value);
            }
        }

        return .unknown;
    }

    fn signToU32(s: [4]u8) u32 {
        return @bitCast(s);
    }

    fn strToU32(comptime s: []const u8) u32 {
        if (s.len < 4) {
            @compileError("SDT header string too short");
        }
        const b4: *const [4]u8 = @ptrCast(s.ptr);
        return @bitCast(b4.*);
    }
};

//

pub const Rsdp = extern struct {
    signature: [8]u8 align(1),
    checksum: u8 align(1),
    oem_id: [6]u8 align(1),
    revision: u8 align(1),
    rsdt_addr: u32 align(1),
};

pub const Xsdp = extern struct {
    rsdp: Rsdp align(1),

    length: u32 align(1),
    xsdt_addr: u64 align(1),
    ext_checksum: u8 align(1),
    _reserved: [3]u8 align(1),
};

pub const SdtHeader = extern struct {
    signature: [4]u8 align(1),
    length: u32 align(1),
    revision: u8 align(1),
    checksum: u8 align(1),
    oem_id: [6]u8 align(1),
    oem_table_id: [8]u8 align(1),
    oem_revision: u32 align(1),
    creator_id: u32 align(1),
    creator_revision: u32 align(1),
};

pub const Rsdt = extern struct {
    header: SdtHeader align(1),

    fn pointers(self: *const @This()) []align(1) const u32 {
        const arr_self: [*]const @This() = @ptrCast(self);
        const arr_ptr: [*]align(1) const u32 = @ptrCast(&arr_self[1]);
        return arr_ptr[0 .. (self.header.length - @sizeOf(@This())) / @sizeOf(u32)];
    }
};

pub const Xsdt = extern struct {
    header: SdtHeader align(1),

    fn pointers(self: *const @This()) []align(1) const u64 {
        const arr_self: [*]const @This() = @ptrCast(self);
        const arr_ptr: [*]align(1) const u64 = @ptrCast(&arr_self[1]);
        return arr_ptr[0 .. (self.header.length - @sizeOf(@This())) / @sizeOf(u64)];
    }
};

//

pub fn isChecksumValid(comptime T: type, val: *const T) bool {
    var len: usize = undefined;

    switch (T) {
        SdtHeader, Rsdt, Xsdt => {
            const val_sdt: *const SdtHeader = @ptrCast(val);
            len = val_sdt.length;
        },
        Rsdp => len = @sizeOf(T),
        Xsdp => len = @sizeOf(T),
        else => @compileError("isChecksumValid: unknown type"),
    }

    const bytes_ptr: [*]const u8 = @ptrCast(val);
    const as_bytes = bytes_ptr[0..len];

    var checksum: u8 = 0;
    for (as_bytes) |b| {
        checksum +%= b;
    }

    return checksum == 0;
}
