#!/usr/bin/env bash
set -euo pipefail

ARCH="${ARCH:-arm64}"
KERNEL_DIR="${KERNEL_DIR:-./kernel/linux-7.3}"
BUILD_DIR="${BUILD_DIR:-./build/${ARCH}}"
ROOTFS_EROFS="${BUILD_DIR}/rootfs.erofs"
OUT_IMG="${BUILD_DIR}/coreos-${ARCH}.img"
STAGE_DIR="${BUILD_DIR}/img-stage"
DATA_SIZE_MB="${DATA_SIZE_MB:-7680}"

if [[ "${ARCH}" == "amd64" ]]; then
  KERNEL_IMG="${KERNEL_DIR}/arch/x86/boot/bzImage"
  GRUB_FMT="x86_64-efi"
  EFI_BOOT_NAME="BOOTX64.EFI"
  CONSOLE_ARG="console=tty0 console=ttyS0"
else
  KERNEL_IMG="${KERNEL_DIR}/arch/arm64/boot/Image"
  GRUB_FMT="arm64-efi"
  EFI_BOOT_NAME="BOOTAA64.EFI"
  CONSOLE_ARG="console=tty0 console=ttyAMA0"
fi

rm -rf "${STAGE_DIR}"
mkdir -p "${STAGE_DIR}/EFI/BOOT"

cat <<EOF > "${STAGE_DIR}/grub.cfg"
set timeout=1
set default=0
insmod part_gpt
insmod fat
insmod ext2
search --no-floppy --file --set=root /vmlinuz

menuentry "CORE-OS 7.3 LTS" {
    linux /vmlinuz root=PARTLABEL=COREOS_ROOT rootfstype=erofs ro rootwait init=/sbin/coreos-pid1 lsm=landlock,yama,bpf ${CONSOLE_ARG}
}
EOF

grub-mkstandalone \
  --format="${GRUB_FMT}" \
  --output="${STAGE_DIR}/EFI/BOOT/${EFI_BOOT_NAME}" \
  "boot/grub/grub.cfg=${STAGE_DIR}/grub.cfg"

# 1. Build 64 MiB FAT32 EFI System Partition
ESP_IMG="${STAGE_DIR}/esp.img"
truncate -s 64M "${ESP_IMG}"
mkfs.vfat -F 32 -n "COREOS_ESP" "${ESP_IMG}" >/dev/null
mmd -i "${ESP_IMG}" ::/EFI ::/EFI/BOOT
mcopy -i "${ESP_IMG}" "${STAGE_DIR}/EFI/BOOT/${EFI_BOOT_NAME}" "::/EFI/BOOT/${EFI_BOOT_NAME}"
mcopy -i "${ESP_IMG}" "${KERNEL_IMG}" ::/vmlinuz

# 2. Build persistent ext4 overlay partition (default 7680 MiB for ~8 GB disk)
DATA_IMG="${STAGE_DIR}/data.img"
truncate -s "${DATA_SIZE_MB}M" "${DATA_IMG}"
mkfs.ext4 -F -L "COREOS_DATA" "${DATA_IMG}" >/dev/null

# 3. Compute 1 MiB-aligned sector offsets and pack GPT disk image
ESP_START=2048
ESP_SECTORS=$((64 * 2048))
ROOT_START=$((ESP_START + ESP_SECTORS))
ROOT_BYTES=$(stat -c%s "${ROOTFS_EROFS}")
ROOT_ALIGNED=$(( (ROOT_BYTES + 1048575) / 1048576 * 1048576 ))
ROOT_SECTORS=$((ROOT_ALIGNED / 512))
DATA_START=$((ROOT_START + ROOT_SECTORS))
DATA_SECTORS=$((DATA_SIZE_MB * 2048))
TOTAL_SECTORS=$((DATA_START + DATA_SECTORS + 2048))

rm -f "${OUT_IMG}"
truncate -s $((TOTAL_SECTORS * 512)) "${OUT_IMG}"

sgdisk -Z "${OUT_IMG}" >/dev/null
sgdisk -n 1:${ESP_START}:+${ESP_SECTORS}   -t 1:EF00 -c 1:COREOS_ESP  "${OUT_IMG}" >/dev/null
sgdisk -n 2:${ROOT_START}:+${ROOT_SECTORS} -t 2:8300 -c 2:COREOS_ROOT "${OUT_IMG}" >/dev/null
sgdisk -n 3:${DATA_START}:+${DATA_SECTORS} -t 3:8300 -c 3:COREOS_DATA "${OUT_IMG}" >/dev/null

dd if="${ESP_IMG}"      of="${OUT_IMG}" bs=512 seek=${ESP_START}  conv=notrunc status=none
dd if="${ROOTFS_EROFS}" of="${OUT_IMG}" bs=512 seek=${ROOT_START} conv=notrunc status=none
dd if="${DATA_IMG}"     of="${OUT_IMG}" bs=512 seek=${DATA_START} conv=notrunc status=none

echo "Built bootable UEFI disk image: ${OUT_IMG} ($(du -h "${OUT_IMG}" | cut -f1))"
