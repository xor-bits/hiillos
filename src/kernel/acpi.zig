const abi = @import("abi");
const std = @import("std");

const addr = @import("addr.zig");
const apic = @import("apic.zig");
const arch = @import("arch.zig");
const boot = @import("boot.zig");
const caps = @import("caps.zig");
const hpet = @import("hpet.zig");

const log = std.log.scoped(.acpi);

//

var maybe_mcfg: ?*const SdtHeader = null;

//

pub fn init() !void {
    if (arch.cpuId() == 0)
        log.info("init ACPI", .{});

    const rsdp_resp = boot.rsdp.response orelse {
        return error.NoRsdp;
    };

    const rsdp: *const Rsdp = if (rsdp_resp.revision >= 3)
        addr.Phys.fromInt(@intFromPtr(rsdp_resp.address)).toHhdm().toPtr(*const Rsdp)
    else
        @ptrCast(rsdp_resp.address);
    // log.debug("RSDP={*}", .{rsdp});
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
        try acpiv2(rsdp);
    }
}

pub fn bootInfoInstallMcfg(boot_info: *caps.Frame, thread: *caps.Thread) !void {
    const mcfg_table = maybe_mcfg orelse return;

    var it = @as(*const Mcfg, @ptrCast(mcfg_table)).iterator();
    if (it.next()) |entry| {
        const mcfg_paddr = addr.Phys.fromInt(entry.base_addr);

        const mcfg_obj = try caps.Frame.initPhysical(mcfg_paddr, 0x10000000);
        const mcfg_info_obj = try caps.Frame.init(@sizeOf(abi.FramebufferInfoFrame), .{});

        try mcfg_info_obj.initialWrite(0, std.mem.asBytes(&abi.McfgInfoFrame{
            .pci_segment_group = entry.pci_segment_group,
            .start_pci_bus = entry.start_pci_bus,
            .end_pci_bus = entry.end_pci_bus,
        }));

        var id: u32 = undefined;
        id = try thread.proc.pushCapability(.init(mcfg_obj, null));
        try boot_info.initialWrite(
            @offsetOf(abi.BootInfo, "mcfg"),
            std.mem.asBytes(&abi.caps.Frame{ .cap = id }),
        );

        id = try thread.proc.pushCapability(.init(mcfg_info_obj, null));
        try boot_info.initialWrite(
            @offsetOf(abi.BootInfo, "mcfg_info"),
            std.mem.asBytes(&abi.caps.Frame{ .cap = id }),
        );
    }

    if (it.next()) |_| {
        log.warn("TODO: other MCFG entries discarded", .{});
    }
}

fn acpiv1(rsdp: *const Rsdp) !void {
    if (arch.cpuId() == 0)
        log.info("ACPI v1", .{});

    // FIXME: this is unaligned most of the time, but zig doesnt like that
    const rsdt: *const Rsdt = addr.Phys.fromInt(rsdp.rsdt_addr).toHhdm().toPtr(*const Rsdt);
    if (arch.cpuId() == 0)
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
    if (arch.cpuId() == 0)
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
            .MCFG => maybe_mcfg = sdt,
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

pub const Madt = extern struct {
    header: SdtHeader align(1),
    lapic_addr: u32 align(1),
    flags: u32 align(1),

    pub fn iterator(self: *const @This()) Iterator {
        return .{
            .header = &self.header,
            .ext_len = 0,
        };
    }

    pub const Iterator = struct {
        header: *const SdtHeader,
        ext_len: usize,

        pub fn next(self: *@This()) ?AnyEntry {
            while (true) {
                if (self.ext_len >= self.header.length - @sizeOf(Madt))
                    return null;

                const entry_base: *const Entry = @ptrFromInt(@intFromPtr(self.header) + self.ext_len + @sizeOf(Madt));
                self.ext_len += entry_base.record_len;

                switch (entry_base.entry_type) {
                    0 => return AnyEntry{ .processor_local_apic = @ptrCast(entry_base) },
                    1 => return AnyEntry{ .ioapic = @ptrCast(entry_base) },
                    2 => return AnyEntry{ .ioapic_interrupt_source_override = @ptrCast(entry_base) },
                    3 => return AnyEntry{ .ioapic_nmi_source = @ptrCast(entry_base) },
                    4 => return AnyEntry{ .lapic_nmis = @ptrCast(entry_base) },
                    5 => return AnyEntry{ .lapic_addr_override = @ptrCast(entry_base) },
                    9 => return AnyEntry{ .processor_lx2apic = @ptrCast(entry_base) },
                    else => {}, // ignore others
                }
            }
        }
    };

    pub const AnyEntry = union(enum) {
        processor_local_apic: *const ProcessorLocalApic,
        ioapic: *const IoApic,
        ioapic_interrupt_source_override: *const IoApicInterruptSourceOverride,
        ioapic_nmi_source: *const IoApicNmiSource,
        lapic_nmis: *const LapicNmis,
        lapic_addr_override: *const LapicAddrOverride,
        processor_lx2apic: *const ProcessorLx2apic,
    };

    pub const Entry = extern struct {
        entry_type: u8,
        record_len: u8,
    };

    pub const ProcessorLocalApic = extern struct {
        entry: Entry align(1),
        acpi_processor_id: u8,
        apic_id: u8,
        flags: u32 align(1),
    };

    pub const IoApic = extern struct {
        entry: Entry align(1),
        io_apic_id: u8,
        reserved: u8,
        io_apic_addr: u32 align(1),
        global_system_interrupt_base: u32 align(1),
    };

    pub const IoApicInterruptSourceOverride = extern struct {
        entry: Entry align(1),
        bus_source: u8,
        irq_source: u8,
        global_system_interrupt: u32 align(1),
        flags: u16 align(1),
    };

    pub const IoApicNmiSource = extern struct {
        entry: Entry align(1),
        nmi_source: u8,
        reserved: u8,
        flags: u16 align(1),
        global_system_interrupt: u32 align(1),
    };

    pub const LapicNmis = extern struct {
        entry: Entry align(1),
        acpi_processor_id: u8,
        flags: u16 align(1),
        lint: u8,
    };

    pub const LapicAddrOverride = extern struct {
        entry: Entry align(1),
        lapic_addr: u64 align(1),
    };

    pub const ProcessorLx2apic = extern struct {
        entry: Entry align(1),
        local_x2apic_id: u32 align(1),
        flags: u32 align(1),
        acpi_id: u32 align(1),
    };
};

pub const Mcfg = extern struct {
    header: SdtHeader align(1),
    _reserved: u64 align(1),

    pub fn iterator(self: *const @This()) Iterator {
        return .{
            .header = &self.header,
            .ext_len = 0,
        };
    }

    pub const Iterator = struct {
        header: *const SdtHeader,
        ext_len: usize,

        pub fn next(self: *@This()) ?*const Entry {
            while (true) {
                if (self.ext_len >= self.header.length - @sizeOf(Mcfg))
                    return null;

                const entry: *const Entry = @ptrFromInt(@intFromPtr(self.header) + self.ext_len + @sizeOf(Mcfg));
                self.ext_len += 16;

                return entry;
            }
        }
    };

    pub const Entry = extern struct {
        base_addr: u64 align(1),
        pci_segment_group: u16 align(1),
        start_pci_bus: u8 align(1),
        end_pci_bus: u8 align(1),
        _reserved: u32 align(1),
    };
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
