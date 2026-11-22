#!/usr/bin/env bash
set -euo pipefail

ARCH="${ARCH:-arm64}"
KERNEL_DIR="${KERNEL_DIR:-./kernel/linux-7.3}"
BUILD_DIR="${BUILD_DIR:-./build/${ARCH}}"
ROOTFS_EROFS="${BUILD_DIR}/rootfs-${ARCH}.erofs"
OUT_IMG="${BUILD_DIR}/moonhead-${ARCH}.img"
STAGE_DIR="${BUILD_DIR}/img-stage"
DATA_SIZE_MB="${DATA_SIZE_MB:-7680}"
ESP_SIZE_MB=256
STATE_SIZE_MB=64
SECURE_BOOT="${SECURE_BOOT:-0}"

ROOT_A_PARTUUID="c02e0500-0000-4000-8000-000000000002"
HASH_A_PARTUUID="c02e0500-0000-4000-8000-000000000003"
ROOT_B_PARTUUID="c02e0500-0000-4000-8000-000000000004"
HASH_B_PARTUUID="c02e0500-0000-4000-8000-000000000005"

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

# 1. Pad rootfs.erofs to 4096-byte boundary and generate dm-verity Merkle hash tree
VERITY_DATA="${STAGE_DIR}/rootfs-${ARCH}-verity.erofs"
VERITY_HASH="${STAGE_DIR}/rootfs-${ARCH}.verity"
cp "${ROOTFS_EROFS}" "${VERITY_DATA}"
RAW_BYTES=$(stat -c%s "${VERITY_DATA}")
ALIGNED_BYTES=$(( (RAW_BYTES + 4095) / 4096 * 4096 ))
truncate -s "${ALIGNED_BYTES}" "${VERITY_DATA}"

VERITY_OUT=$(veritysetup format --data-block-size=4096 --hash-block-size=4096 "${VERITY_DATA}" "${VERITY_HASH}")
ROOT_HASH=$(printf '%s\n' "${VERITY_OUT}" | awk '/^Root hash:/ {print $3}')
SALT=$(printf '%s\n' "${VERITY_OUT}" | awk '/^Salt:/ {print $2}')
DATA_BLOCKS=$((ALIGNED_BYTES / 4096))
DATA_SECTORS=$((DATA_BLOCKS * 8))

cat <<EOF > "${STAGE_DIR}/grub.cfg"
set timeout=1
set default=0
insmod part_gpt
insmod fat
insmod ext2
search --no-floppy --file --set=root /kernel-${ARCH}-A

menuentry "Moonhead OS ${ARCH} (dm-verity A/B)" {
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
    linux /kernel-${ARCH}-\$slot root=/dev/dm-0 rootfstype=erofs ro rootwait dm-mod.waitfor=PARTUUID=\$root_partuuid,PARTUUID=\$hash_partuuid dm-mod.create="\$dm_table" init=/sbin/moonhead-init lsm=landlock,yama,bpf ${CONSOLE_ARG}
}
EOF

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

grub-mkstandalone \
  --format="${GRUB_FMT}" \
  --output="${STAGE_DIR}/EFI/BOOT/${EFI_BOOT_NAME}" \
  "boot/grub/grub.cfg=${STAGE_DIR}/grub.cfg"
sign_efi "${STAGE_DIR}/EFI/BOOT/${EFI_BOOT_NAME}"

# 2. Build FAT32 EFI System Partition
ESP_IMG="${STAGE_DIR}/esp-${ARCH}.img"
truncate -s "${ESP_SIZE_MB}M" "${ESP_IMG}"
mkfs.vfat -F 32 -n "MOONHEADESP" "${ESP_IMG}" >/dev/null
mmd -i "${ESP_IMG}" ::/EFI ::/EFI/BOOT
mcopy -i "${ESP_IMG}" "${STAGE_DIR}/EFI/BOOT/${EFI_BOOT_NAME}" "::/EFI/BOOT/${EFI_BOOT_NAME}"
cp "${KERNEL_IMG}" "${STAGE_DIR}/kernel"
sign_efi "${STAGE_DIR}/kernel"
mcopy -i "${ESP_IMG}" "${STAGE_DIR}/kernel" "::/kernel-${ARCH}-A"
mcopy -i "${ESP_IMG}" "${STAGE_DIR}/kernel" "::/kernel-${ARCH}-B"
if [[ "${SECURE_BOOT}" == "1" ]]; then
  openssl x509 -in "${SECURE_BOOT_CERT}" -outform DER \
    -out "${STAGE_DIR}/secure-boot-cert.der"
  mcopy -i "${ESP_IMG}" "${STAGE_DIR}/secure-boot-cert.der" ::/secure-boot-cert.der
fi

# 3. Build A/B state and persistent ext4 overlay
STATE_STAGE="${STAGE_DIR}/state"
mkdir -p "${STATE_STAGE}"
grub-editenv "${STATE_STAGE}/grubenv" create
grub-editenv "${STATE_STAGE}/grubenv" set \
  slot=A healthy_slot=A boot_pending=0 boot_attempts=0 version=0.0.0 \
  "root_hash_a=${ROOT_HASH}" "root_hash_b=${ROOT_HASH}" \
  "root_salt_a=${SALT}" "root_salt_b=${SALT}" "data_blocks=${DATA_BLOCKS}"
STATE_IMG="${STAGE_DIR}/state-${ARCH}.img"
truncate -s "${STATE_SIZE_MB}M" "${STATE_IMG}"
mkfs.ext4 -q -F -L MOONHEAD_STATE -d "${STATE_STAGE}" "${STATE_IMG}"

DATA_IMG="${STAGE_DIR}/data-${ARCH}.img"
truncate -s "${DATA_SIZE_MB}M" "${DATA_IMG}"
mkfs.ext4 -F -L "MOONHEAD_DATA" "${DATA_IMG}" >/dev/null

# 4. Compute 1 MiB-aligned sector offsets and pack the GPT disk image
ESP_START=2048
ESP_SECTORS=$((ESP_SIZE_MB * 2048))

ROOT_A_START=$((ESP_START + ESP_SECTORS))
ROOT_ALIGNED_MIB=$(( (ALIGNED_BYTES + 1048575) / 1048576 * 1048576 ))
ROOT_SECTORS=$((ROOT_ALIGNED_MIB / 512))

VERITY_A_START=$((ROOT_A_START + ROOT_SECTORS))
VERITY_BYTES=$(stat -c%s "${VERITY_HASH}")
VERITY_ALIGNED_MIB=$(( (VERITY_BYTES + 1048575) / 1048576 * 1048576 ))
VERITY_SECTORS=$((VERITY_ALIGNED_MIB / 512))

ROOT_B_START=$((VERITY_A_START + VERITY_SECTORS))
VERITY_B_START=$((ROOT_B_START + ROOT_SECTORS))
STATE_START=$((VERITY_B_START + VERITY_SECTORS))
STATE_SECTORS=$((STATE_SIZE_MB * 2048))
DATA_START=$((STATE_START + STATE_SECTORS))
DATA_SECTORS=$((DATA_SIZE_MB * 2048))
TOTAL_SECTORS=$((DATA_START + DATA_SECTORS + 2048))

rm -f "${OUT_IMG}"
truncate -s $((TOTAL_SECTORS * 512)) "${OUT_IMG}"

sgdisk -Z "${OUT_IMG}" >/dev/null
sgdisk -n 1:${ESP_START}:+${ESP_SECTORS} -t 1:EF00 -c 1:MOONHEAD_ESP "${OUT_IMG}" >/dev/null
sgdisk -n 2:${ROOT_A_START}:+${ROOT_SECTORS} -t 2:8300 -c 2:MOONHEAD_ROOT_A -u 2:${ROOT_A_PARTUUID} "${OUT_IMG}" >/dev/null
sgdisk -n 3:${VERITY_A_START}:+${VERITY_SECTORS} -t 3:8300 -c 3:MOONHEAD_HASH_A -u 3:${HASH_A_PARTUUID} "${OUT_IMG}" >/dev/null
sgdisk -n 4:${ROOT_B_START}:+${ROOT_SECTORS} -t 4:8300 -c 4:MOONHEAD_ROOT_B -u 4:${ROOT_B_PARTUUID} "${OUT_IMG}" >/dev/null
sgdisk -n 5:${VERITY_B_START}:+${VERITY_SECTORS} -t 5:8300 -c 5:MOONHEAD_HASH_B -u 5:${HASH_B_PARTUUID} "${OUT_IMG}" >/dev/null
sgdisk -n 6:${STATE_START}:+${STATE_SECTORS} -t 6:8300 -c 6:MOONHEAD_STATE "${OUT_IMG}" >/dev/null
sgdisk -n 7:${DATA_START}:+${DATA_SECTORS} -t 7:8300 -c 7:MOONHEAD_DATA "${OUT_IMG}" >/dev/null

dd if="${ESP_IMG}" of="${OUT_IMG}" bs=512 seek=${ESP_START} conv=notrunc status=none
dd if="${VERITY_DATA}" of="${OUT_IMG}" bs=512 seek=${ROOT_A_START} conv=notrunc status=none
dd if="${VERITY_HASH}" of="${OUT_IMG}" bs=512 seek=${VERITY_A_START} conv=notrunc status=none
dd if="${VERITY_DATA}" of="${OUT_IMG}" bs=512 seek=${ROOT_B_START} conv=notrunc status=none
dd if="${VERITY_HASH}" of="${OUT_IMG}" bs=512 seek=${VERITY_B_START} conv=notrunc status=none
dd if="${STATE_IMG}" of="${OUT_IMG}" bs=512 seek=${STATE_START} conv=notrunc status=none
dd if="${DATA_IMG}" of="${OUT_IMG}" bs=512 seek=${DATA_START} conv=notrunc status=none

echo "Built dm-verity UEFI disk image: ${OUT_IMG} ($(du -h "${OUT_IMG}" | cut -f1))"
echo "  dm-verity Root Hash (SHA-256): ${ROOT_HASH}"
