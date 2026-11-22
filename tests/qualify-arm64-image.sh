#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

IMAGE="${1:-}"
UPDATE_DIR="${2:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
QEMU_SSH_PORT="${QEMU_SSH_PORT:-2228}"
QEMU_TIMEOUT_SECONDS="${QEMU_TIMEOUT_SECONDS:-180}"
QEMU_PID=
QEMU_LOG=
WORK_DIR=$(mktemp -d)

usage() {
  cat <<'EOF'
Usage: ADMIN_PASSWORD=<password> tests/qualify-arm64-image.sh <image> <signed-update-directory>

Runs the ARM64 Moonhead OS release qualification:
  1. Password SSH and runtime health
  2. Persistent state and reboot
  3. Signed update to slot B
  4. Simulated B-slot corruption
  5. Boot rollback to healthy slot A

Optional:
  QEMU_SSH_PORT=2228
  QEMU_FIRMWARE=/path/to/uefi-code.fd
  QEMU_BIN=qemu-system-aarch64
  QEMU_ACCEL=kvm|tcg|hvf
  QEMU_CPU=max|host
EOF
}

cleanup() {
  if [[ -n "${QEMU_PID}" ]] && kill -0 "${QEMU_PID}" 2>/dev/null; then
    kill "${QEMU_PID}"
    wait "${QEMU_PID}" 2>/dev/null || true
  fi
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT INT TERM

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $1" >&2
    exit 1
  fi
}

if [[ -z "${IMAGE}" || -z "${UPDATE_DIR}" || ! -f "${IMAGE}" ||
      ! -d "${UPDATE_DIR}" || -z "${ADMIN_PASSWORD}" ]]; then
  usage >&2
  exit 2
fi
for required in \
  manifest manifest.sig kernel-arm64 rootfs-arm64.erofs rootfs-arm64.verity; do
  if [[ ! -f "${UPDATE_DIR}/${required}" ]]; then
    echo "ERROR: update bundle is missing ${required}." >&2
    exit 1
  fi
done

for command in qemu-img ssh sshpass scp sgdisk; do
  require_command "${command}"
done

QEMU_BIN="${QEMU_BIN:-qemu-system-aarch64}"
require_command "${QEMU_BIN}"
if [[ -z "${QEMU_FIRMWARE:-}" ]]; then
  for candidate in \
    /usr/share/AAVMF/AAVMF_CODE.fd \
    /usr/share/AAVMF/AAVMF_CODE.no-secboot.fd; do
    if [[ -f "${candidate}" ]]; then
      QEMU_FIRMWARE="${candidate}"
      break
    fi
  done
fi
if [[ -z "${QEMU_FIRMWARE:-}" || ! -f "${QEMU_FIRMWARE}" ]]; then
  echo "ERROR: set QEMU_FIRMWARE to ARM64 UEFI firmware." >&2
  exit 1
fi
if [[ -z "${QEMU_ACCEL:-}" ]]; then
  if [[ "$(uname -s)" == "Darwin" ]]; then
    QEMU_ACCEL=hvf
  elif [[ -e /dev/kvm ]]; then
    QEMU_ACCEL=kvm
  else
    QEMU_ACCEL=tcg
  fi
fi
if [[ -n "${QEMU_CPU:-}" ]]; then
  :
elif [[ "${QEMU_ACCEL}" == "tcg" ]]; then
  QEMU_CPU=max
else
  QEMU_CPU=host
fi

TEST_IMAGE="${WORK_DIR}/moonhead-arm64.img"
cp "${IMAGE}" "${TEST_IMAGE}"
QEMU_LOG="${WORK_DIR}/qemu.log"

SSH_OPTIONS=(
  -p "${QEMU_SSH_PORT}"
  -o BatchMode=no
  -o ConnectTimeout=3
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o PreferredAuthentications=password
  -o PubkeyAuthentication=no
)
export SSHPASS="${ADMIN_PASSWORD}"

start_qemu() {
  : > "${QEMU_LOG}"
  "${QEMU_BIN}" \
    -M virt -accel "${QEMU_ACCEL}" -cpu "${QEMU_CPU}" -smp 4 -m 2G -nographic \
    -bios "${QEMU_FIRMWARE}" \
    -drive "file=${TEST_IMAGE},format=raw,if=virtio" \
    -netdev "user,id=net0,hostfwd=tcp::${QEMU_SSH_PORT}-:22" \
    -device virtio-net-pci,netdev=net0 \
    > "${QEMU_LOG}" 2>&1 &
  QEMU_PID=$!
}

stop_qemu() {
  if [[ -n "${QEMU_PID}" ]] && kill -0 "${QEMU_PID}" 2>/dev/null; then
    kill "${QEMU_PID}"
    wait "${QEMU_PID}" 2>/dev/null || true
  fi
  QEMU_PID=
}

graceful_stop() {
  guest_sudo 'sync'
  guest_sudo 'poweroff'
  local deadline=$((SECONDS + 30))
  while (( SECONDS < deadline )) && kill -0 "${QEMU_PID}" 2>/dev/null; do
    sleep 1
  done
  if kill -0 "${QEMU_PID}" 2>/dev/null; then
    echo "ERROR: guest did not power off cleanly." >&2
    stop_qemu
    return 1
  fi
  wait "${QEMU_PID}" 2>/dev/null || true
  QEMU_PID=
}

wait_for_ssh() {
  local timeout="$1"
  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    if ! kill -0 "${QEMU_PID}" 2>/dev/null; then
      echo "ERROR: QEMU exited before SSH became available." >&2
      tail -100 "${QEMU_LOG}" >&2
      return 1
    fi
    if sshpass -e ssh "${SSH_OPTIONS[@]}" admin@127.0.0.1 \
      'test "$(uname -m)" = aarch64' >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "ERROR: SSH did not become available within ${timeout}s." >&2
  tail -100 "${QEMU_LOG}" >&2
  return 1
}

guest() {
  local attempt
  for attempt in 1 2 3 4 5; do
    if sshpass -e ssh "${SSH_OPTIONS[@]}" admin@127.0.0.1 "$1"; then
      return 0
    fi
    sleep 2
  done
  echo "ERROR: guest command failed after 5 SSH attempts." >&2
  return 1
}

guest_sudo() {
  local attempt
  for attempt in 1 2 3 4 5; do
    if printf '%s\n' "${ADMIN_PASSWORD}" |
      sshpass -e ssh "${SSH_OPTIONS[@]}" admin@127.0.0.1 \
        "sudo -S -- $1"; then
      return 0
    fi
    sleep 2
  done
  echo "ERROR: guest sudo command failed after 5 SSH attempts." >&2
  return 1
}

expect_no_ssh() {
  local timeout="$1"
  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    if ! kill -0 "${QEMU_PID}" 2>/dev/null; then
      return 0
    fi
    if sshpass -e ssh "${SSH_OPTIONS[@]}" admin@127.0.0.1 \
      'exit 0' >/dev/null 2>&1; then
      echo "ERROR: corrupted B slot unexpectedly reached SSH." >&2
      return 1
    fi
    sleep 2
  done
  echo "Expected failed B-slot boot did not expose SSH within ${timeout}s."
}

echo "[1/5] Verifying initial A-slot boot..."
start_qemu
wait_for_ssh "${QEMU_TIMEOUT_SECONDS}"
guest '
  set -eu
  test "$(uname -m)" = aarch64
  test "$(id -u)" != 0
  grep -q "^NAME=\"Moonhead OS\"$" /etc/os-release
  ps -p 1 -o comm= | grep -qx "moonhead-init"
  test -S /run/moonhead/pid1.sock
  grep -q "PARTUUID=c02e0500-0000-4000-8000-000000000002" /proc/cmdline
  grep -q "healthy_slot=A" /mnt/moonhead-state/grubenv
'
guest_sudo 'service sshd status'
guest_sudo 'sh -c "echo qualification-v1 > /mnt/data/qualification-marker"'
guest 'test -s /mnt/data/qualification-marker'

echo "[2/5] Verifying persistent state across reboot..."
graceful_stop
start_qemu
wait_for_ssh "${QEMU_TIMEOUT_SECONDS}"
guest 'grep -qx qualification-v1 /mnt/data/qualification-marker'
guest 'grep -q "slot=A" /mnt/moonhead-state/grubenv'

echo "[3/5] Applying signed update to slot B..."
sshpass -e scp \
  -P "${QEMU_SSH_PORT}" \
  -o BatchMode=no \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -r "${UPDATE_DIR}" admin@127.0.0.1:/tmp/moonhead-update
guest_sudo 'moonhead-update /tmp/moonhead-update'
guest 'grep -q "slot=B" /mnt/moonhead-state/grubenv'
guest 'grep -q "boot_pending=1" /mnt/moonhead-state/grubenv'

echo "[4/5] Simulating an unreadable B slot..."
graceful_stop
ROOT_B_START=$(sgdisk -i 4 "${TEST_IMAGE}" |
  awk '/First sector:/ {print $3}')
if [[ ! "${ROOT_B_START}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: could not determine B-slot start sector." >&2
  exit 1
fi
dd if=/dev/urandom of="${TEST_IMAGE}" bs=512 \
  seek="${ROOT_B_START}" count=8 conv=notrunc status=none

for attempt in 1 2; do
  echo "  Corrupted B-slot boot attempt ${attempt}/2..."
  start_qemu
  expect_no_ssh 35
  stop_qemu
done

echo "[5/5] Verifying automatic rollback to healthy slot A..."
start_qemu
wait_for_ssh "${QEMU_TIMEOUT_SECONDS}"
guest '
  set -eu
  grep -q "PARTUUID=c02e0500-0000-4000-8000-000000000002" /proc/cmdline
  grep -q "slot=A" /mnt/moonhead-state/grubenv
  grep -q "healthy_slot=A" /mnt/moonhead-state/grubenv
  grep -q "boot_pending=0" /mnt/moonhead-state/grubenv
  grep -qx qualification-v1 /mnt/data/qualification-marker
'

echo "PASS: ARM64 boot, password SSH, persistence, signed update, and rollback qualified"
