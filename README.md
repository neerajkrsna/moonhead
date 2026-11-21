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

Prepare an administrator SSH public key and an update-verification public
key outside the repository. Private keys and build outputs must not be
committed.

```bash
git clone https://github.com/neerajkrsna/moonhead.git
cd moonhead
make deps
make kernel
make iso \
  SSH_PUBKEY_FILE="$HOME/.ssh/id_ed25519.pub" \
  UPDATE_PUBLIC_KEY_FILE=/secure/moonhead-update-public.pem
```

The build prompts for the administrator console password. SSH password
authentication is disabled, so the supplied SSH public key is used for remote
access.

The installer ISO is written to:

```text
build/arm64/moonhead-arm64.iso
```

To build a directly bootable disk image instead:

```bash
make image \
  SSH_PUBKEY_FILE="$HOME/.ssh/id_ed25519.pub" \
  UPDATE_PUBLIC_KEY_FILE=/secure/moonhead-update-public.pem
```

Other generated formats are available through `make vmdk` and `make ova`.
All generated artifacts remain below `build/`; `make clean` removes them.

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

Connect with the SSH private key matching the public key supplied at build
time:

```bash
ssh -p 2222 -i ~/.ssh/id_ed25519 admin@localhost
```

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
  SSH_PUBKEY_FILE="$HOME/.ssh/id_ed25519.pub" \
  UPDATE_PUBLIC_KEY_FILE=/secure/moonhead-update-public.pem \
  UPDATE_SIGNING_KEY=/secure/moonhead-update-private.pem \
  UPDATE_VERSION=0.2.0
```

Apply the generated `build/arm64/update/` bundle on the appliance:

```bash
sudo moonhead-update /path/to/update
sudo reboot
```

## Repository layout

```text
Makefile            Build entry points
moonhead-ebpf/       Kernel-side programs
moonhead-init/       Rust PID 1 and service tools
kernel/fragments/   Kernel configuration
profiles/           Root filesystem package list
scripts/            Rootfs, image, ISO, installer, and update scripts
```
