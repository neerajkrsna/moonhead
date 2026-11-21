#!/usr/bin/env bash
set -euo pipefail

ARCH="${ARCH:-arm64}"
KERNEL_DIR="${KERNEL_DIR:-./kernel/linux-7.3}"
BUILD_DIR="${BUILD_DIR:-./build/${ARCH}}"
ROOTFS_EROFS="${BUILD_DIR}/rootfs.erofs"
OUT_ISO="${BUILD_DIR}/moonhead-${ARCH}.iso"
ISO_STAGE="${BUILD_DIR}/iso-stage"
INITRD_DIR="${BUILD_DIR}/iso-initrd"
SECURE_BOOT="${SECURE_BOOT:-0}"
ROOT_A_PARTUUID="c02e0500-0000-4000-8000-000000000002"
HASH_A_PARTUUID="c02e0500-0000-4000-8000-000000000003"
ROOT_B_PARTUUID="c02e0500-0000-4000-8000-000000000004"
HASH_B_PARTUUID="c02e0500-0000-4000-8000-000000000005"

sign_efi() {
  local file="$1"
  local signed="${file}.signed"
  if [[ "${SECURE_BOOT}" != "1" ]]; then
    return
  fi
  if [[ -z "${SECURE_BOOT_KEY:-}" || -z "${SECURE_BOOT_CERT:-}" ||
        ! -f "${SECURE_BOOT_KEY}" || ! -f "${SECURE_BOOT_CERT}" ]]; then
    echo "ERROR: SECURE_BOOT_KEY and SECURE_BOOT_CERT are required." >&2
    exit 1
  fi
  sbsign --key "${SECURE_BOOT_KEY}" --cert "${SECURE_BOOT_CERT}" \
    --output "${signed}" "${file}"
  sbverify --cert "${SECURE_BOOT_CERT}" "${signed}" >/dev/null
  mv "${signed}" "${file}"
}

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
        exec switch_root /newroot /sbin/moonhead-init
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
sign_efi "${ISO_STAGE}/live/vmlinuz"

cp "${ROOTFS_EROFS}" "${ISO_STAGE}/live/rootfs-verity.erofs"
RAW_BYTES=$(stat -c%s "${ISO_STAGE}/live/rootfs-verity.erofs")
ALIGNED_BYTES=$(( (RAW_BYTES + 4095) / 4096 * 4096 ))
truncate -s "${ALIGNED_BYTES}" "${ISO_STAGE}/live/rootfs-verity.erofs"
VERITY_OUT=$(veritysetup format --data-block-size=4096 --hash-block-size=4096 \
  "${ISO_STAGE}/live/rootfs-verity.erofs" "${ISO_STAGE}/live/rootfs.verity")
ROOT_HASH=$(printf '%s\n' "${VERITY_OUT}" | awk '/^Root hash:/ {print $3}')
SALT=$(printf '%s\n' "${VERITY_OUT}" | awk '/^Salt:/ {print $2}')
DATA_BLOCKS=$((ALIGNED_BYTES / 4096))
DATA_SECTORS=$((DATA_BLOCKS * 8))
printf 'root_hash=%s\nsalt=%s\ndata_blocks=%s\n' \
  "${ROOT_HASH}" "${SALT}" "${DATA_BLOCKS}" > "${ISO_STAGE}/live/verity.env"
if [[ "${SECURE_BOOT}" == "1" ]]; then
  openssl x509 -in "${SECURE_BOOT_CERT}" -outform DER \
    -out "${ISO_STAGE}/live/secure-boot-cert.der"
fi

# 2. Build standalone disk GRUB EFI binary (used by moonhead-install)
cat <<EOF > "${ISO_STAGE}/disk-grub.cfg"
set timeout=1
set default=0
insmod part_gpt
insmod fat
insmod ext2
search --no-floppy --file --set=root /kernel-A

menuentry "Moonhead OS 7.3 (dm-verity A/B)" {
    insmod ext2
    search --no-floppy --label --set=state MOONHEAD_STATE
    load_env --file=(\$state)/grubenv
    if [ -z "\$slot" ]; then
        set slot=A
    fi
    if [ "\$boot_pending" = "1" ]; then
        if [ "\$boot_attempts" = "0" ]; then
            set boot_attempts=1
        elif [ "\$boot_attempts" = "1" ]; then
            set boot_attempts=2
        else
            set slot=\$healthy_slot
            set boot_pending=0
        fi
        save_env --file=(\$state)/grubenv slot healthy_slot boot_pending boot_attempts
    fi
    if [ "\$slot" = "A" ]; then
        set root_partuuid=${ROOT_A_PARTUUID}
        set hash_partuuid=${HASH_A_PARTUUID}
        set root_hash=\$root_hash_a
        set root_salt=\$root_salt_a
    else
        set root_partuuid=${ROOT_B_PARTUUID}
        set hash_partuuid=${HASH_B_PARTUUID}
        set root_hash=\$root_hash_b
        set root_salt=\$root_salt_b
    fi
    set dm_table="moonhead-verity,,,ro,0 ${DATA_SECTORS} verity 1 PARTUUID=\$root_partuuid PARTUUID=\$hash_partuuid 4096 4096 \$data_blocks 1 sha256 \$root_hash \$root_salt 1 panic_on_corruption"
    linux /kernel-\$slot root=/dev/dm-0 rootfstype=erofs ro rootwait dm-mod.waitfor=PARTUUID=\$root_partuuid,PARTUUID=\$hash_partuuid dm-mod.create="\$dm_table" init=/sbin/moonhead-init lsm=landlock,yama,bpf ${CONSOLE_ARG}
}
EOF

grub-mkstandalone \
  --format="${GRUB_FMT}" \
  --output="${ISO_STAGE}/live/disk-boot.efi" \
  "boot/grub/grub.cfg=${ISO_STAGE}/disk-grub.cfg"
sign_efi "${ISO_STAGE}/live/disk-boot.efi"

# 3. Build Live ISO GRUB EFI binary + El Torito image
cat <<EOF > "${ISO_STAGE}/grub.cfg"
set timeout=1
set default=0
insmod iso9660
insmod part_gpt
insmod fat
search --no-floppy --file --set=root /live/vmlinuz

menuentry "Moonhead OS 7.3 (Live / Installer)" {
    linux /live/vmlinuz lsm=landlock,yama,bpf ${CONSOLE_ARG}
    initrd /live/initrd.img
}
EOF

grub-mkstandalone \
  --format="${GRUB_FMT}" \
  --output="${ISO_STAGE}/EFI/BOOT/${EFI_BOOT_NAME}" \
  "boot/grub/grub.cfg=${ISO_STAGE}/grub.cfg"
sign_efi "${ISO_STAGE}/EFI/BOOT/${EFI_BOOT_NAME}"

truncate -s 16M "${ISO_STAGE}/efiboot.img"
mkfs.vfat -F 12 "${ISO_STAGE}/efiboot.img" >/dev/null
mmd -i "${ISO_STAGE}/efiboot.img" ::/EFI ::/EFI/BOOT
mcopy -i "${ISO_STAGE}/efiboot.img" "${ISO_STAGE}/EFI/BOOT/${EFI_BOOT_NAME}" "::/EFI/BOOT/${EFI_BOOT_NAME}"

# 4. Pack hybrid UEFI ISO-9660 image
xorriso -as mkisofs \
  -o "${OUT_ISO}" \
  -V "MOONHEAD_ISO" \
  -J -R \
  -e efiboot.img \
  -no-emul-boot \
  -append_partition 2 0xef "${ISO_STAGE}/efiboot.img" \
  "${ISO_STAGE}"

echo "Built bootable UEFI Live/Installer ISO: ${OUT_ISO} ($(du -h "${OUT_ISO}" | cut -f1))"
