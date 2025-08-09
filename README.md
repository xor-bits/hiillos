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
