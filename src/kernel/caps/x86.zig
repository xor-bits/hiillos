const std = @import("std");
const abi = @import("abi");

const addr = @import("../addr.zig");
const apic = @import("../apic.zig");
const arch = @import("../arch.zig");
const caps = @import("../caps.zig");
const pmem = @import("../pmem.zig");

pub const HalVmem = @import("x86/HalVmem.zig");
pub const X86IoPort = @import("x86/X86IoPort.zig");
pub const X86Irq = @import("x86/X86Irq.zig");
pub const X86IoPortAllocator = X86IoPort.X86IoPortAllocator;
pub const X86IrqAllocator = X86Irq.X86IrqAllocator;

//

pub fn init() !void {
    try HalVmem.init_global();
}
