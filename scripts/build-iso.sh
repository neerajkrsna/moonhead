#!/usr/bin/env bash
set -euo pipefail

ARCH="${ARCH:-arm64}"
KERNEL_DIR="${KERNEL_DIR:-./kernel/linux-7.3}"
BUILD_DIR="${BUILD_DIR:-./build/${ARCH}}"
ROOTFS_EROFS="${BUILD_DIR}/rootfs.erofs"
OUT_ISO="${BUILD_DIR}/coreos-${ARCH}.iso"
ISO_STAGE="${BUILD_DIR}/iso-stage"
INITRD_DIR="${BUILD_DIR}/iso-initrd"

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

# 1. Build minimal initramfs to mount ISO -> erofs + tmpfs overlay -> switch_root
rm -rf "${ISO_STAGE}" "${INITRD_DIR}"
mkdir -p "${ISO_STAGE}/EFI/BOOT" "${ISO_STAGE}/live" "${INITRD_DIR}"/{bin,dev,proc,sys,mnt/iso,mnt/ro,mnt/rw,newroot}

cp /bin/busybox "${INITRD_DIR}/bin/busybox"
for cmd in sh mount umount mkdir sleep switch_root losetup; do
  ln -sf busybox "${INITRD_DIR}/bin/${cmd}"
done

cat <<'EOF' > "${INITRD_DIR}/init"
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

for _ in $(seq 1 30); do
  for dev in /dev/sr* /dev/vd* /dev/sd* /dev/nvme*p*; do
    [ -b "$dev" ] || continue
    if mount -t iso9660 -o ro "$dev" /mnt/iso 2>/dev/null; then
      if [ -f /mnt/iso/live/rootfs.erofs ]; then
        mount -t erofs -o ro,loop /mnt/iso/live/rootfs.erofs /mnt/ro
        mount -t tmpfs -o mode=0755 tmpfs /mnt/rw
        mkdir -p /mnt/rw/upper /mnt/rw/work
        mount -t overlay overlay -o lowerdir=/mnt/ro,upperdir=/mnt/rw/upper,workdir=/mnt/rw/work /newroot
        exec switch_root /newroot /sbin/coreos-pid1
      fi
      umount /mnt/iso
    fi
  done
  sleep 0.2
done
exec /bin/sh
EOF
chmod +x "${INITRD_DIR}/init"

ABS_ISO_STAGE="$(realpath "${ISO_STAGE}")"
(cd "${INITRD_DIR}" && find . -print0 | cpio --null -ov --format=newc 2>/dev/null | gzip -9 > "${ABS_ISO_STAGE}/live/initrd.img")
cp "${KERNEL_IMG}" "${ISO_STAGE}/live/vmlinuz"
cp "${ROOTFS_EROFS}" "${ISO_STAGE}/live/rootfs.erofs"

# 2. Build standalone disk GRUB EFI binary (used by coreos-install)
cat <<EOF > "${ISO_STAGE}/disk-grub.cfg"
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
  --output="${ISO_STAGE}/live/disk-boot.efi" \
  "boot/grub/grub.cfg=${ISO_STAGE}/disk-grub.cfg"

# 3. Build Live ISO GRUB EFI binary + El Torito image
cat <<EOF > "${ISO_STAGE}/grub.cfg"
set timeout=1
set default=0
insmod iso9660
insmod part_gpt
insmod fat
search --no-floppy --file --set=root /live/vmlinuz

menuentry "CORE-OS 7.3 LTS (Live / Installer)" {
    linux /live/vmlinuz lsm=landlock,yama,bpf ${CONSOLE_ARG}
    initrd /live/initrd.img
}
EOF

grub-mkstandalone \
  --format="${GRUB_FMT}" \
  --output="${ISO_STAGE}/EFI/BOOT/${EFI_BOOT_NAME}" \
  "boot/grub/grub.cfg=${ISO_STAGE}/grub.cfg"

truncate -s 16M "${ISO_STAGE}/efiboot.img"
mkfs.vfat -F 12 "${ISO_STAGE}/efiboot.img" >/dev/null
mmd -i "${ISO_STAGE}/efiboot.img" ::/EFI ::/EFI/BOOT
mcopy -i "${ISO_STAGE}/efiboot.img" "${ISO_STAGE}/EFI/BOOT/${EFI_BOOT_NAME}" "::/EFI/BOOT/${EFI_BOOT_NAME}"

# 4. Pack hybrid UEFI ISO-9660 image
xorriso -as mkisofs \
  -o "${OUT_ISO}" \
  -V "COREOS_ISO" \
  -J -R \
  -e efiboot.img \
  -no-emul-boot \
  -append_partition 2 0xef "${ISO_STAGE}/efiboot.img" \
  "${ISO_STAGE}"

echo "Built bootable UEFI Live/Installer ISO: ${OUT_ISO} ($(du -h "${OUT_ISO}" | cut -f1))"
