#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-}"
OUTPUT_DIR="${2:-}"
KERNEL_IMAGE="${KERNEL_IMAGE:-}"
ROOTFS_IMAGE="${ROOTFS_IMAGE:-}"
SIGNING_KEY="${UPDATE_SIGNING_KEY:-}"
ARCH="${ARCH:-arm64}"

if [[ -z "${VERSION}" || -z "${OUTPUT_DIR}" || -z "${SIGNING_KEY}" ||
      -z "${KERNEL_IMAGE}" || -z "${ROOTFS_IMAGE}" ]]; then
  cat >&2 <<'EOF'
Usage: UPDATE_SIGNING_KEY=private.pem KERNEL_IMAGE=... ROOTFS_IMAGE=... \
  ./scripts/create-update.sh <version> <output-directory>
EOF
  exit 2
fi
if [[ ! "${VERSION}" =~ ^[0-9A-Za-z.+:~-]+$ ]]; then
  echo "ERROR: version contains unsupported characters." >&2
  exit 2
fi

mkdir -p "${OUTPUT_DIR}"
rm -f "${OUTPUT_DIR}/kernel" "${OUTPUT_DIR}/rootfs.erofs" \
  "${OUTPUT_DIR}/rootfs.verity"
KERNEL_FILE="kernel-${ARCH}"
ROOTFS_FILE="rootfs-${ARCH}.erofs"
VERITY_FILE="rootfs-${ARCH}.verity"
install -m 0644 "${KERNEL_IMAGE}" "${OUTPUT_DIR}/${KERNEL_FILE}"
install -m 0644 "${ROOTFS_IMAGE}" "${OUTPUT_DIR}/${ROOTFS_FILE}"
ROOT_BYTES=$(stat -c%s "${OUTPUT_DIR}/${ROOTFS_FILE}")
ALIGNED_BYTES=$(( (ROOT_BYTES + 4095) / 4096 * 4096 ))
truncate -s "${ALIGNED_BYTES}" "${OUTPUT_DIR}/${ROOTFS_FILE}"
VERITY_OUT=$(veritysetup format --data-block-size=4096 --hash-block-size=4096 \
  "${OUTPUT_DIR}/${ROOTFS_FILE}" "${OUTPUT_DIR}/${VERITY_FILE}")
ROOT_HASH=$(printf '%s\n' "${VERITY_OUT}" | awk '/^Root hash:/ {print $3}')
SALT=$(printf '%s\n' "${VERITY_OUT}" | awk '/^Salt:/ {print $2}')
DATA_BLOCKS=$((ALIGNED_BYTES / 4096))
{
  echo "format=moonhead-update-v1"
  echo "architecture=${ARCH}"
  echo "version=${VERSION}"
  printf 'kernel-sha256=%s\n' "$(sha256sum "${OUTPUT_DIR}/${KERNEL_FILE}" | cut -d' ' -f1)"
  printf 'rootfs-sha256=%s\n' "$(sha256sum "${OUTPUT_DIR}/${ROOTFS_FILE}" | cut -d' ' -f1)"
  printf 'verity-sha256=%s\n' "$(sha256sum "${OUTPUT_DIR}/${VERITY_FILE}" | cut -d' ' -f1)"
  printf 'root-hash=%s\n' "${ROOT_HASH}"
  printf 'salt=%s\n' "${SALT}"
  printf 'data-blocks=%s\n' "${DATA_BLOCKS}"
} > "${OUTPUT_DIR}/manifest"
openssl dgst -sha256 -sign "${SIGNING_KEY}" \
  -out "${OUTPUT_DIR}/manifest.sig" "${OUTPUT_DIR}/manifest"
echo "Created signed update bundle in ${OUTPUT_DIR}"
