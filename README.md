# Moonhead OS

> **Status:** `v0.1.0-alpha` (Developer Preview) — ARM64 runtime boot-tested
> locally on macOS QEMU `hvf`.

Moonhead is an experimental Linux distribution built from upstream Linux
7.3.4, a Rust PID 1, an immutable EROFS system image, and an
Ubuntu-derived package base. It is intended for controlled VM and appliance
evaluation; it is not yet a production-certified distribution.

## Runtime overview

```text
┌────────────────────────────────────────────────────────┐
│                    QEMU / UEFI                         │
├────────────────────────────────────────────────────────┤
│  Kernel: upstream Linux 7.3.4                          │
│                                                        │
│  Boot:   MOONHEAD_ESP                                   │
│  System: MOONHEAD_ROOT_A/B + MOONHEAD_HASH_A/B          │
│           dm-verity → read-only EROFS root               │
│                                                        │
│  State:  MOONHEAD_STATE + MOONHEAD_DATA                 │
│           boot health, rollback, persistent overlays    │
│                                                        │
│  PID 1:  moonhead-init                                  │
└────────────────────────────────────────────────────────┘
```

## Build from source

Use an ARM64 Ubuntu host or VM with Rust, Cargo, and `sudo` access.

Prepare an update-verification public key outside the repository. Private
keys and build outputs must not be committed. An SSH public key is optional.

```bash
git clone https://github.com/neerajkrsna/moonhead.git
cd moonhead
make deps
make kernel
make iso \
  UPDATE_PUBLIC_KEY_FILE=/secure/moonhead-update-public.pem
```

The build prompts for the `admin` password. This password is enabled for both
console and SSH login. To add key-based SSH login as well, pass
`SSH_PUBKEY_FILE="$HOME/.ssh/id_ed25519.pub"`.

The installer ISO is written to:

```text
build/arm64/moonhead-arm64.iso
```

Architecture-specific artifacts carry their architecture in the filename, for
example `rootfs-arm64.erofs`, `moonhead-arm64.img`, `vmlinuz-arm64`, and
`io_uring_lsm-arm64.bpf.o`. AMD64 builds use the equivalent `-amd64` names.
Names that remain unchanged inside the installed OS are architecture-neutral
runtime paths, such as `/usr/lib/moonhead/io_uring_lsm.bpf.o`.

To build a directly bootable disk image instead:

```bash
make image \
  UPDATE_PUBLIC_KEY_FILE=/secure/moonhead-update-public.pem
```

Other generated formats are available through `make vmdk` and `make ova`.
All generated artifacts remain below `build/`; `make clean` removes them.

## Sync source from the Ubuntu VM

To refresh this repository from `/home/risvai/core-os` without copying generated
artifacts, run:

```bash
scripts/sync-from-vm.sh --dry-run
scripts/sync-from-vm.sh
```

SSH credentials are read from the user's normal SSH configuration. To use a
specific key:

```bash
SSH_KEY=~/.ssh/id_ed25519 scripts/sync-from-vm.sh --dry-run
```

The script supports `VM_HOST`, `VM_USER`, and `VM_PATH` overrides. It syncs
implementation directories and `Makefile` only; README, docs, licenses, GitHub
configuration, and repository metadata are preserved.

## Boot on macOS

```bash
brew install qemu zstd
qemu-system-aarch64 \
  -M virt -accel hvf -cpu host -smp 4 -m 2G -nographic \
  -bios /opt/homebrew/share/qemu/edk2-aarch64-code.fd \
  -drive file=moonhead-arm64.img,format=raw,if=virtio \
  -netdev user,id=net0,hostfwd=tcp::2222-:22,hostfwd=udp::9999-:9999 \
  -device virtio-net-pci,netdev=net0
```

```bash
ssh -p 2222 admin@localhost
```

Enter the password provided while building the image.

## Install from the ISO

After booting the ISO, identify the target disk with `lsblk` and run:

```bash
sudo moonhead-install --yes-wipe /dev/vda
```

This command destroys all data on the selected disk. It refuses mounted
devices, the installer media, undersized disks, and installation without the
explicit `--yes-wipe` argument.

## Updates

Updates must be signed by the private key corresponding to the public key
embedded during the image build.

```bash
make signed-update \
  UPDATE_PUBLIC_KEY_FILE=/secure/moonhead-update-public.pem \
  UPDATE_SIGNING_KEY=/secure/moonhead-update-private.pem \
  UPDATE_VERSION=0.2.0
```

Apply the generated `build/arm64/update/` bundle on the appliance:

```bash
sudo moonhead-update /path/to/update
sudo reboot
```

## ARM64 release qualification

Run both qualification paths on ARM64 images built with the same `admin`
password. The tests require QEMU, ARM64 UEFI firmware, `sshpass`, `sgdisk`, and
`qemu-img`.

Qualify direct-image boot, persistence, signed update, and rollback:

```bash
ADMIN_PASSWORD='test-password' make image \
  UPDATE_PUBLIC_KEY_FILE=/secure/moonhead-update-public.pem
ADMIN_PASSWORD='test-password' make signed-update \
  UPDATE_PUBLIC_KEY_FILE=/secure/moonhead-update-public.pem \
  UPDATE_SIGNING_KEY=/secure/moonhead-update-private.pem \
  UPDATE_VERSION=0.1.0-qualify
ADMIN_PASSWORD='test-password' make qualify-arm64
```

This test deliberately corrupts the updated B slot and verifies that the next
successful boot returns to healthy slot A without losing persistent state.

Qualify the installer ISO separately:

```bash
ADMIN_PASSWORD='test-password' make iso \
  UPDATE_PUBLIC_KEY_FILE=/secure/moonhead-update-public.pem
ADMIN_PASSWORD='test-password' make qualify-arm64-iso
```

The installer test boots the ISO, installs to a blank virtual disk, reboots,
and verifies password SSH plus healthy A-slot state.

## Repository layout

```text
Makefile            Build entry points
moonhead-ebpf/       Kernel-side programs
moonhead-init/       Rust PID 1 and service tools
kernel/fragments/   Kernel configuration
profiles/           Root filesystem package list
scripts/            Rootfs, image, ISO, installer, and update scripts
```
