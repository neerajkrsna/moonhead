#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
  -out "${TMP}/private.pem" >/dev/null 2>&1
openssl pkey -in "${TMP}/private.pem" -pubout \
  -out "${TMP}/public.pem" >/dev/null 2>&1
printf 'signed test kernel\n' > "${TMP}/kernel"
printf 'signed test root filesystem\n' > "${TMP}/rootfs.erofs"

mkdir -p "${TMP}/mockbin"
cat > "${TMP}/mockbin/veritysetup" <<'EOF'
#!/usr/bin/env bash
printf 'mock verity tree\n' > "${5}"
cat <<'OUT'
Root hash: 0000000000000000000000000000000000000000000000000000000000000000
Salt:     0000000000000000000000000000000000000000000000000000000000000000
OUT
EOF
cat > "${TMP}/mockbin/stat" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-c%s" ]]; then
  echo 100
else
  exec /usr/bin/stat "$@"
fi
EOF
chmod +x "${TMP}/mockbin/veritysetup" "${TMP}/mockbin/stat"

UPDATE_SIGNING_KEY="${TMP}/private.pem" \
  KERNEL_IMAGE="${TMP}/kernel" \
  ROOTFS_IMAGE="${TMP}/rootfs.erofs" \
  ARCH=arm64 \
  PATH="${TMP}/mockbin:${PATH}" \
  "${ROOT}/scripts/create-update.sh" 1.0.1 "${TMP}/update"

cat > "${TMP}/mockbin/id" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "-u" ]] && echo 0
EOF
cat > "${TMP}/mockbin/findmnt" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat > "${TMP}/mockbin/mount" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "${TMP}/mockbin/findfs" <<'EOF'
#!/usr/bin/env bash
echo "${MOCK_ROOT_DEV}"
EOF
cat > "${TMP}/mockbin/grub-editenv" <<'EOF'
#!/usr/bin/env bash
case "${2:-}" in
  list)
    printf 'slot=A\nhealthy_slot=A\nversion=1.0.0\n'
    ;;
  set)
    printf '%s\n' "$*" >> "${MOCK_GRUB_LOG}"
    ;;
  *)
    exit 1
    ;;
esac
EOF
cat > "${TMP}/mockbin/blkid" <<'EOF'
#!/usr/bin/env bash
echo "${MOCK_ROOT_DEV}"
EOF
cat > "${TMP}/mockbin/blockdev" <<'EOF'
#!/usr/bin/env bash
echo 1048576
EOF
cat > "${TMP}/mockbin/dpkg" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--print-architecture" ]]; then
  echo arm64
  exit 0
fi
[[ "${1:-}" == "--compare-versions" ]] && exit 0
EOF
cat > "${TMP}/mockbin/sync" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${TMP}"/mockbin/*

export MOCK_GRUB_LOG="${TMP}/grub.log"
export MOCK_ROOT_DEV="${TMP}/root-b"
export UPDATE_PUBLIC_KEY="${TMP}/public.pem"
export MOONHEAD_STATE_DIR="${TMP}/state"
export MOONHEAD_ESP_DIR="${TMP}/esp"
touch "${MOCK_ROOT_DEV}"

cp "${TMP}/update/manifest" "${TMP}/manifest.good"
printf 'tampered\n' >> "${TMP}/update/manifest"
if PATH="${TMP}/mockbin:${PATH}" "${ROOT}/scripts/moonhead-update.sh" \
  "${TMP}/update" >/dev/null 2>&1; then
  echo "ERROR: tampered update was accepted" >&2
  exit 1
fi
cp "${TMP}/manifest.good" "${TMP}/update/manifest"

PATH="${TMP}/mockbin:${PATH}" "${ROOT}/scripts/moonhead-update.sh" \
  "${TMP}/update" >/dev/null
test -s "${MOCK_ROOT_DEV}"
grep -q 'slot=B' "${MOCK_GRUB_LOG}"
grep -q 'boot_pending=1' "${MOCK_GRUB_LOG}"

echo "PASS: signed update rejected tampering and staged the inactive A/B slot"
