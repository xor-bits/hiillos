const abi = @import("abi");
const std = @import("std");

const arch = @import("arch.zig");
const addr = @import("addr.zig");
const caps = @import("caps.zig");
const main = @import("main.zig");
const copy = @import("copy.zig");
const proc = @import("proc.zig");

const futex = @import("call/futex.zig");

const log = std.log.scoped(.call);
const conf = abi.conf;
const Error = abi.sys.Error;
const Rights = abi.sys.Rights;

var syscall_stats: std.EnumArray(abi.sys.Id, std.atomic.Value(usize)) = .initFill(.init(0));

//

pub fn syscall(trap: *arch.TrapRegs) void {
    defer std.debug.assert(arch.cpuLocal().current_thread != null);

    // TODO: once every CPU has reached this, bootloader_reclaimable memory could be freed
    // just some few things need to be copied, but the page map(s) and stack(s) are already copied

    const id = std.meta.intToEnum(abi.sys.Id, trap.syscall_id) catch {
        @branchHint(.cold);
        log.warn("invalid syscall: {x}", .{trap.syscall_id});
        trap.syscall_id = abi.sys.encode(abi.sys.Error.InvalidSyscall);
        return;
    };

    const locals = arch.cpuLocal();
    const thread = locals.current_thread.?;

    if (conf.LOG_SYSCALLS and id != .self_yield)
        log.debug("syscall: {s} from {*}", .{ @tagName(id), thread });
    defer if (conf.LOG_SYSCALLS and id != .self_yield)
        log.debug("syscall: {s} done", .{@tagName(id)});

    if (conf.LOG_SYSCALL_STATS) {
        _ = syscall_stats.getPtr(id).fetchAdd(1, .monotonic);
    }

    if (conf.LOG_SYSCALL_STATS and id == .log) {
        log.debug("syscalls:", .{});
        var it = syscall_stats.iterator();
        while (it.next()) |e| {
            const v = e.value.load(.monotonic);
            log.debug(" - {}: {}", .{ e.key, v });
        }
    }

    handle_syscall(id, thread, trap) catch |err| {
        @branchHint(.cold);
        if (err != Error.Retry)
            log.warn("syscall error {}: {} ({})", .{ id, err, trap.readMessage() });
        trap.syscall_id = abi.sys.encode(err);
    };

    if (locals.current_thread == null) {
        // all locks are unlocked now and the CPU
        // can halt while waiting for threads
        proc.switchNow(trap);
    }

    std.debug.assert(locals.held_lock_count == 0);

    // if (conf.IS_DEBUG) {
    //     const new_thread = locals.current_thread.?;
    //     new_thread.lock.lock();
    //     defer new_thread.lock.unlock();
    //     if (new_thread.status != .running)
    //         std.debug.panic("call={} status={}", .{
    //             id,
    //             new_thread.status,
    //         });
    // }
}

fn handle_syscall(
    id: abi.sys.Id,
    thread: *caps.Thread,
    trap: *arch.TrapRegs,
) Error!void {
    switch (id) {
        .log => {
            // FIXME: disable on release builds

            const vaddr = try addr.Virt.fromUser(trap.arg0);

            // log syscall
            var len = trap.arg1;
            if (len > 0x1000)
                return Error.InvalidArgument;

            _ = std.math.add(u64, vaddr.raw, len) catch
                return Error.InvalidArgument;

            // log.debug("log of {} bytes from 0x{x}", .{
            //     len,
            //     vaddr.raw,
            // });

            var it = thread.proc.vmem.data(vaddr, false);
            defer it.deinit();

            var bytes: usize = 0;
            defer trap.arg0 = bytes;

            while (try it.next()) |chunk| {
                const limit = @min(len, chunk.len);
                len -= limit;
                bytes += limit;

                var lines = std.mem.splitAny(u8, @volatileCast(chunk[0..limit]), "\n\r");
                while (lines.next()) |line| {
                    if (line.len == 0) continue;
                    log.info("{s}", .{line});
                }

                if (len == 0) break;
            }

            trap.syscall_id = abi.sys.encode(0);
        },
        .kernel_panic => {
            if (!conf.KERNEL_PANIC_SYSCALL)
                return abi.sys.Error.InvalidSyscall;

            @panic("manual kernel panic");
        },

        .frame_create => {
            const size_bytes = trap.arg0;
            const flags = abi.sys.FrameCreateFlags.decode(trap.arg1);
            const frame = try caps.Frame.init(size_bytes, flags);
            errdefer frame.deinit();

            const handle = try thread.proc.pushCapabilityDefaultRights(frame);
            trap.syscall_id = abi.sys.encode(handle);
        },
        .frame_get_size => {
            const frame: *caps.Frame = try thread.proc.getCapabilityAs(
                @truncate(trap.arg0),
                .frame,
                .{},
            );
            defer frame.deinit();

            trap.syscall_id = abi.sys.encode(0);
            trap.arg0 = frame.size_bytes;
        },
        .frame_read => {
            const offset_bytes = trap.arg1;
            const vaddr = try addr.Virt.fromUser(trap.arg2);
            const bytes = trap.arg3;
            const frame: *caps.Frame = try thread.proc.getCapabilityAs(
                @truncate(trap.arg0),
                .frame,
                .{ .min_rights = .{ .read = true } },
            );
            defer frame.deinit();

            var progress: usize = 0;
            defer trap.arg0 = progress;
            var dst = thread.proc.vmem.data(vaddr, true);
            defer dst.deinit();
            var src = frame.data(offset_bytes, false);
            defer src.deinit();

            try copy.tryInterAddressSpaceCopy(
                &src,
                &dst,
                bytes,
                &progress,
            );
            trap.syscall_id = abi.sys.encode(0);
        },
        .frame_write => {
            const offset_bytes = trap.arg1;
            const vaddr = try addr.Virt.fromUser(trap.arg2);
            const bytes = trap.arg3;
            const frame: *caps.Frame = try thread.proc.getCapabilityAs(
                @truncate(trap.arg0),
                .frame,
                .{ .min_rights = .{ .write = true } },
            );
            defer frame.deinit();

            var progress: usize = 0;
            defer trap.arg0 = progress;
            var src = thread.proc.vmem.data(vaddr, false);
            defer src.deinit();
            var dst = frame.data(offset_bytes, true);
            defer dst.deinit();

            try copy.tryInterAddressSpaceCopy(
                &src,
                &dst,
                bytes,
                &progress,
            );
            trap.syscall_id = abi.sys.encode(0);
        },
        .frame_dummy_access => {
            const offset_byte = trap.arg1;
            const mode: abi.sys.FaultCause = std.meta.intToEnum(abi.sys.FaultCause, trap.arg2) catch {
                return Error.InvalidArgument;
            };
            const rights = mode.rights();
            const frame: *caps.Frame = try thread.proc.getCapabilityAs(
                @truncate(trap.arg0),
                .frame,
                .{ .min_rights = rights },
            );
            defer frame.deinit();

            trap.syscall_id = abi.sys.encode(0);
            const res = frame.pageFault(
                @truncate(offset_byte / 0x1000),
                mode == .write,
                null,
                trap,
                thread,
            );
            if (res == Error.Retry) {
                return;
            } else {
                _ = try res;
            }
        },
        .frame_dump => {
            const frame: *caps.Frame = try thread.proc.getCapabilityAs(
                @truncate(trap.arg0),
                .frame,
                .{},
            );
            defer frame.deinit();

            frame.lock.lock();
            defer frame.lock.unlock();

            log.info("frame: {*} is_transient={}", .{ frame, frame.is_transient });
            for (frame.chunks) |p| {
                log.info(" - 0x{x}", .{p});
            }
        },

        .vmem_create => {
            const vmem = try caps.Vmem.init();
            errdefer vmem.deinit();

            const handle = try thread.proc.pushCapabilityDefaultRights(vmem);
            trap.syscall_id = abi.sys.encode(handle);
        },
        .vmem_self => {
            const vmem_self = thread.proc.vmem;

            const handle = try thread.proc.pushCapabilityDefaultRights(vmem_self);
            // clone it late, because it is currently owned anyways
            // this avoids the deinit path completely
            vmem_self.base.clone();
            trap.syscall_id = abi.sys.encode(handle);
        },
        .vmem_map => {
            const frame_first_page: u32 = @truncate(trap.arg2 / 0x1000);
            const vaddr = try addr.Virt.fromUser(trap.arg3);
            const flags = abi.sys.MapFlags.decode(@truncate(trap.arg5));
            const rights = flags.rights();

            if (!std.mem.isAligned(vaddr.raw, 0x1000)) {
                return Error.InvalidAddress;
            }

            const vmem: *caps.Vmem = try thread.proc.getCapabilityAs(
                @truncate(trap.arg0),
                .vmem,
                .{ .min_rights = rights },
            );
            defer vmem.deinit();
            const frame: *caps.Frame = try thread.proc.getCapabilityAs(
                @truncate(trap.arg1),
                .frame,
                .{ .min_rights = rights },
            );
            errdefer frame.deinit();

            // map takes ownership of the frame
            const pages: u32 = if (trap.arg4 == 0)
                @intCast(@max(frame.chunks.len * frame.chunk_size.sizePages(), frame_first_page) - frame_first_page)
            else
                @truncate(std.math.divCeil(usize, trap.arg4, 0x1000) catch unreachable);

            const mapped_vaddr = try vmem.map(
                frame,
                frame_first_page,
                vaddr,
                pages,
                flags,
            );

            std.debug.assert(mapped_vaddr.raw < 0x8000_0000_0000);
            trap.syscall_id = abi.sys.encode(@truncate(mapped_vaddr.raw));
        },
        .vmem_unmap => {
            const pages: u32 = @truncate(std.math.divCeil(usize, trap.arg2, 0x1000) catch unreachable);
            if (pages == 0) {
                trap.syscall_id = abi.sys.encode(0);
                return;
            }
            const vaddr = try addr.Virt.fromUser(trap.arg1);

            if (!std.mem.isAligned(vaddr.raw, 0x1000)) {
                return Error.InvalidAddress;
            }

            const vmem: *caps.Vmem = try thread.proc.getCapabilityAs(
                @truncate(trap.arg0),
                .vmem,
                .{ .min_rights = .{ .unmap = true } },
            );
            defer vmem.deinit();

            trap.syscall_id = abi.sys.encode(0);
            vmem.unmap(
                trap,
                thread,
                vaddr,
                pages,
                false,
            ) catch |err| switch (err) {
                Error.Retry => return,
                else => return err,
            };
        },
        .vmem_read => {
            const src_vaddr = try addr.Virt.fromUser(trap.arg1);
            const dst_vaddr = try addr.Virt.fromUser(trap.arg2);
            const bytes = trap.arg3;
            const vmem: *caps.Vmem = try thread.proc.getCapabilityAs(
                @truncate(trap.arg0),
                .vmem,
                .{ .min_rights = .{ .read = true } },
            );
            defer vmem.deinit();

            var progress: usize = 0;
            defer trap.arg0 = progress;
            var dst = vmem.data(dst_vaddr, true);
            defer dst.deinit();
            var src = thread.proc.vmem.data(src_vaddr, false);
            defer src.deinit();

            try copy.tryInterAddressSpaceCopy(
                &src,
                &dst,
                bytes,
                &progress,
            );
            trap.syscall_id = abi.sys.encode(0);
        },
        .vmem_write => {
            const dst_vaddr = try addr.Virt.fromUser(trap.arg1);
            const src_vaddr = try addr.Virt.fromUser(trap.arg2);
            const bytes = trap.arg3;
            const vmem: *caps.Vmem = try thread.proc.getCapabilityAs(
                @truncate(trap.arg0),
                .vmem,
                .{ .min_rights = .{ .write = true } },
            );
            defer vmem.deinit();

            var progress: usize = 0;
            defer trap.arg0 = progress;
            var dst = vmem.data(dst_vaddr, true);
            defer dst.deinit();
            var src = thread.proc.vmem.data(src_vaddr, false);
            defer src.deinit();

            try copy.tryInterAddressSpaceCopy(
                &src,
                &dst,
                bytes,
                &progress,
            );
            trap.syscall_id = abi.sys.encode(0);
        },
        .vmem_dummy_access => {
            const vaddr = try addr.Virt.fromUser(trap.arg1);
            const mode: abi.sys.FaultCause = std.meta.intToEnum(abi.sys.FaultCause, trap.arg2) catch {
                return Error.InvalidArgument;
            };
            const rights = mode.rights();
            const vmem: *caps.Vmem = try thread.proc.getCapabilityAs(
                @truncate(trap.arg0),
                .vmem,
                .{ .min_rights = rights },
            );
            defer vmem.deinit();

            trap.syscall_id = abi.sys.encode(0);
            const res = vmem.pageFault(
                mode,
                vaddr,
                trap,
                thread,
            );
            if (res == Error.Retry) {
                return;
            } else {
                _ = try res;
            }
        },
        .vmem_dump => {
            const vmem: *caps.Vmem = try thread.proc.getCapabilityAs(
                @truncate(trap.arg0),
                .vmem,
                .{},
            );
            defer vmem.deinit();

            vmem.lock.lock();
            defer vmem.lock.unlock();

            log.info("vmem: {*} cr3=0x{x}", .{ vmem, vmem.hal_vmem.pml4.raw });
            for (vmem.mappings.items) |mapping| {
                log.info(" - [ 0x{x:0>16}..0x{x:0>16} ]: {*}", .{
                    mapping.getVaddr().raw,
                    mapping.getVaddr().raw + mapping.pages * 0x1000,
                    mapping.frame,
                });
            }
            log.info("halvmem", .{});
            try vmem.hal_vmem.printMappings();
        },

        .proc_create => {
            const from_vmem: *caps.Vmem = try thread.proc.getCapabilityAs(
                @truncate(trap.arg0),
                .vmem,
                .{},
            );
            comptime var from_vmem_owned = true;
            defer if (from_vmem_owned) from_vmem.deinit();

            const new_proc = try caps.Process.init(from_vmem);
            from_vmem_owned = false;
            errdefer new_proc.deinit();

            const handle = try thread.proc.pushCapabilityDefaultRights(new_proc);
            trap.syscall_id = abi.sys.encode(handle);
        },
        .proc_self => {
            const proc_self = thread.proc;

            const handle = try thread.proc.pushCapabilityDefaultRights(proc_self);
            proc_self.base.clone();
            proc_self.deinit();
            trap.syscall_id = abi.sys.encode(handle);
        },
        .proc_give_cap => {
            const target_proc: *caps.Process = try thread.proc.getCapabilityAs(
                @truncate(trap.arg0),
                .process,
                .{},
            );
            defer target_proc.deinit();

            const handle = try thread.proc.transferCapability(
                target_proc,
                @truncate(trap.arg1),
            );
            trap.syscall_id = abi.sys.encode(handle);
        },
        .proc_wait => {
            const target_proc: *caps.Process = try thread.proc.getCapabilityAs(
                @truncate(trap.arg0),
                .process,
                .{},
            );
            defer target_proc.deinit();

            trap.syscall_id = abi.sys.encode(0);
            try target_proc.waitExit(thread, trap);
        },
        .proc_exit => {
            proc.switchFrom(trap, thread);
            thread.proc.exit(trap.arg0, null);
        },

        .thread_create => {
            const from_proc: *caps.Process = try thread.proc.getCapabilityAs(
                @truncate(trap.arg0),
                .process,
                .{},
            );
            comptime var from_proc_owned = true;
            defer if (from_proc_owned) from_proc.deinit();

            const new_thread = try caps.Thread.init(from_proc);
            comptime var new_thread_owned = true;
            from_proc_owned = false;
            errdefer if (new_thread_owned) new_thread.deinit();

            const handle = try thread.proc.pushCapabilityDefaultRights(new_thread);
            new_thread_owned = false;
            trap.syscall_id = abi.sys.encode(handle);
        },
        .thread_self => {
            const thread_self = thread;

            const handle = try thread.proc.pushCapabilityDefaultRights(thread_self);
            thread_self.base.clone();
            trap.syscall_id = abi.sys.encode(handle);
        },
        .thread_read_regs => {
            const regs_ptr = try addr.Virt.fromUser(trap.arg1);
            const target_thread: *caps.Thread = try thread.proc.getCapabilityAs(
                @truncate(trap.arg0),
                .thread,
                .{ .min_rights = .{ .read = true } },
            );
            defer target_thread.deinit();

            const regs: abi.sys.ThreadRegs = target_thread.readRegs();
            var src = copy.SliceConst.fromSingle(&regs);
            defer src.deinit();
            var dst = thread.proc.vmem.data(regs_ptr, true);
            defer dst.deinit();

            var progress: usize = 0;
            try copy.tryInterAddressSpaceCopy(
                &src,
                &dst,
                @sizeOf(abi.sys.ThreadRegs),
                &progress,
            );
            trap.syscall_id = abi.sys.encode(0);
        },
        .thread_write_regs => {
            const regs_ptr = try addr.Virt.fromUser(trap.arg1);
            const target_thread: *caps.Thread = try thread.proc.getCapabilityAs(
                @truncate(trap.arg0),
                .thread,
                .{ .min_rights = .{ .write = true } },
            );
            defer target_thread.deinit();

            var regs: abi.sys.ThreadRegs = undefined;
            var src = thread.proc.vmem.data(regs_ptr, false);
            defer src.deinit();
            var dst = copy.Slice.fromSingle(&regs);
            defer dst.deinit();

            var progress: usize = 0;
            try copy.tryInterAddressSpaceCopy(
                &src,
                &dst,
                @sizeOf(abi.sys.ThreadRegs),
                &progress,
            );
            target_thread.writeRegs(regs);
            trap.syscall_id = abi.sys.encode(0);
        },
        .thread_start => {
            const target_thread: *caps.Thread = try thread.proc.getCapabilityAs(
                @truncate(trap.arg0),
                .thread,
                .{},
            );
            defer target_thread.deinit();

            trap.syscall_id = abi.sys.encode(0);
            try target_thread.start();
        },
        .thread_stop => {
            const target_thread: *caps.Thread = try thread.proc.getCapabilityAs(
                @truncate(trap.arg0),
                .thread,
                .{},
            );
            defer target_thread.deinit();

            trap.syscall_id = abi.sys.encode(0);
            try target_thread.stop(thread, trap);
        },
        .thread_set_prio => {
            const target_thread: *caps.Thread = try thread.proc.getCapabilityAs(
                @truncate(trap.arg0),
                .thread,
                .{},
            );
            defer target_thread.deinit();

            target_thread.lock.lock();
            defer target_thread.lock.unlock();

            target_thread.priority = @truncate(trap.arg1);
            trap.syscall_id = abi.sys.encode(0);
        },
        .thread_wait => {
            const target_thread: *caps.Thread = try thread.proc.getCapabilityAs(
                @truncate(trap.arg0),
                .thread,
                .{},
            );
            defer target_thread.deinit();

            trap.syscall_id = abi.sys.encode(0);
            try target_thread.waitExit(thread, trap);
        },
        .thread_set_sig_handler => {
            const target_thread: *caps.Thread = try thread.proc.getCapabilityAs(
                @truncate(trap.arg0),
                .thread,
                .{},
            );
            defer target_thread.deinit();

            target_thread.signal_handler = trap.arg1;
            trap.syscall_id = abi.sys.encode(0);
        },
        .thread_exit => {
            proc.switchFrom(trap, thread);
            thread.exit(trap.arg0);
        },

        .channel_create => {
            const rx, const tx = try caps.Channel.init();
            errdefer {
                rx.deinit();
                tx.deinit();
            }
            var handles: [2]u32 = undefined;

            try thread.proc.pushCapabilitiesDefaultRights(
                2,
                .{ rx, tx },
                &handles,
            );

            trap.arg0 = handles[1];
            trap.syscall_id = abi.sys.encode(handles[0]);
        },
        .receiver_recv => {
            const recv: *caps.Receiver = try thread.proc.getCapabilityAs(
                @truncate(trap.arg0),
                .receiver,
                .{},
            );
            defer recv.deinit();

            trap.syscall_id = abi.sys.encode(0);
            try recv.recv(thread, trap);
        },
        .receiver_reply => {
            var msg = trap.readMessage();

            msg.cap_or_stamp = 0; // call doesnt get to know the Receiver capability id
            try caps.Receiver.reply(thread, msg);

            trap.syscall_id = abi.sys.encode(0);
        },
        .receiver_reply_recv => {
            @branchHint(.likely);
            var msg = trap.readMessage();

            const recv: *caps.Receiver = try thread.proc.getCapabilityAs(
                msg.cap_or_stamp,
                .receiver,
                .{},
            );
            defer recv.deinit();

            msg.cap_or_stamp = 0; // call doesnt get to know the Receiver capability id
            try recv.replyRecv(thread, trap, msg);
        },

        .reply_create => {
            const reply = try caps.Reply.init(thread);
            errdefer reply.deinit();

            const handle = try thread.proc.pushCapabilityDefaultRights(reply);
            trap.syscall_id = abi.sys.encode(handle);
        },
        .reply_reply => {
            var msg = trap.readMessage();

            const reply: *caps.Reply = try thread.proc.takeCapabilityAs(
                msg.cap_or_stamp,
                .reply,
                .{},
            );
            defer reply.deinit(); // destroys the object

            msg.cap_or_stamp = 0; // call doesnt get to know the Receiver capability id
            // the only error is allowed to destroy the object, so the defer deinit ↑ is fine
            try reply.reply(thread, msg);

            trap.syscall_id = abi.sys.encode(0);
        },

        .sender_stamp => {
            const sender: *caps.Sender = try thread.proc.getCapabilityAs(
                @truncate(trap.arg0),
                .sender,
                .{ .min_rights = .{ .tag = true } },
            );
            defer sender.deinit();

            const new_send = try sender.restamp(@truncate(trap.arg1));
            errdefer new_send.deinit();
            const handle = try thread.proc.pushCapabilityDefaultRights(new_send);
            trap.syscall_id = abi.sys.encode(handle);
        },
        .sender_send => {
            const msg = trap.readMessage();
            const sender: *caps.Sender = try thread.proc.getCapabilityAs(
                @truncate(trap.arg0),
                .sender,
                .{},
            );
            defer sender.deinit();

            try sender.send(msg);
        },
        .sender_call => {
            @branchHint(.likely);
            const msg = trap.readMessage();
            const sender: *caps.Sender = try thread.proc.getCapabilityAs(
                msg.cap_or_stamp,
                .sender,
                .{},
            );
            defer sender.deinit();

            try sender.call(thread, trap, msg);
        },

        .notify_create => {
            const notify = try caps.Notify.init();
            errdefer notify.deinit();

            const handle = try thread.proc.pushCapabilityDefaultRights(notify);
            trap.syscall_id = abi.sys.encode(handle);
        },
        .notify_wait => {
            const notify: *caps.Notify = try thread.proc.getCapabilityAs(
                @truncate(trap.arg0),
                .notify,
                .{},
            );
            defer notify.deinit();

            trap.syscall_id = abi.sys.encode(0);
            notify.wait(thread, trap);
        },
        .notify_poll => {
            const notify: *caps.Notify = try thread.proc.getCapabilityAs(
                @truncate(trap.arg0),
                .notify,
                .{},
            );
            defer notify.deinit();

            trap.syscall_id = abi.sys.encode(@intFromBool(notify.poll()));
        },
        .notify_notify => {
            const notify: *caps.Notify = try thread.proc.getCapabilityAs(
                @truncate(trap.arg0),
                .notify,
                .{},
            );
            defer notify.deinit();

            trap.syscall_id = abi.sys.encode(@intFromBool(notify.notify()));
        },

        .x86_ioport_create => {
            const allocator: *caps.X86IoPortAllocator = try thread.proc.getCapabilityAs(
                @truncate(trap.arg0),
                .x86_ioport_allocator,
                .{},
            );
            defer allocator.deinit();

            const ioport = try caps.X86IoPort.init(allocator, @truncate(trap.arg1));
            errdefer ioport.deinit();

            const handle = try thread.proc.pushCapabilityDefaultRights(ioport);
            trap.syscall_id = abi.sys.encode(handle);
        },
        .x86_ioport_inb => {
            const ioport: *caps.X86IoPort = try thread.proc.getCapabilityAs(
                @truncate(trap.arg0),
                .x86_ioport,
                .{},
            );
            defer ioport.deinit();

            trap.syscall_id = abi.sys.encode(ioport.inb());
        },
        .x86_ioport_outb => {
            const ioport: *caps.X86IoPort = try thread.proc.getCapabilityAs(
                @truncate(trap.arg0),
                .x86_ioport,
                .{},
            );
            defer ioport.deinit();

            ioport.outb(@truncate(trap.arg1));
            trap.syscall_id = abi.sys.encode(0);
        },

        .x86_irq_create => {
            const allocator: *caps.X86IrqAllocator = try thread.proc.getCapabilityAs(
                @truncate(trap.arg0),
                .x86_irq_allocator,
                .{},
            );
            defer allocator.deinit();

            const irq = try caps.X86Irq.init(allocator, @truncate(trap.arg1));
            errdefer irq.deinit();

            const handle = try thread.proc.pushCapabilityDefaultRights(irq);
            trap.syscall_id = abi.sys.encode(handle);
        },
        .x86_irq_subscribe => {
            const irq: *caps.X86Irq = try thread.proc.getCapabilityAs(
                @truncate(trap.arg0),
                .x86_irq,
                .{},
            );
            defer irq.deinit();

            const notify = try irq.subscribe();
            errdefer notify.deinit();

            const handle = try thread.proc.pushCapabilityDefaultRights(notify);
            trap.syscall_id = abi.sys.encode(handle);
        },
        .x86_irq_ack => {
            return Error.InvalidSyscall;
        },

        .handle_identify => {
            const cap = try thread.proc.getCapability(
                @truncate(trap.arg0),
                .{},
            );
            defer cap.deinit();

            trap.syscall_id = abi.sys.encode(@intFromEnum(cap.type));
        },
        .handle_rights => {
            const rights = try thread.proc.getCapabilityRights(
                @truncate(trap.arg0),
                .{},
            );

            trap.arg0 = rights.encode();
            trap.syscall_id = abi.sys.encode(0);
        },
        .handle_restrict => {
            const mask = abi.sys.Rights.decode(trap.arg1);
            try thread.proc.restrictCapability(@truncate(trap.arg0), mask);

            trap.syscall_id = abi.sys.encode(0);
        },
        .handle_duplicate => {
            const handle = try thread.proc.cloneCapability(
                @truncate(trap.arg0),
            );
            trap.syscall_id = abi.sys.encode(handle);
        },
        .handle_close => {
            thread.proc.closeCapability(@truncate(trap.arg0));
            trap.syscall_id = abi.sys.encode(0);
        },
        .handle_dbg_filter => {
            if (!conf.IS_DEBUG) return Error.InvalidSyscall;

            const obj = try thread.proc.getCapability(
                @truncate(trap.arg0),
                .{},
            );
            defer obj.deinit();

            switch (obj.type) {
                inline .thread => |as| {
                    const cast_obj = obj.downcast(caps.Object.typeOf(as));
                    cast_obj.lock.lock();
                    cast_obj.dbg_filter = trap.arg1 != 0;
                    cast_obj.lock.unlock();
                },
                else => {},
            }
        },

        .futex_wait => try futex.wait(trap, thread),
        .futex_wake => try futex.wake(trap, thread),
        .futex_requeue => try futex.requeue(trap, thread),

        .self_yield => {
            proc.yield(trap);
        },
        .self_dump => {
            log.info("selfDump: {}", .{trap.*});
        },
        .self_set_extra => {
            const idx: u7 = @truncate(trap.arg0);
            const val: u64 = @truncate(trap.arg1);
            const is_cap: bool = trap.arg2 != 0;

            if (is_cap) {
                const object, const rights = try thread.proc.takeCapability(
                    @truncate(val),
                    .{ .min_rights = .{ .transfer = true } },
                );

                thread.setExtraLockedExec(
                    idx,
                    .{
                        .object = object,
                        .rights = rights,
                    },
                );
            } else {
                // `rights` store the extra slot u64 value when the object is null
                thread.setExtraLockedExec(
                    idx,
                    .{
                        .object = null,
                        .rights = .decode(val),
                    },
                );
            }

            trap.syscall_id = abi.sys.encode(0);
        },
        .self_get_extra => {
            const idx: u7 = @truncate(trap.arg0);

            const handle = try thread.proc.allocSlot();
            const data = thread.getExtraLockedExec(idx);

            if (data.object) |object| {
                thread.proc.insertCapability(
                    handle,
                    object,
                    data.rights,
                );
                trap.arg0 = handle;
                trap.syscall_id = abi.sys.encode(1);
            } else {
                thread.proc.freeSlot(handle);
                // `rights` store the extra slot u64 value when the object is null
                trap.arg0 = data.rights.encode();
                trap.syscall_id = abi.sys.encode(0);
            }
        },
        .self_get_signal => {
            const sig_ptr = try addr.Virt.fromUser(trap.arg0);

            const sig: abi.sys.Signal = thread.signal orelse return Error.NotMapped;
            var src = copy.SliceConst.fromSingle(&sig);
            defer src.deinit();
            var dst = thread.proc.vmem.data(sig_ptr, true);
            defer dst.deinit();

            var progress: usize = 0;
            try copy.tryInterAddressSpaceCopy(
                &src,
                &dst,
                @sizeOf(abi.sys.Signal),
                &progress,
            );

            thread.signal = null;
            trap.syscall_id = abi.sys.encode(0);
        },
    }
}
