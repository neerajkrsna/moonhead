# Moonhead (`CORE-OS`)

> **Status:** `v0.1.0-alpha` (Developer Preview) — Single-node immutable + persistent Linux 7.3 LTS runtime verified on ARM64 (macOS QEMU `hvf` & Linux `KVM`).

Moonhead is an experimental, fork-free Linux distribution built on pristine upstream **Linux 7.3.4**, a memory-safe **Rust PID 1 (`coreos-pid1`)** with **zero `systemd` or `dbus`**, cryptographic **`dm-verity` root verification**, an immutable **`erofs`** root paired with a persistent **`ext4` `overlayfs`** (`COREOS_DATA`), in-kernel **eBPF LSM `io_uring` filtering**, **`sched_ext` (`scx_coreos`) task scheduling**, and line-rate **`AF_XDP` zero-copy packet bypassing (`core-xdp`)**.

---

## Architecture & Subsystems

```text
 ┌──────────────────────────────────────────────────────────────┐
 |                      QEMU / UEFI (AAVMF)                     │
 ├──────────────────────────────────────────────────────────────┤
 │  Kernel: Linux 7.3.4 (BTF, BPF_LSM, EROFS, sched_ext, XDP)   │
 ├──────────────────────────────────────────────────────────────┤
 │  Root: /dev/dm-0 (dm-verity verified SHA-256 Merkle Tree)    │
 │        Mounted read-only as compressed erofs                 │
 ├──────────────────────────────────────────────────────────────┤
 │  State: /dev/vda4 (COREOS_DATA ext4 partition)               │
 │         Backed overlayfs on /etc, /var, /usr, /root, /home   │
 ├──────────────────────────────────────────────────────────────┤
 │  PID 1: coreos-pid1 (Rust)                                   │
 │         ├── Hardware Prober (ZRAM swap @ 50% RAM)            │
 │         ├── PSI Memory-Pressure EPOLLPRI Guard               │
 │         ├── Netlink rtnetlink + udhcpc Bring-Up              │
 │         ├── scx_coreos sched_ext BPF Scheduler               │
 │         ├── eBPF LSM io_uring Gatekeeper                     │
 │         └── core-jail Landlock FD Sandboxing                 │
 ├──────────────────────────────────────────────────────────────┤
 │  Fast-Path: core-xdp (AF_XDP UMEM Zero-Copy Socket Bypass)   │
 └──────────────────────────────────────────────────────────────┘
```

### 1. Zero-`systemd` Rust PID 1 (`coreos-pid1`)
- **Supervision & IPC:** Manages child processes via `epoll` and `signalfd`, isolates PID 1 filesystem state (`unshare(CLONE_FS)`), and captures service logs in sealed `memfd` ring buffers.
- **CLI Compatibility Shims:** Provides `service`, `journalctl`, and `netplan` command-line shims for operational familiarity without any background daemon overhead.

### 2. Cryptographic Root Integrity (`dm-verity`)
- **Block-Level Verification:** Computes a SHA-256 Merkle hash tree over `rootfs.erofs` at build time (`veritysetup format`) and passes deterministic `PARTUUID`s via `dm-mod.create=` and `panic_on_corruption`.
- **Zero Initramfs:** Direct kernel-level device-mapper mounting (`/dev/dm-0`) before PID 1 execution.

### 3. Immutable Root + Persistent Overlay (`COREOS_DATA`)
- **Partition Layout:**
  - `COREOS_ESP` (FAT32, 128 MiB): UEFI bootloader (`BOOTAA64.EFI`) & Linux kernel (`vmlinuz`).
  - `COREOS_ROOT` (`erofs`, ~86 MiB): Immutable compressed OS filesystem.
  - `COREOS_VERITY` (`ext4`/raw, ~1 MiB): Merkle verification hash tree.
  - `COREOS_DATA` (`ext4`, 7.5 GiB default): Persistent writable storage backing `/etc`, `/var`, `/usr`, `/root`, and `/home` via `overlayfs`.

### 4. Custom `sched_ext` BPF Scheduler (`scx_coreos`)
- **Cgroup-Aware Tiers:** Dispatches tasks across `/sys/fs/cgroup/coreos.slice/{foreground,batch,jailed}` into tiered Dispatch Queues (DSQs) with automatic EEVDF watchdog failover and 16-dispatch starvation bounds.

### 5. In-Kernel eBPF LSM `io_uring` Gatekeeper & Landlock (`core-jail`)
- **Security Gatekeeping:** BTF CO-RE eBPF LSM programs intercept `uring_sqpoll`, `uring_override_creds`, and raw `uring_cmd` calls for jailed cgroups.
- **Filesystem Isolation:** `core-jail` strips ambient authority; processes access only subtrees explicitly passed via `--ro` or `--rw` file descriptors.

### 6. `AF_XDP` Zero-Copy Fast Path (`core-xdp`)
- **Kernel Bypass:** XDP eBPF program (`xdp_fastpath.bpf.c`) inspects inbound UDP packets and redirects matching flows directly into an `AF_XDP` UMEM ring buffer, bypassing `sk_buff` allocation and `nftables` traversal.

---

## Quickstart 1: Boot Prebuilt Image on macOS (QEMU `hvf`)

1. Download `coreos-arm64.img.zst` from [Releases](https://github.com/neerajkrsna/moonhead/releases) and decompress:
   ```bash
   brew install qemu zstd
   unzstd coreos-arm64.img.zst
   ```
2. Boot under Apple's `Hypervisor.framework`:
   ```bash
   qemu-system-aarch64 \
     -M virt -accel hvf -cpu host -smp 4 -m 2G -nographic \
     -bios /opt/homebrew/share/qemu/edk2-aarch64-code.fd \
     -drive file=coreos-arm64.img,format=raw,if=virtio \
     -netdev user,id=net0,hostfwd=tcp::2222-:22,hostfwd=udp::9999-:9999 \
     -device virtio-net-pci,netdev=net0
   ```
3. Connect via SSH (`ssh -p 2222 admin@localhost`, default password set at build).

---

## Quickstart 2: Build from Source (Ubuntu ARM64 Build Host)

Requires an ARM64 Ubuntu host (tested on Ubuntu 26.04 `resolute` or OrbStack) with Rust, Cargo, and `sudo` access:

```bash
git clone https://github.com/neerajkrsna/moonhead.git
cd moonhead
make deps
sudo apt-get install -y grub-efi-arm64-bin dosfstools mtools gdisk \
  e2fsprogs xorriso busybox-static qemu-utils cryptsetup-bin
make kernel
make image DATA_SIZE_MB=7680
```

- `make kernel`: Fetches upstream Linux 7.3.4 and compiles with BTF, BPF_LSM, EROFS, `sched_ext`, and `dm-verity` configurations.
- `make image`: Generates the 4-partition UEFI GPT disk image (`build/arm64/coreos-arm64.img`) with dm-verity Merkle trees and persistent `COREOS_DATA`.

---

## Repository Layout

```text
├── Makefile                    # Kernel fetch/build, eBPF, Rust .deb, rootfs & image targets
├── coreos-ebpf/                # CO-RE eBPF programs (io_uring_lsm.bpf.c, scx_coreos.bpf.c, xdp_fastpath.bpf.c)
├── coreos-pid1/                # Rust PID 1 supervisor, Netlink Netplan, core-xdp & CLI shims
├── kernel/fragments/           # Minimal Linux 7.3 Kconfig fragment
├── profiles/                   # Declarative mmdebstrap package manifest (base.packages)
└── scripts/                    # Zero-systemd rootfs, dm-verity, and GPT UEFI .img builders
```

---

## Roadmap & Status

- [x] Pristine upstream Linux 7.3.4 + Rust PID 1 (`coreos-pid1`) + `erofs` immutable root
- [x] Hardware prober (ZRAM), `EPOLLPRI` PSI guard, Netlink Netplan & `service`/`journalctl` shims
- [x] CO-RE eBPF LSM `io_uring` gatekeeper + FD-only Landlock `core-jail`
- [x] `dm-verity` cryptographic root verification + 4-partition GPT UEFI images (`.img`, `.iso`, `.ova`)
- [x] Custom `sched_ext` BPF scheduler (`scx_coreos`) with cgroup-aware tier dispatch
- [x] `AF_XDP` zero-copy packet fast path (`core-xdp`)