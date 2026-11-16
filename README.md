# Moonhead (`CORE-OS`)

An experimental ARM64 Linux distribution combining pristine upstream **Linux 7.3.4**, a memory-safe **Rust PID 1 (`coreos-pid1`)** with **zero `systemd` or `dbus`**, an immutable **`erofs`** root filesystem paired with a persistent **`ext4` `overlayfs`**, in-kernel **eBPF LSM `io_uring` filtering**, and **FD-only Landlock sandboxing (`core-jail`)**.

The current prototype builds an ARM64 Ubuntu-based root filesystem with a
custom Rust PID 1 and Linux 7.3.4. The project was built and boot-tested in an
Ubuntu VM. This is experimental software, not a production-ready OS: its
image configuration enables password SSH access, configures passwordless
sudo for the administrator, and removes the root password. Do not expose it
to untrusted networks or use it for sensitive workloads.

Linux 7.3 is a stable kernel branch, not an upstream LTS branch. The kernel
source, compiled binaries, disk images, ISOs, VMDKs, and OVAs are not committed.


> **Warning — Experimental Software:** The current prototype is built and boot-tested in ARM64 VMs and is **not** a production-ready OS. Its image configuration enables password SSH access, configures passwordless `sudo` for `admin`, and removes the root password. Do not expose it to untrusted networks or use it for sensitive workloads.
>
> Linux 7.3 is a stable kernel branch, not an upstream LTS branch. Kernel source, compiled binaries, disk images, ISOs, VMDKs, and OVAs are excluded from Git.

## Architecture Highlights

- **Zero-`systemd` Rust PID 1 (`coreos-pid1`):** Supervises services via `epoll`/`signalfd`, isolates PID 1 filesystem state (`unshare(CLONE_FS)`), captures service output in sealed `memfd` ring buffers, and provides `service`, `journalctl`, and `netplan` CLI shims.
- **Immutable Root + Persistent Overlay (`COREOS_DATA`):** Boots from a read-only compressed `erofs` partition (`COREOS_ROOT`, ~85 MB) while overlaying `/etc`, `/var`, `/usr`, `/root`, and `/home` onto a persistent `ext4` partition (`COREOS_DATA`).
- **Sub-20 ms Hardware & Network Bring-Up:** Auto-configures `zstd`-compressed ZRAM swap at 50% of RAM, registers microsecond `EPOLLPRI` PSI memory-pressure cache-shedding triggers, and configures interfaces over Linux `rtnetlink` (with `udhcpc` fallback).
- **In-Kernel eBPF LSM `io_uring` Gatekeeper (`coreos-ebpf/`):** Hooks `uring_sqpoll`, `uring_override_creds`, and `uring_cmd` via BTF CO-RE to block privileged/raw `io_uring` operations for jailed cgroups.
- **FD-Only Landlock Isolation (`core-jail`):** Strips ambient filesystem authority by default; processes access only subtrees explicitly passed via `--ro` or `--rw` file descriptors.

## Repository Layout

```text
├── Makefile                    # Kernel fetch/build, eBPF, Rust .deb, rootfs & image targets
├── coreos-ebpf/                # CO-RE eBPF LSM programs (io_uring_lsm.bpf.c)
├── coreos-pid1/                # Rust PID 1 supervisor, Netlink Netplan, PSI guard & CLI shims
├── kernel/fragments/           # Minimal Linux 7.3 Kconfig fragment (BTF, BPF_LSM, EROFS, sched_ext)
├── profiles/                   # Declarative mmdebstrap package manifest (base.packages)
└── scripts/                    # Zero-systemd rootfs, GPT UEFI .img, and hybrid .iso builders


## Build the ARM64 prototype

Use an ARM64 Ubuntu Linux machine or VM with network access, Rust and Cargo
installed, and sufficient disk space for kernel compilation and generated
images. The build downloads and compiles Linux and uses `sudo` to assemble the
root filesystem. Use a supported Ubuntu release for a build host; the default
target suite is Ubuntu 26.04 (`resolute`).

From the repository root:

```sh
make deps
sudo apt-get install -y grub-efi-arm64-bin dosfstools mtools gdisk \
  e2fsprogs xorriso busybox-static qemu-utils
make kernel
make iso
```

`make kernel` fetches the upstream Linux 7.3.4 source and builds it with the
configuration fragment in `kernel/fragments/`. The `iso` target builds the
eBPF program, Rust package and root filesystem before producing
`build/arm64/coreos-arm64.iso`. On first build, allow time and disk space for
the kernel and package downloads.

During rootfs assembly, enter a nonempty password for the image's `admin`
account when prompted. No default password is committed. The password is
passed to the rootfs builder in its environment, so use a trusted build
host. Treat the resulting image and its credentials as sensitive. The
builder may include a public SSH key from the home directory of the user
running the rootfs script (normally root via `sudo`).

Other outputs, built locally rather than stored in Git:

```sh
make image  # build/arm64/coreos-arm64.img
make vmdk   # build/arm64/coreos-arm64.vmdk
make ova    # build/arm64/coreos-arm64.ova
```

To boot the root filesystem directly with QEMU after building it:

```sh
make run-qemu
```

The image scripts replace their own output and staging directories under
`build/`; `make clean` removes the entire `build/` directory. Back up any
outputs you need before running either.
