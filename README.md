<div align="center">

# hiillos

hiillos is an operating system with its own microkernel
all written in pure Zig

</div>

The plan is for the kernel to be just a scheduler, an IPC relay,
a physical memory manager and a virtual memory manager.

The system design ~~steals~~ borrows ideas from:
 - Zircon: the reference counted capability model
 - seL4: synchronous IPC endpoints and asynchronous signals
 - RedoxOS: optional filesystem schema (URI protocol here) to reference different services,
like fs:///etc/hosts, initfs:///sbin/init, tcp://10.0.0.1:80 or https://archlinux.org

## Running in QEMU

```bash
zig build run # thats it

# read 'Project-Specific Options' from `zig build --help` for more options
zig build run -Dtest=true # include custom unit test runner
```

## Building an ISO

```bash
zig build # generates the os.iso in zig-out/os.iso
```

## Stuff included here

 - kernel: [src/kernel](/src/kernel)
 - kernel/user interface: [src/abi](src/abi)
 - root process: [src/userspace/root](src/userspace/root)

## TODOs and roadmap

### NOTE: /path/to/something is a short form for fs:///path/to/something

- [x] kernel
  - [x] PMM
  - [x] VMM
    - [ ] PCID for better context switch performance
    - [x] Mapping cache modes with PAT, uncacheable, write-combining,
          write-through, write-protect, write-back and uncached
  - [x] GDT, TSS, IDT
  - [x] ACPI, APIC
  - [x] SMP
  - [x] HPET
  - [ ] TSC
  - [ ] I/O Privilege Bitmap for port io caps (IOPB)
  - [x] scheduler
  - [x] binary loader
  - [x] stack tracer with line info
  - [x] message IPC, shared memory IPC
    - [ ] multiple parallel recvs to the same endpoint
    - [x] multiple parallel calls to the same endpoint
  - [x] figure out userland interrupts (ps2 keyboard, ..)
  - [x] capabilities
    - [x] free list of capabilities
    - [x] allocate capabilities
    - [x] deallocate capabilities
    - [x] map capabilities
    - [x] unmap capabilities
    - [x] send capabilities
    - [x] disallow mapping a frame twice without cloning the cap
    - [x] disallow overlapping maps
    - [ ] restrict capability rights, ex: read-only frame can only create read-only frames
    - [x] scrap the derivation tree, use refcounts like Zircon
    - [x] per process handle tables, allowing more dynamic kernel object metadata (user handle (u32) is an index to process local table, which holds a pointer (and rights) to a kernel object)
    - [x] objects
      - [x] Thread
      - [x] Vmem
      - [x] Frame
        - [x] multiple Frame caps to the same physical memory (for shared memory)
        - [x] lazy alloc
        - [x] map into multiple `Vmem`s
        - [ ] copy on write
        - [ ] use a multi-level tree to store the pages, like how hardware page tables do it
        - [ ] custom Frames where the creator provides data on page faults and gets notified when all other handles are closed
        - [ ] set_size
        - [ ] 2MiB and 1GiB pages
      - [x] Receiver
      - [x] Reply
      - [x] Sender
      - [x] Notify
  - [x] syscalls
    - [x] move all object methods to be syscalls
    - [x] syscall tracker
    - [x] method call tracker
    - [x] futex

- [x] user-space
  - [x] posix abstraction layer, like `open` instead of the manual ipc call
  - [x] stack traces with line info

- [x] root + initfsd process
  - [x] decompress initfs.tar.zst
  - [x] server manifest embedded into the ELF
    - [x] name
    - [x] imports
    - [x] exports
  - [x] execute servers
  - [x] grant server imports and exports

- [x] initfs:///sbin/pm server process
  - [x] executes processes and gives them capabilities

- [x] initfs:///sbin/vfs server process
  - [x] create fs://
  - [ ] exec required root filesystem drivers
  - [ ] read /etc/fstab before mounting root (root= kernel cli arg)
  - [ ] mount everything according to /etc/fstab
  - [ ] exec other filesystem drivers lazily

- [x] initfs:///sbin/init process
  - [ ] launch initfs:///sbin/rngd
  - [ ] launch initfs:///sbin/vfsd
  - [x] launch services from initfs://
<!---
  - [ ] launch /bin/wm
-->

- [ ] initfs:///sbin/fsd.fat32

- [ ] initfs:///sbin/rngd process

- [ ] /sbin/outputd process

- [ ] /sbin/kbd process

- [ ] /sbin/moused process

- [ ] /sbin/timed process

- [ ] /sbin/fbd process

- [ ] /sbin/pcid process

- [ ] /sbin/usbd process

## IPC performance

Approximate synchronous IPC performance: `call` + `replyRecv`
loop takes about 349ns (2 864 198 per second) (in QEMU+KVM with Ryzen 9 5950X):

```zig
// server
while (true) {
    msg = try rx.replyRecv(msg);
}
// client
while (true) {
    try tx.call(.{});
}
```

## Gallery
    
![image](https://github.com/user-attachments/assets/e508b174-1ccd-4830-aa00-68ec27faba77)
![image](https://github.com/user-attachments/assets/a11dbcd1-6afb-4f2f-ba08-40af514a712b)
<img width="1284" height="832" alt="image" src="https://github.com/user-attachments/assets/d06fa0ee-0bd6-4de0-974f-b77f3d0c226a" />
<img width="1284" height="832" alt="image" src="https://github.com/user-attachments/assets/13414bbb-5b2e-4db0-9fc2-3461f0be58b6" />
