ARCH        ?= arm64
SUITE       ?= resolute
MIRROR      ?= http://ports.ubuntu.com/ubuntu-ports
KERNEL_VER  ?= 7.3.4
KERNEL_URL  := https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-$(KERNEL_VER).tar.xz
KERNEL_DIR  ?= ./kernel/linux-7.3
BUILD_DIR   ?= ./build/$(ARCH)
JOBS        ?= $(shell nproc)
DATA_SIZE_MB ?= 7680

KVM_FLAGS   := $(if $(wildcard /dev/kvm),-cpu host -accel kvm,-cpu max -accel tcg)

ifeq ($(ARCH),amd64)
  MIRROR    := http://archive.ubuntu.com/ubuntu
  BPF_ARCH  := x86
  QEMU_BIN  := qemu-system-x86_64
  QEMU_ARGS := -M q35 $(KVM_FLAGS) -kernel $(KERNEL_DIR)/arch/x86/boot/bzImage \
               -append "root=/dev/vda rootfstype=erofs ro init=/sbin/coreos-pid1 lsm=landlock,yama,bpf console=ttyS0"
else
  BPF_ARCH  := arm64
  QEMU_BIN  := qemu-system-aarch64
  QEMU_ARGS := -M virt $(KVM_FLAGS) -kernel $(KERNEL_DIR)/arch/arm64/boot/Image \
               -append "root=/dev/vda rootfstype=erofs ro init=/sbin/coreos-pid1 lsm=landlock,yama,bpf console=ttyAMA0"
endif

.PHONY: all deps fetch-kernel ebpf pid1 kernel rootfs run-qemu clean

all: ebpf pid1 rootfs

deps:
	sudo apt-get update && sudo apt-get install -y \
	  mmdebstrap erofs-utils cryptsetup-bin qemu-system-arm qemu-user qemu-user-binfmt \
	  build-essential bc bison flex libssl-dev libelf-dev dwarves cpio zstd \
	  debhelper rsync kmod curl xz-utils clang llvm libbpf-dev bpftool
	command -v cargo-deb >/dev/null 2>&1 || cargo install cargo-deb --locked

fetch-kernel:
	@if [ ! -f "$(KERNEL_DIR)/Makefile" ]; then \
	  echo "[fetch-kernel] Downloading Linux $(KERNEL_VER)..."; \
	  mkdir -p $(KERNEL_DIR); \
	  curl -fL $(KERNEL_URL) | tar -xJ --strip-components=1 -C $(KERNEL_DIR); \
	fi

# Compile CO-RE BPF LSM io_uring gatekeeper against the exact Linux 7.3 vmlinux BTF
ebpf:
	mkdir -p $(BUILD_DIR)/ebpf
	bpftool btf dump file $(KERNEL_DIR)/vmlinux format c > $(BUILD_DIR)/ebpf/vmlinux.h
	clang -O2 -g -target bpf -D__TARGET_ARCH_$(BPF_ARCH) \
	  -I$(BUILD_DIR)/ebpf -c ./coreos-ebpf/io_uring_lsm.bpf.c \
	  -o $(BUILD_DIR)/ebpf/io_uring_lsm.bpf.o

pid1: ebpf
	mkdir -p $(BUILD_DIR)/debs
	cd coreos-pid1 && cargo deb --output ../$(BUILD_DIR)/debs/

kernel: fetch-kernel
	$(MAKE) -C $(KERNEL_DIR) ARCH=$(ARCH) defconfig
	$(KERNEL_DIR)/scripts/kconfig/merge_config.sh -m -O $(KERNEL_DIR) \
	  $(KERNEL_DIR)/.config ./kernel/fragments/coreos-7.3.config
	$(MAKE) -C $(KERNEL_DIR) ARCH=$(ARCH) olddefconfig
	$(MAKE) -C $(KERNEL_DIR) ARCH=$(ARCH) -j$(JOBS)

rootfs: pid1
	sudo ARCH=$(ARCH) SUITE=$(SUITE) MIRROR=$(MIRROR) BUILD_DIR=$(BUILD_DIR) \
	  ./scripts/build-image.sh

run-qemu:
	$(QEMU_BIN) $(QEMU_ARGS) -m 2G -smp 4 -nographic \
	  -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
	  -drive file=$(BUILD_DIR)/rootfs.erofs,format=raw,if=virtio,readonly=on

clean:
	rm -rf ./build


image: rootfs
	chmod +x ./scripts/build-disk-img.sh
	ARCH=$(ARCH) KERNEL_DIR=$(KERNEL_DIR) BUILD_DIR=$(BUILD_DIR) DATA_SIZE_MB=$(DATA_SIZE_MB) \
	  ./scripts/build-disk-img.sh

vmdk: image
	qemu-img convert -O vmdk $(BUILD_DIR)/coreos-$(ARCH).img $(BUILD_DIR)/coreos-$(ARCH).vmdk
	@echo "Built VMware disk image: $(BUILD_DIR)/coreos-$(ARCH).vmdk"

iso: rootfs
	chmod +x ./scripts/build-iso.sh
	ARCH=$(ARCH) KERNEL_DIR=$(KERNEL_DIR) BUILD_DIR=$(BUILD_DIR) ./scripts/build-iso.sh

ova: image
	mkdir -p $(BUILD_DIR)/ova-stage
	qemu-img convert -O vmdk -o subformat=streamOptimized \
	  $(BUILD_DIR)/coreos-$(ARCH).img $(BUILD_DIR)/ova-stage/coreos-$(ARCH).vmdk
	@DISK_BYTES=$$(stat -c%s $(BUILD_DIR)/coreos-$(ARCH).img); \
	VMDK_BYTES=$$(stat -c%s $(BUILD_DIR)/ova-stage/coreos-$(ARCH).vmdk); \
	printf '<?xml version="1.0" encoding="UTF-8"?>\n\
<Envelope xmlns="http://schemas.dmtf.org/ovf/envelope/1" xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1" xmlns:rasd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData" xmlns:vssd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData" xmlns:vmw="http://www.vmware.com/schema/ovf">\n\
  <References><File ovf:id="file1" ovf:href="coreos-$(ARCH).vmdk" ovf:size="%s"/></References>\n\
  <DiskSection><Info>Virtual disk</Info><Disk ovf:diskId="vmdisk1" ovf:fileRef="file1" ovf:capacity="%s" ovf:capacityAllocationUnits="byte" ovf:format="http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized"/></DiskSection>\n\
  <NetworkSection><Info>Logical networks</Info><Network ovf:name="NAT"><Description>NAT network</Description></Network></NetworkSection>\n\
  <VirtualSystem ovf:id="CORE-OS-7.3">\n\
    <Info>CORE-OS 7.3 LTS</Info>\n\
    <Name>CORE-OS 7.3 LTS</Name>\n\
    <OperatingSystemSection ovf:id="101"><Info>Linux</Info></OperatingSystemSection>\n\
    <VirtualHardwareSection>\n\
      <Info>Virtual hardware</Info>\n\
      <System><vssd:ElementName>Virtual Hardware Family</vssd:ElementName><vssd:InstanceID>0</vssd:InstanceID><vssd:VirtualSystemIdentifier>CORE-OS</vssd:VirtualSystemIdentifier><vssd:VirtualSystemType>vmx-19</vssd:VirtualSystemType></System>\n\
      <Item><rasd:AllocationUnits>hertz * 10^6</rasd:AllocationUnits><rasd:Description>Number of Virtual CPUs</rasd:Description><rasd:ElementName>4 virtual CPU(s)</rasd:ElementName><rasd:InstanceID>1</rasd:InstanceID><rasd:ResourceType>3</rasd:ResourceType><rasd:VirtualQuantity>4</rasd:VirtualQuantity></Item>\n\
      <Item><rasd:AllocationUnits>byte * 2^20</rasd:AllocationUnits><rasd:Description>Memory Size</rasd:Description><rasd:ElementName>2048MB of memory</rasd:ElementName><rasd:InstanceID>2</rasd:InstanceID><rasd:ResourceType>4</rasd:ResourceType><rasd:VirtualQuantity>2048</rasd:VirtualQuantity></Item>\n\
      <Item><rasd:Address>0</rasd:Address><rasd:Description>SCSI Controller</rasd:Description><rasd:ElementName>SCSI Controller 0</rasd:ElementName><rasd:InstanceID>3</rasd:InstanceID><rasd:ResourceSubType>lsilogicsas</rasd:ResourceSubType><rasd:ResourceType>6</rasd:ResourceType></Item>\n\
      <Item><rasd:AddressOnParent>0</rasd:AddressOnParent><rasd:ElementName>Hard Disk 1</rasd:ElementName><rasd:HostResource>ovf:/disk/vmdisk1</rasd:HostResource><rasd:InstanceID>4</rasd:InstanceID><rasd:Parent>3</rasd:Parent><rasd:ResourceType>17</rasd:ResourceType></Item>\n\
      <Item><rasd:AddressOnParent>0</rasd:AddressOnParent><rasd:AutomaticAllocation>true</rasd:AutomaticAllocation><rasd:Connection>NAT</rasd:Connection><rasd:ElementName>Ethernet 0</rasd:ElementName><rasd:InstanceID>5</rasd:InstanceID><rasd:ResourceSubType>E1000e</rasd:ResourceSubType><rasd:ResourceType>10</rasd:ResourceType></Item>\n\
      <vmw:Config ovf:required="false" vmw:key="firmware" vmw:value="efi"/>\n\
    </VirtualHardwareSection>\n\
  </VirtualSystem>\n\
</Envelope>\n' "$$VMDK_BYTES" "$$DISK_BYTES" > $(BUILD_DIR)/ova-stage/coreos-$(ARCH).ovf
	tar -cf $(BUILD_DIR)/coreos-$(ARCH).ova -C $(BUILD_DIR)/ova-stage coreos-$(ARCH).ovf coreos-$(ARCH).vmdk
	@echo "Built single-click VMware appliance: $(BUILD_DIR)/coreos-$(ARCH).ova"
