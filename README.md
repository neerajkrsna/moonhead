# CORE-OS

The current prototype builds an ARM64 Ubuntu-based root filesystem with a
custom Rust PID 1 and Linux 7.3.4. The project was built and boot-tested in an
Ubuntu VM. This is experimental software, not a production-ready OS: its
image configuration enables password SSH access, configures passwordless
sudo for the administrator, and removes the root password. Do not expose it
to untrusted networks or use it for sensitive workloads.

Linux 7.3 is a stable kernel branch, not an upstream LTS branch. The kernel
source, compiled binaries, disk images, ISOs, VMDKs, and OVAs are not committed.

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

## Previous Yocto reference (paused)

The earlier prototype was a minimal Yocto reference image for
`qemux86-64`, built from pinned Yocto Project 6.0.4 (Wrynose) metadata. It
inherits the Poky reference distribution and its existing init; **Rust PID 1
is not integrated into that image**. The following instructions apply to that
paused reference build, not the current prototype.

## Build host

Build on a supported Linux host or Linux VM. Yocto does not build natively on
macOS. Follow the [Wrynose host requirements and package instructions](https://docs.yoctoproject.org/6.0/brief-yoctoprojectqs/index.html):
the reference guidance specifies at least 140 GB free disk, 32 GB RAM, and
16 CPU cores for faster builds. An ARM64 Linux VM on Apple Silicon can
cross-compile the x86-64 image; QEMU will emulate x86-64 for the boot test.
Fewer CPU cores make builds slower. Builds require network access.

## Get pinned sources

From the repository root on the Linux build host:

```sh
mkdir -p sources
git clone --branch yocto-6.0.4 https://git.openembedded.org/bitbake sources/bitbake
git clone --branch yocto-6.0.4 https://git.openembedded.org/openembedded-core sources/openembedded-core
git clone --branch yocto-6.0.4 https://git.yoctoproject.org/meta-yocto sources/meta-yocto
```

Verify the checked-out commits before building:

```sh
git -C sources/bitbake rev-parse HEAD
# 51fd94a67fa17650a9ff623492005972bbc7d26f
git -C sources/openembedded-core rev-parse HEAD
# 0f03c732a0a2d0506b41b1abe60b3f368b2300dc
git -C sources/meta-yocto rev-parse HEAD
# 7c25b11156553145fa6b241a2d4f65d94438f804
```

These are release snapshots, not automatic security updates. Record and review
updates to all three repositories together; review kernel and userspace CVEs
before any pilot.

## Configure and build

Use Bash from the repository root:

```sh
export TEMPLATECONF="$PWD/meta-coreos/conf/templates/default"
source sources/openembedded-core/oe-init-build-env build
bitbake-layers show-layers
bitbake -e coreos-image-prototype | grep -E '^(MACHINE|DISTRO|DEFAULTTUNE|PACKAGE_CLASSES|PREFERRED_VERSION_linux-yocto)='
bitbake coreos-image-prototype
```

`oe-init-build-env` changes the shell's working directory to `build/`. The
template applies when the build directory is first created; it does not
overwrite an existing configuration. The explicit `x86-64` tune avoids
Wrynose's `qemux86-64` default of `x86-64-v3`. The `.deb` setting selects
Yocto's package format; it does not provide Ubuntu package compatibility.

The pinned reference distro selects the `linux-yocto` 6.18 branch, which is an
upstream long-term branch. Its recipe contains Yocto-specific kernel metadata
and patches, so it is not claimed to be an unmodified upstream kernel. The
exact recipe revision is a baseline to audit and update, not a declaration
that all desired kernel features are present.

## Boot and inspect

After a successful build, from the initialized build shell:

```sh
runqemu qemux86-64 coreos-image-prototype nographic slirp
```

Record whether the kernel boots and reaches the login prompt; exit QEMU with
Ctrl-A followed by X. Repeat the boot and record the hardware/VM and image
details. The default image does not enable an empty root password, so a login
prompt is not a promise of interactive root access.

The deployed image manifest is under `tmp/deploy/images/qemux86-64/` and ends
in `.manifest`; inspect it for the actual installed packages. Also record
the selected kernel recipe/version and build configuration. Before advancing
to Rust PID 1, establish a reproducible build and repeated boot on the Linux
host, then define and test the init service and shutdown contract.

Sources and build artifacts are ignored by Git. The reference baseline has not
yet been built or booted on a Linux host.
