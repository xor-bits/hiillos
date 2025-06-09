const std = @import("std");

const caps = @import("caps.zig");

//

// pub fn serialize(comptime T: type, msg: T) void {}

// fn serializeRecurse(comptime T: type, msg: T, reg_idx: u7) void {}

// pub fn deserialize(comptime T: type) T {

// }

// pub const MessageInfo = struct {
//     /// number of capabilities that need to use the extra regs
//     cap_count: u7 = 0,
//     /// number of inlined bytes in this message
//     data_size: u32 = 0,
//     /// number of extra items 'out-of-line', aka not inlined to the message
//     out_of_line: usize = 0,

//     pub fn merge(self: @This(), other: @This()) @This() {
//         return .{
//             .cap_count = self.cap_count + other.cap_count,
//             .data_size = self.data_size + other.data_size,
//             .out_of_line = self.out_of_line + other.out_of_line,
//         };
//     }
// };

// pub fn messageInfo(comptime T: type) MessageInfo {
//     switch (T) {
//         // special case types
//         caps.Handle,
//         caps.Thread,
//         caps.Process,
//         caps.Vmem,
//         caps.Frame,
//         caps.Receiver,
//         caps.Reply,
//         caps.Sender,
//         caps.Notify,
//         caps.X86IoPortAllocator,
//         caps.X86IoPort,
//         caps.X86IrqAllocator,
//         caps.X86Irq,
//         => return .{ .cap_count = 1 },

//         f64,
//         f32,
//         f16,
//         usize,
//         u128,
//         u64,
//         u32,
//         u16,
//         u8,
//         isize,
//         i128,
//         i64,
//         i32,
//         i16,
//         i8,
//         void,
//         => return .{ .data_size = @sizeOf(T) },
//     }
// }

// /// count the number of out-of-line fields
// fn outOfLineCount(comptime T: type) usize {

//     // special case types
//     switch (T) {
//         caps.Handle,
//         caps.Thread,
//         caps.Process,
//         caps.Vmem,
//         caps.Frame,
//         caps.Receiver,
//         caps.Reply,
//         caps.Sender,
//         caps.Notify,
//         caps.X86IoPortAllocator,
//         caps.X86IoPort,
//         caps.X86IrqAllocator,
//         caps.X86Irq,
//         f64,
//         f32,
//         f16,
//         usize,
//         u128,
//         u64,
//         u32,
//         u16,
//         u8,
//         isize,
//         i128,
//         i64,
//         i32,
//         i16,
//         i8,
//         void,
//         => return 0,
//     }

//     std.builtin.Type;

//     switch (@typeInfo(T)) {
//         .Struct => {},
//     }
// }

// pub fn call() void {}

test "encode test" {}
