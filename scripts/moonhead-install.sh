#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: sudo moonhead-install [--yes-wipe] <block-device>

Installs Moonhead OS to an entire disk. The command refuses mounted devices,
the ISO source device, devices smaller than 4 GiB, and devices without the
explicit --yes-wipe acknowledgement.
EOF
}

if [[ "${1:-}" == "--yes-wipe" ]]; then
  YES_WIPE=1
  shift
else
  YES_WIPE=0
fi

TARGET_DEV="${1:-}"
if [[ -z "${TARGET_DEV}" || "${#}" -ne 1 ]]; then
  usage
  exit 2
fi
if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: moonhead-install must run as root (use sudo)." >&2
  exit 1
fi
if [[ "${YES_WIPE}" -ne 1 ]]; then
  echo "ERROR: installation requires --yes-wipe; this destroys the target disk." >&2
  exit 2
fi
if [[ ! -b "${TARGET_DEV}" ]]; then
  echo "ERROR: target is not a block device: ${TARGET_DEV}" >&2
  exit 1
fi

MOUNTED_PARTS=$(lsblk -nrpo NAME,MOUNTPOINTS "${TARGET_DEV}" |
  awk 'NF >= 2 && $2 != "-" && $2 != "" { print $1 }')
if [[ -n "${MOUNTED_PARTS}" ]]; then
  echo "ERROR: target or one of its partitions is mounted: ${MOUNTED_PARTS}" >&2
  exit 1
fi

SIZE_BYTES=$(blockdev --getsize64 "${TARGET_DEV}")
MIN_SIZE_BYTES=$((4 * 1024 * 1024 * 1024))
if (( SIZE_BYTES < MIN_SIZE_BYTES )); then
  echo "ERROR: target is smaller than 4 GiB." >&2
  exit 1
fi

case "$(uname -m)" in
  aarch64) EFI_BOOT_NAME="BOOTAA64.EFI"; HOST_ARCH=arm64 ;;
  x86_64) EFI_BOOT_NAME="BOOTX64.EFI"; HOST_ARCH=amd64 ;;
  *) echo "ERROR: unsupported installer architecture $(uname -m)." >&2; exit 1 ;;
esac

ISO_MNT=""
for candidate in /mnt/iso /run/initramfs/live /media/cdrom; do
  if [[ -f "${candidate}/live/rootfs-${HOST_ARCH}.erofs" ]]; then
    ISO_MNT="${candidate}"
    break
  fi
done
if [[ -z "${ISO_MNT}" ]]; then
  mkdir -p /mnt/moonhead-iso
  for dev in /dev/sr* /dev/sd* /dev/nvme*p* /dev/vd*; do
    [[ -b "${dev}" ]] || continue
    if mount -t iso9660 -o ro "${dev}" /mnt/moonhead-iso 2>/dev/null; then
      if [[ -f /mnt/moonhead-iso/live/rootfs-${HOST_ARCH}.erofs ]]; then
        ISO_MNT=/mnt/moonhead-iso
        break
      fi
      umount /mnt/moonhead-iso
    fi
  done
fi
if [[ -z "${ISO_MNT}" ]]; then
  echo "ERROR: could not locate Moonhead OS installer media." >&2
  exit 1
fi
for required in \
  "rootfs-${HOST_ARCH}-verity.erofs" \
  "rootfs-${HOST_ARCH}.verity" \
  verity.env \
  "vmlinuz-${HOST_ARCH}" \
  "disk-boot-${HOST_ARCH}.efi"; do
  if [[ ! -f "${ISO_MNT}/live/${required}" ]]; then
    echo "ERROR: installer media is missing /live/${required}." >&2
    exit 1
  fi
done

ISO_SOURCE_DEV=$(findmnt -no SOURCE --target "${ISO_MNT}" 2>/dev/null || true)
ISO_SOURCE_NAME="${ISO_SOURCE_DEV#/dev/}"
TARGET_NAME="${TARGET_DEV#/dev/}"
ISO_PARENT=$(lsblk -ndo PKNAME "${ISO_SOURCE_DEV}" 2>/dev/null || true)
if [[ -n "${ISO_SOURCE_DEV}" &&
      ( "${ISO_SOURCE_NAME}" == "${TARGET_NAME}" || "${ISO_PARENT}" == "${TARGET_NAME}" ) ]]; then
  echo "ERROR: refusing to install onto the installer device." >&2
  exit 1
fi

part_path() {
  if [[ "$1" =~ [0-9]$ ]]; then
    printf '%sp%s\n' "$1" "$2"
  else
    printf '%s%s\n' "$1" "$2"
  fi
}

ROOT_BYTES=$(stat -c%s "${ISO_MNT}/live/rootfs-${HOST_ARCH}-verity.erofs")
ROOT_MIB=$(( (ROOT_BYTES + 1048575) / 1048576 + 16 ))
HASH_BYTES=$(stat -c%s "${ISO_MNT}/live/rootfs-${HOST_ARCH}.verity")
HASH_MIB=$(( (HASH_BYTES + 1048575) / 1048576 + 1 ))
ESP_MIB=256
STATE_MIB=64
FIXED_MIB=$((ESP_MIB + (ROOT_MIB + HASH_MIB) * 2 + STATE_MIB + 64))
if (( SIZE_BYTES / 1048576 <= FIXED_MIB )); then
  echo "ERROR: target lacks enough space for two system slots and persistent data." >&2
  exit 1
fi
ROOT_HASH=$(sed -n 's/^root_hash=//p' "${ISO_MNT}/live/verity.env")
SALT=$(sed -n 's/^salt=//p' "${ISO_MNT}/live/verity.env")
DATA_BLOCKS=$(sed -n 's/^data_blocks=//p' "${ISO_MNT}/live/verity.env")
if [[ ! "${ROOT_HASH}" =~ ^[[:xdigit:]]{64}$ ||
      ! "${SALT}" =~ ^[[:xdigit:]]+$ ||
      ! "${DATA_BLOCKS}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: installer media has invalid dm-verity metadata." >&2
  exit 1
fi

echo "[1/5] Partitioning ${TARGET_DEV}..."
sgdisk --zap-all "${TARGET_DEV}" >/dev/null
sgdisk \
  -n "1:2048:+${ESP_MIB}M" -t 1:EF00 -c 1:MOONHEAD_ESP \
  -n "2:0:+${ROOT_MIB}M" -t 2:8300 -c 2:MOONHEAD_ROOT_A \
  -u 2:c02e0500-0000-4000-8000-000000000002 \
  -n "3:0:+${HASH_MIB}M" -t 3:8300 -c 3:MOONHEAD_HASH_A \
  -u 3:c02e0500-0000-4000-8000-000000000003 \
  -n "4:0:+${ROOT_MIB}M" -t 4:8300 -c 4:MOONHEAD_ROOT_B \
  -u 4:c02e0500-0000-4000-8000-000000000004 \
  -n "5:0:+${HASH_MIB}M" -t 5:8300 -c 5:MOONHEAD_HASH_B \
  -u 5:c02e0500-0000-4000-8000-000000000005 \
  -n "6:0:+${STATE_MIB}M" -t 6:8300 -c 6:MOONHEAD_STATE \
  -n 7:0:0 -t 7:8300 -c 7:MOONHEAD_DATA \
  "${TARGET_DEV}" >/dev/null
partprobe "${TARGET_DEV}" 2>/dev/null ||
  blockdev --rereadpt "${TARGET_DEV}" 2>/dev/null || true
sleep 1
for _ in $(seq 1 10); do
  if [[ -b "$(part_path "${TARGET_DEV}" 1)" &&
        -b "$(part_path "${TARGET_DEV}" 7)" ]]; then
    break
  fi
  sleep 1
done
if [[ ! -b "$(part_path "${TARGET_DEV}" 1)" ||
      ! -b "$(part_path "${TARGET_DEV}" 7)" ]]; then
  echo "ERROR: partition devices did not appear after repartitioning." >&2
  exit 1
fi

P1=$(part_path "${TARGET_DEV}" 1)
P2=$(part_path "${TARGET_DEV}" 2)
P3=$(part_path "${TARGET_DEV}" 3)
P4=$(part_path "${TARGET_DEV}" 4)
P5=$(part_path "${TARGET_DEV}" 5)
P6=$(part_path "${TARGET_DEV}" 6)
P7=$(part_path "${TARGET_DEV}" 7)

echo "[2/5] Formatting EFI and persistent partitions..."
mkfs.vfat -F 32 -n MOONHEADESP "${P1}" >/dev/null
mkfs.ext4 -q -F -L MOONHEAD_STATE "${P6}"
mkfs.ext4 -q -F -L MOONHEAD_DATA "${P7}"

echo "[3/5] Installing dm-verity A/B root images..."
dd if="${ISO_MNT}/live/rootfs-${HOST_ARCH}-verity.erofs" of="${P2}" bs=4M conv=fsync status=progress
dd if="${ISO_MNT}/live/rootfs-${HOST_ARCH}.verity" of="${P3}" bs=4M conv=fsync status=progress
dd if="${ISO_MNT}/live/rootfs-${HOST_ARCH}-verity.erofs" of="${P4}" bs=4M conv=fsync status=progress
dd if="${ISO_MNT}/live/rootfs-${HOST_ARCH}.verity" of="${P5}" bs=4M conv=fsync status=progress

echo "[4/5] Installing bootloader and boot state..."
mmd -i "${P1}" ::/EFI ::/EFI/BOOT
mcopy -i "${P1}" "${ISO_MNT}/live/disk-boot-${HOST_ARCH}.efi" "::/EFI/BOOT/${EFI_BOOT_NAME}"
mcopy -i "${P1}" "${ISO_MNT}/live/vmlinuz-${HOST_ARCH}" "::/kernel-${HOST_ARCH}-A"
mcopy -i "${P1}" "${ISO_MNT}/live/vmlinuz-${HOST_ARCH}" "::/kernel-${HOST_ARCH}-B"
if [[ -f "${ISO_MNT}/live/secure-boot-cert.der" ]]; then
  mcopy -i "${P1}" "${ISO_MNT}/live/secure-boot-cert.der" \
    ::/secure-boot-cert.der
fi

STATE_MNT=$(mktemp -d /tmp/moonhead-state.XXXXXX)
trap 'umount "${STATE_MNT}" 2>/dev/null || true; rmdir "${STATE_MNT}" 2>/dev/null || true' EXIT
mount "${P6}" "${STATE_MNT}"
grub-editenv "${STATE_MNT}/grubenv" create
grub-editenv "${STATE_MNT}/grubenv" set \
  slot=A healthy_slot=A boot_pending=0 boot_attempts=0 version=0.0.0 \
  "root_hash_a=${ROOT_HASH}" "root_hash_b=${ROOT_HASH}" \
  "root_salt_a=${SALT}" "root_salt_b=${SALT}" \
  "data_blocks=${DATA_BLOCKS}"

echo "[5/5] Verifying the installed partitions..."
sgdisk -v "${TARGET_DEV}" >/dev/null
sync

cat <<'EOF'

Moonhead OS was installed with A/B system slots.
Eject the ISO and reboot. The initial A slot is selected.
Log in as admin with the password set while building the image.
EOF
