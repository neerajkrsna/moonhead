# CORE-OS prototype

This is the first roadmap increment: a minimal Yocto reference image for
`qemux86-64`, built from pinned Yocto Project 6.0.4 (Wrynose) metadata. It
inherits the Poky reference distribution and its existing init; **Rust PID 1
is not implemented or integrated yet**. This image is for establishing a
baseline, not production use.

## Build host

Build on a supported Linux host or Linux VM. Yocto does not build natively on
macOS. Follow the [Wrynose host requirements and package instructions](https://docs.yoctoproject.org/6.0/brief-yoctoprojectqs/index.html):
the reference guidance specifies at least 140 GB free disk, 32 GB RAM, and
16 CPU cores. On an Apple Silicon Mac, an x86-64 Linux VM is the simplest
starting point for this x86-64 target. Builds require network access.

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
