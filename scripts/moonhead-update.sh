#!/usr/bin/env bash
set -euo pipefail

UPDATE_DIR="${1:-}"
PUBLIC_KEY="${UPDATE_PUBLIC_KEY:-/etc/moonhead/update-public-key.pem}"
STATE_DIR="${MOONHEAD_STATE_DIR:-/mnt/moonhead-state}"
ESP_DIR="${MOONHEAD_ESP_DIR:-/mnt/moonhead-esp}"
TARGET_ARCH=$(dpkg --print-architecture)
KERNEL_FILE="kernel-${TARGET_ARCH}"
ROOTFS_FILE="rootfs-${TARGET_ARCH}.erofs"
VERITY_FILE="rootfs-${TARGET_ARCH}.verity"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: moonhead-update must run as root (use sudo)." >&2
  exit 1
fi
if [[ -z "${UPDATE_DIR}" || ! -d "${UPDATE_DIR}" ]]; then
  echo "Usage: sudo moonhead-update <signed-update-directory>" >&2
  exit 2
fi
if [[ ! -f "${PUBLIC_KEY}" ]]; then
  echo "ERROR: update public key not installed at ${PUBLIC_KEY}." >&2
  exit 1
fi

for required in manifest manifest.sig "${KERNEL_FILE}" "${ROOTFS_FILE}" "${VERITY_FILE}"; do
  if [[ ! -f "${UPDATE_DIR}/${required}" ]]; then
    echo "ERROR: update is missing ${required}." >&2
    exit 1
  fi
done

openssl dgst -sha256 -verify "${PUBLIC_KEY}" \
  -signature "${UPDATE_DIR}/manifest.sig" "${UPDATE_DIR}/manifest"

FORMAT=
ARCHITECTURE=
VERSION=
KERNEL_SHA256=
ROOTFS_SHA256=
VERITY_SHA256=
ROOT_HASH=
SALT=
DATA_BLOCKS=
while IFS='=' read -r key value; do
  [[ -z "${key}" || "${key}" == \#* ]] && continue
  case "${key}" in
    format) FORMAT="${value}" ;;
    architecture) ARCHITECTURE="${value}" ;;
    version) VERSION="${value}" ;;
    kernel-sha256) KERNEL_SHA256="${value}" ;;
    rootfs-sha256) ROOTFS_SHA256="${value}" ;;
    verity-sha256) VERITY_SHA256="${value}" ;;
    root-hash) ROOT_HASH="${value}" ;;
    salt) SALT="${value}" ;;
    data-blocks) DATA_BLOCKS="${value}" ;;
    *) echo "ERROR: unknown manifest field: ${key}" >&2; exit 1 ;;
  esac
done < "${UPDATE_DIR}/manifest"

if [[ "${FORMAT}" != "moonhead-update-v1" ||
      "${ARCHITECTURE}" != "${TARGET_ARCH}" ||
      -z "${VERSION}" ||
      ! "${KERNEL_SHA256}" =~ ^[[:xdigit:]]{64}$ ||
      ! "${ROOTFS_SHA256}" =~ ^[[:xdigit:]]{64}$ ||
      ! "${VERITY_SHA256}" =~ ^[[:xdigit:]]{64}$ ||
      ! "${ROOT_HASH}" =~ ^[[:xdigit:]]{64}$ ||
      ! "${SALT}" =~ ^[[:xdigit:]]+$ ||
      ! "${DATA_BLOCKS}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: malformed or architecture-incompatible update manifest." >&2
  exit 1
fi
if [[ ! "${VERSION}" =~ ^[0-9A-Za-z.+:~-]+$ ]]; then
  echo "ERROR: update version contains unsupported characters." >&2
  exit 1
fi
printf '%s  %s\n' "${KERNEL_SHA256}" "${UPDATE_DIR}/${KERNEL_FILE}" | sha256sum -c -
printf '%s  %s\n' "${ROOTFS_SHA256}" "${UPDATE_DIR}/${ROOTFS_FILE}" | sha256sum -c -
printf '%s  %s\n' "${VERITY_SHA256}" "${UPDATE_DIR}/${VERITY_FILE}" | sha256sum -c -

mkdir -p "${STATE_DIR}" "${ESP_DIR}"
if ! findmnt -rn "${STATE_DIR}" >/dev/null; then
  STATE_DEV=$(findfs PARTLABEL=MOONHEAD_STATE 2>/dev/null || true)
  if [[ -z "${STATE_DEV}" ]]; then
    echo "ERROR: MOONHEAD_STATE partition was not found." >&2
    exit 1
  fi
  mount -t ext4 "${STATE_DEV}" "${STATE_DIR}"
fi
if ! findmnt -rn "${ESP_DIR}" >/dev/null; then
  mount -t vfat LABEL=MOONHEADESP "${ESP_DIR}"
fi

ACTIVE_SLOT=$(grub-editenv "${STATE_DIR}/grubenv" list | sed -n 's/^slot=//p')
case "${ACTIVE_SLOT}" in
  A) TARGET_SLOT=B; ROOT_LABEL=MOONHEAD_ROOT_B; HASH_LABEL=MOONHEAD_HASH_B ;;
  B) TARGET_SLOT=A; ROOT_LABEL=MOONHEAD_ROOT_A; HASH_LABEL=MOONHEAD_HASH_A ;;
  *) echo "ERROR: invalid active slot '${ACTIVE_SLOT}'." >&2; exit 1 ;;
esac
CURRENT_VERSION=$(grub-editenv "${STATE_DIR}/grubenv" list |
  sed -n 's/^version=//p')
if [[ -n "${CURRENT_VERSION}" ]] &&
   ! dpkg --compare-versions "${VERSION}" gt "${CURRENT_VERSION}"; then
  echo "ERROR: update version ${VERSION} is not newer than ${CURRENT_VERSION}." >&2
  exit 1
fi
ROOT_DEV=$(findfs "PARTLABEL=${ROOT_LABEL}" 2>/dev/null || true)
HASH_DEV=$(findfs "PARTLABEL=${HASH_LABEL}" 2>/dev/null || true)
if [[ -z "${ROOT_DEV}" || -z "${HASH_DEV}" ]]; then
  echo "ERROR: block devices for slot ${TARGET_SLOT} were not found." >&2
  exit 1
fi
ROOT_SIZE=$(blockdev --getsize64 "${ROOT_DEV}")
HASH_SIZE=$(blockdev --getsize64 "${HASH_DEV}")
IMAGE_SIZE=$(stat -c%s "${UPDATE_DIR}/${ROOTFS_FILE}")
VERITY_SIZE=$(stat -c%s "${UPDATE_DIR}/${VERITY_FILE}")
if (( IMAGE_SIZE > ROOT_SIZE )); then
  echo "ERROR: root filesystem is too large for slot ${TARGET_SLOT}." >&2
  exit 1
fi
if (( VERITY_SIZE > HASH_SIZE )); then
  echo "ERROR: verity tree is too large for slot ${TARGET_SLOT}." >&2
  exit 1
fi

echo "Installing signed update ${VERSION} into slot ${TARGET_SLOT}..."
dd if="${UPDATE_DIR}/${ROOTFS_FILE}" of="${ROOT_DEV}" bs=4M conv=fsync status=progress
dd if="${UPDATE_DIR}/${VERITY_FILE}" of="${HASH_DEV}" bs=4M conv=fsync status=progress
install -m 0644 "${UPDATE_DIR}/${KERNEL_FILE}" \
  "${ESP_DIR}/kernel-${TARGET_ARCH}-${TARGET_SLOT}.tmp"
mv -f "${ESP_DIR}/kernel-${TARGET_ARCH}-${TARGET_SLOT}.tmp" \
  "${ESP_DIR}/kernel-${TARGET_ARCH}-${TARGET_SLOT}"
sync

TARGET_LOWER=$(printf '%s' "${TARGET_SLOT}" | tr '[:upper:]' '[:lower:]')
grub-editenv "${STATE_DIR}/grubenv" set \
  "slot=${TARGET_SLOT}" \
  boot_pending=1 \
  boot_attempts=0 \
  "pending_version=${VERSION}" \
  "root_hash_${TARGET_LOWER}=${ROOT_HASH}" \
  "root_salt_${TARGET_LOWER}=${SALT}" \
  "data_blocks=${DATA_BLOCKS}"

echo "Update staged. Reboot to validate slot ${TARGET_SLOT}; the healthy slot is retained for rollback."
