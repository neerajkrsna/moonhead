ARCH        ?= arm64
SUITE       ?= resolute
MIRROR      ?= http://ports.ubuntu.com/ubuntu-ports
KERNEL_VER  ?= 7.3.4
KERNEL_URL  := https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-$(KERNEL_VER).tar.xz
KERNEL_DIR  ?= ./kernel/linux-7.3
BUILD_DIR   ?= ./build/$(ARCH)
KERNEL_UPDATE_IMAGE ?=
JOBS        ?= $(shell nproc)
DATA_SIZE_MB ?= 7680
SSH_PUBKEY_FILE ?=
UPDATE_PUBLIC_KEY_FILE ?=
SECURE_BOOT ?= 0
SECURE_BOOT_KEY ?=
SECURE_BOOT_CERT ?=

KVM_FLAGS   := $(if $(wildcard /dev/kvm),-cpu host -accel kvm,-cpu max -accel tcg)

ifeq ($(ARCH),amd64)
  MIRROR    := http://archive.ubuntu.com/ubuntu
  BPF_ARCH  := x86
  QEMU_BIN  := qemu-system-x86_64
  KERNEL_IMAGE := $(KERNEL_DIR)/arch/x86/boot/bzImage
  QEMU_ARGS := -M q35 $(KVM_FLAGS) -kernel $(KERNEL_DIR)/arch/x86/boot/bzImage \
               -append "root=/dev/vda rootfstype=erofs ro init=/sbin/moonhead-init lsm=landlock,yama,bpf console=ttyS0"
else
  BPF_ARCH  := arm64
  QEMU_BIN  := qemu-system-aarch64
  KERNEL_IMAGE := $(KERNEL_DIR)/arch/arm64/boot/Image
  QEMU_ARGS := -M virt $(KVM_FLAGS) -kernel $(KERNEL_DIR)/arch/arm64/boot/Image \
               -append "root=/dev/vda rootfstype=erofs ro init=/sbin/moonhead-init lsm=landlock,yama,bpf console=ttyAMA0"
endif

.PHONY: all deps fetch-kernel ebpf pid1 kernel rootfs run-qemu clean image vmdk iso ova production-iso production-update signed-update qualify-arm64 qualify-arm64-iso

all: ebpf pid1 rootfs

deps:
	sudo apt-get update && sudo apt-get install -y \
	  mmdebstrap erofs-utils cryptsetup-bin qemu-system-arm qemu-user qemu-user-binfmt \
	  build-essential bc bison flex libssl-dev libelf-dev dwarves cpio zstd \
	  debhelper rsync kmod curl xz-utils clang llvm libbpf-dev bpftool \
	  sbsigntool grub-efi-arm64-bin grub-efi-amd64-bin grub-common \
	  dosfstools mtools gdisk e2fsprogs xorriso busybox-static qemu-utils openssl sshpass
	command -v cargo-deb >/dev/null 2>&1 || cargo install cargo-deb --locked

fetch-kernel:
	@if [ ! -f "$(KERNEL_DIR)/Makefile" ]; then \
	  echo "[fetch-kernel] Downloading Linux $(KERNEL_VER)..."; \
	  mkdir -p $(KERNEL_DIR); \
	  curl -fL $(KERNEL_URL) | tar -xJ --strip-components=1 -C $(KERNEL_DIR); \
	fi

# Compile CO-RE BPF programs against the exact Linux 7.3 vmlinux BTF.
ebpf:
	mkdir -p $(BUILD_DIR)/ebpf
	rm -f $(BUILD_DIR)/ebpf/io_uring_lsm.bpf.o \
	  $(BUILD_DIR)/ebpf/scx_moonhead.bpf.o $(BUILD_DIR)/ebpf/xdp_fastpath.bpf.o
	bpftool btf dump file $(KERNEL_DIR)/vmlinux format c >$(BUILD_DIR)/ebpf/vmlinux.h
	clang -O2 -g -Wno-missing-declarations -target bpf -D__TARGET_ARCH_$(BPF_ARCH) \
	  -I$(BUILD_DIR)/ebpf -c ./moonhead-ebpf/io_uring_lsm.bpf.c \
	  -o $(BUILD_DIR)/ebpf/io_uring_lsm-$(ARCH).bpf.o
	clang -O2 -g -Wno-missing-declarations -target bpf -D__TARGET_ARCH_$(BPF_ARCH) \
	  -I$(BUILD_DIR)/ebpf -c ./moonhead-ebpf/scx_moonhead.bpf.c \
	  -o $(BUILD_DIR)/ebpf/scx_moonhead-$(ARCH).bpf.o
	clang -O2 -g -Wno-missing-declarations -target bpf -D__TARGET_ARCH_$(BPF_ARCH) \
	  -I$(BUILD_DIR)/ebpf -c ./moonhead-ebpf/xdp_fastpath.bpf.c \
	  -o $(BUILD_DIR)/ebpf/xdp_fastpath-$(ARCH).bpf.o


pid1: ebpf
	mkdir -p $(BUILD_DIR)/debs
	rm -rf ./build/package-assets
	mkdir -p ./build/package-assets/ebpf
	cp $(BUILD_DIR)/ebpf/io_uring_lsm-$(ARCH).bpf.o \
	  ./build/package-assets/ebpf/io_uring_lsm.bpf.o
	cp $(BUILD_DIR)/ebpf/scx_moonhead-$(ARCH).bpf.o \
	  ./build/package-assets/ebpf/scx_moonhead.bpf.o
	cp $(BUILD_DIR)/ebpf/xdp_fastpath-$(ARCH).bpf.o \
	  ./build/package-assets/ebpf/xdp_fastpath.bpf.o
	cd moonhead-init && cargo deb --output ../$(BUILD_DIR)/debs/

kernel: fetch-kernel
	$(MAKE) -C $(KERNEL_DIR) ARCH=$(ARCH) defconfig
	$(KERNEL_DIR)/scripts/kconfig/merge_config.sh -m -O $(KERNEL_DIR) \
	  $(KERNEL_DIR)/.config ./kernel/fragments/moonhead-7.3.config
	$(MAKE) -C $(KERNEL_DIR) ARCH=$(ARCH) olddefconfig
	$(MAKE) -C $(KERNEL_DIR) ARCH=$(ARCH) -j$(JOBS)

rootfs: pid1
	@test -z "$(SSH_PUBKEY_FILE)" || test -f "$(SSH_PUBKEY_FILE)" || { echo "ERROR: SSH_PUBKEY_FILE does not exist: $(SSH_PUBKEY_FILE)" >&2; exit 1; }
	sudo ARCH=$(ARCH) SUITE=$(SUITE) MIRROR=$(MIRROR) BUILD_DIR=$(BUILD_DIR) \
	  SSH_PUBKEY_FILE="$(abspath $(SSH_PUBKEY_FILE))" \
	  UPDATE_PUBLIC_KEY_FILE="$(if $(UPDATE_PUBLIC_KEY_FILE),$(abspath $(UPDATE_PUBLIC_KEY_FILE)),)" \
	  ADMIN_PASSWORD="$(ADMIN_PASSWORD)" \
	  ./scripts/build-image.sh

run-qemu:
	$(QEMU_BIN) $(QEMU_ARGS) -m 2G -smp 4 -nographic \
	  -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
	  -drive file=$(BUILD_DIR)/rootfs-$(ARCH).erofs,format=raw,if=virtio,readonly=on

clean:
	rm -rf ./build

qualify-arm64:
	@test "$(ARCH)" = "arm64" || { echo "ERROR: qualify-arm64 requires ARCH=arm64" >&2; exit 1; }
	@test -n "$(ADMIN_PASSWORD)" || { echo "ERROR: ADMIN_PASSWORD is required" >&2; exit 1; }
	@test -f "$(BUILD_DIR)/moonhead-arm64.img" || { echo "ERROR: build image first with 'make image'" >&2; exit 1; }
	@test -d "$(BUILD_DIR)/update" || { echo "ERROR: build signed update with 'make signed-update'" >&2; exit 1; }
	ADMIN_PASSWORD="$(ADMIN_PASSWORD)" ./tests/qualify-arm64-image.sh \
	  "$(BUILD_DIR)/moonhead-arm64.img" "$(BUILD_DIR)/update"

qualify-arm64-iso:
	@test "$(ARCH)" = "arm64" || { echo "ERROR: qualify-arm64-iso requires ARCH=arm64" >&2; exit 1; }
	@test -n "$(ADMIN_PASSWORD)" || { echo "ERROR: ADMIN_PASSWORD is required" >&2; exit 1; }
	@test -f "$(BUILD_DIR)/moonhead-arm64.iso" || { echo "ERROR: build installer with 'make iso'" >&2; exit 1; }
	ADMIN_PASSWORD="$(ADMIN_PASSWORD)" ./tests/qualify-arm64-iso.sh \
	  "$(BUILD_DIR)/moonhead-arm64.iso"


image: rootfs
	chmod +x ./scripts/build-disk-img.sh
	ARCH=$(ARCH) KERNEL_DIR=$(KERNEL_DIR) BUILD_DIR=$(BUILD_DIR) DATA_SIZE_MB=$(DATA_SIZE_MB) \
	  SECURE_BOOT="$(SECURE_BOOT)" SECURE_BOOT_KEY="$(SECURE_BOOT_KEY)" SECURE_BOOT_CERT="$(SECURE_BOOT_CERT)" \
	  ./scripts/build-disk-img.sh

vmdk: image
	qemu-img convert -O vmdk $(BUILD_DIR)/moonhead-$(ARCH).img $(BUILD_DIR)/moonhead-$(ARCH).vmdk
	@echo "Built VMware disk image: $(BUILD_DIR)/moonhead-$(ARCH).vmdk"

iso: rootfs
	chmod +x ./scripts/build-iso.sh
	ARCH=$(ARCH) KERNEL_DIR=$(KERNEL_DIR) BUILD_DIR=$(BUILD_DIR) \
	  SECURE_BOOT="$(SECURE_BOOT)" SECURE_BOOT_KEY="$(SECURE_BOOT_KEY)" SECURE_BOOT_CERT="$(SECURE_BOOT_CERT)" \
	  ./scripts/build-iso.sh

production-iso:
	@test -n "$(UPDATE_PUBLIC_KEY_FILE)" || { echo "ERROR: UPDATE_PUBLIC_KEY_FILE is required" >&2; exit 1; }
	@test -f "$(UPDATE_PUBLIC_KEY_FILE)" || { echo "ERROR: update public key does not exist" >&2; exit 1; }
	@test -n "$(SECURE_BOOT_KEY)" || { echo "ERROR: SECURE_BOOT_KEY is required" >&2; exit 1; }
	@test -f "$(SECURE_BOOT_KEY)" || { echo "ERROR: secure-boot signing key does not exist" >&2; exit 1; }
	@test -n "$(SECURE_BOOT_CERT)" || { echo "ERROR: SECURE_BOOT_CERT is required" >&2; exit 1; }
	@test -f "$(SECURE_BOOT_CERT)" || { echo "ERROR: secure-boot certificate does not exist" >&2; exit 1; }
	$(MAKE) iso SSH_PUBKEY_FILE="$(SSH_PUBKEY_FILE)" \
	  UPDATE_PUBLIC_KEY_FILE="$(UPDATE_PUBLIC_KEY_FILE)" \
	  SECURE_BOOT=1 SECURE_BOOT_KEY="$(SECURE_BOOT_KEY)" \
	  SECURE_BOOT_CERT="$(SECURE_BOOT_CERT)"

signed-update: rootfs kernel
	@test -n "$(UPDATE_SIGNING_KEY)" || { echo "ERROR: UPDATE_SIGNING_KEY is required" >&2; exit 1; }
	@test -n "$(UPDATE_VERSION)" || { echo "ERROR: UPDATE_VERSION is required" >&2; exit 1; }
	UPDATE_SIGNING_KEY="$(UPDATE_SIGNING_KEY)" ARCH="$(ARCH)" \
	  KERNEL_IMAGE="$(if $(KERNEL_UPDATE_IMAGE),$(KERNEL_UPDATE_IMAGE),$(KERNEL_IMAGE))" \
	  ROOTFS_IMAGE="$(BUILD_DIR)/rootfs-$(ARCH).erofs" \
	  ./scripts/create-update.sh "$(UPDATE_VERSION)" "$(BUILD_DIR)/update"

production-update: production-iso
	@test -n "$(UPDATE_SIGNING_KEY)" || { echo "ERROR: UPDATE_SIGNING_KEY is required" >&2; exit 1; }
	@test -f "$(UPDATE_SIGNING_KEY)" || { echo "ERROR: update signing key does not exist" >&2; exit 1; }
	@test -n "$(UPDATE_VERSION)" || { echo "ERROR: UPDATE_VERSION is required" >&2; exit 1; }
	$(MAKE) signed-update \
	  SSH_PUBKEY_FILE="$(SSH_PUBKEY_FILE)" \
	  UPDATE_PUBLIC_KEY_FILE="$(UPDATE_PUBLIC_KEY_FILE)" \
	  KERNEL_UPDATE_IMAGE="$(BUILD_DIR)/iso-stage/live/vmlinuz-$(ARCH)" \
	  UPDATE_SIGNING_KEY="$(UPDATE_SIGNING_KEY)" \
	  UPDATE_VERSION="$(UPDATE_VERSION)"

ova: image
	mkdir -p $(BUILD_DIR)/ova-stage
	qemu-img convert -O vmdk -o subformat=streamOptimized \
	  $(BUILD_DIR)/moonhead-$(ARCH).img $(BUILD_DIR)/ova-stage/moonhead-$(ARCH).vmdk
	@DISK_BYTES=$$(stat -c%s $(BUILD_DIR)/moonhead-$(ARCH).img); \
	VMDK_BYTES=$$(stat -c%s $(BUILD_DIR)/ova-stage/moonhead-$(ARCH).vmdk); \
	printf '<?xml version="1.0" encoding="UTF-8"?>\n\
<Envelope xmlns="http://schemas.dmtf.org/ovf/envelope/1" xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1" xmlns:rasd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData" xmlns:vssd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData" xmlns:vmw="http://www.vmware.com/schema/ovf">\n\
  <References><File ovf:id="file1" ovf:href="moonhead-$(ARCH).vmdk" ovf:size="%s"/></References>\n\
  <DiskSection><Info>Virtual disk</Info><Disk ovf:diskId="vmdisk1" ovf:fileRef="file1" ovf:capacity="%s" ovf:capacityAllocationUnits="byte" ovf:format="http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized"/></DiskSection>\n\
  <NetworkSection><Info>Logical networks</Info><Network ovf:name="NAT"><Description>NAT network</Description></Network></NetworkSection>\n\
  <VirtualSystem ovf:id="Moonhead OS-7.3">\n\
    <Info>Moonhead OS 7.3</Info>\n\
    <Name>Moonhead OS 7.3</Name>\n\
    <OperatingSystemSection ovf:id="101"><Info>Linux</Info></OperatingSystemSection>\n\
    <VirtualHardwareSection>\n\
      <Info>Virtual hardware</Info>\n\
      <System><vssd:ElementName>Virtual Hardware Family</vssd:ElementName><vssd:InstanceID>0</vssd:InstanceID><vssd:VirtualSystemIdentifier>Moonhead OS</vssd:VirtualSystemIdentifier><vssd:VirtualSystemType>vmx-19</vssd:VirtualSystemType></System>\n\
      <Item><rasd:AllocationUnits>hertz * 10^6</rasd:AllocationUnits><rasd:Description>Number of Virtual CPUs</rasd:Description><rasd:ElementName>4 virtual CPU(s)</rasd:ElementName><rasd:InstanceID>1</rasd:InstanceID><rasd:ResourceType>3</rasd:ResourceType><rasd:VirtualQuantity>4</rasd:VirtualQuantity></Item>\n\
      <Item><rasd:AllocationUnits>byte * 2^20</rasd:AllocationUnits><rasd:Description>Memory Size</rasd:Description><rasd:ElementName>2048MB of memory</rasd:ElementName><rasd:InstanceID>2</rasd:InstanceID><rasd:ResourceType>4</rasd:ResourceType><rasd:VirtualQuantity>2048</rasd:VirtualQuantity></Item>\n\
      <Item><rasd:Address>0</rasd:Address><rasd:Description>SCSI Controller</rasd:Description><rasd:ElementName>SCSI Controller 0</rasd:ElementName><rasd:InstanceID>3</rasd:InstanceID><rasd:ResourceSubType>lsilogicsas</rasd:ResourceSubType><rasd:ResourceType>6</rasd:ResourceType></Item>\n\
      <Item><rasd:AddressOnParent>0</rasd:AddressOnParent><rasd:ElementName>Hard Disk 1</rasd:ElementName><rasd:HostResource>ovf:/disk/vmdisk1</rasd:HostResource><rasd:InstanceID>4</rasd:InstanceID><rasd:Parent>3</rasd:Parent><rasd:ResourceType>17</rasd:ResourceType></Item>\n\
      <Item><rasd:AddressOnParent>0</rasd:AddressOnParent><rasd:AutomaticAllocation>true</rasd:AutomaticAllocation><rasd:Connection>NAT</rasd:Connection><rasd:ElementName>Ethernet 0</rasd:ElementName><rasd:InstanceID>5</rasd:InstanceID><rasd:ResourceSubType>E1000e</rasd:ResourceSubType><rasd:ResourceType>10</rasd:ResourceType></Item>\n\
      <vmw:Config ovf:required="false" vmw:key="firmware" vmw:value="efi"/>\n\
    </VirtualHardwareSection>\n\
  </VirtualSystem>\n\
</Envelope>\n' "$$VMDK_BYTES" "$$DISK_BYTES" > $(BUILD_DIR)/ova-stage/moonhead-$(ARCH).ovf
	tar -cf $(BUILD_DIR)/moonhead-$(ARCH).ova -C $(BUILD_DIR)/ova-stage moonhead-$(ARCH).ovf moonhead-$(ARCH).vmdk
	@echo "Built single-click VMware appliance: $(BUILD_DIR)/moonhead-$(ARCH).ova"
