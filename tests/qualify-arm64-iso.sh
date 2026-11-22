#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

ISO="${1:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
QEMU_SSH_PORT="${QEMU_SSH_PORT:-2233}"
QEMU_TIMEOUT_SECONDS="${QEMU_TIMEOUT_SECONDS:-180}"
WORK_DIR=$(mktemp -d)
QEMU_PID=
QEMU_LOG="${WORK_DIR}/qemu.log"
TARGET_DISK="${WORK_DIR}/installed.img"

usage() {
  cat <<'EOF'
Usage: ADMIN_PASSWORD=<password> tests/qualify-arm64-iso.sh <installer.iso>

Boots the ARM64 installer ISO, installs Moonhead OS to a blank QEMU disk,
reboots from the installed disk, and verifies password SSH plus A-slot health.
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

if [[ -z "${ISO}" || ! -f "${ISO}" || -z "${ADMIN_PASSWORD}" ]]; then
  usage >&2
  exit 2
fi
for command in qemu-img ssh sshpass; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "ERROR: required command not found: ${command}" >&2
    exit 1
  fi
done

QEMU_BIN="${QEMU_BIN:-qemu-system-aarch64}"
if ! command -v "${QEMU_BIN}" >/dev/null 2>&1; then
  echo "ERROR: required command not found: ${QEMU_BIN}" >&2
  exit 1
fi
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
if [[ -z "${QEMU_CPU:-}" ]]; then
  if [[ "${QEMU_ACCEL}" == "tcg" ]]; then
    QEMU_CPU=max
  else
    QEMU_CPU=host
  fi
fi

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

start_live_qemu() {
  : > "${QEMU_LOG}"
  "${QEMU_BIN}" \
    -M virt -accel "${QEMU_ACCEL}" -cpu "${QEMU_CPU}" -smp 4 -m 2G -nographic \
    -bios "${QEMU_FIRMWARE}" \
    -drive "file=${ISO},format=raw,if=virtio,readonly=on" \
    -drive "file=${TARGET_DISK},format=raw,if=virtio" \
    -netdev "user,id=net0,hostfwd=tcp::${QEMU_SSH_PORT}-:22" \
    -device virtio-net-pci,netdev=net0 \
    > "${QEMU_LOG}" 2>&1 &
  QEMU_PID=$!
}

start_installed_qemu() {
  : > "${QEMU_LOG}"
  "${QEMU_BIN}" \
    -M virt -accel "${QEMU_ACCEL}" -cpu "${QEMU_CPU}" -smp 4 -m 2G -nographic \
    -bios "${QEMU_FIRMWARE}" \
    -drive "file=${TARGET_DISK},format=raw,if=virtio" \
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

wait_for_ssh() {
  local deadline=$((SECONDS + QEMU_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if ! kill -0 "${QEMU_PID}" 2>/dev/null; then
      echo "ERROR: QEMU exited before SSH became available." >&2
      tail -100 "${QEMU_LOG}" >&2
      exit 1
    fi
    if sshpass -e ssh "${SSH_OPTIONS[@]}" admin@127.0.0.1 \
      'test "$(uname -m)" = aarch64' >/dev/null 2>&1; then
      return
    fi
    sleep 2
  done
  echo "ERROR: SSH did not become available." >&2
  tail -100 "${QEMU_LOG}" >&2
  exit 1
}

guest() {
  for _attempt in 1 2 3 4 5; do
    if sshpass -e ssh "${SSH_OPTIONS[@]}" admin@127.0.0.1 "$1"; then
      return 0
    fi
    sleep 2
  done
  echo "ERROR: guest command failed after 5 SSH attempts." >&2
  return 1
}

guest_sudo() {
  for _attempt in 1 2 3 4 5; do
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

qemu-img create -f raw "${TARGET_DISK}" 12G

echo "[1/3] Booting installer ISO..."
start_live_qemu
wait_for_ssh

echo "[2/3] Installing to blank target disk..."
guest_sudo 'moonhead-install --yes-wipe /dev/vdb'
stop_qemu

echo "[3/3] Booting installed system..."
start_installed_qemu
wait_for_ssh
guest '
  set -eu
  grep -q "^NAME=\"Moonhead OS\"$" /etc/os-release
  ps -p 1 -o comm= | grep -qx "moonhead-init"
  test -S /run/moonhead/pid1.sock
  grep -q "PARTUUID=c02e0500-0000-4000-8000-000000000002" /proc/cmdline
  grep -q "healthy_slot=A" /mnt/moonhead-state/grubenv
'

echo "PASS: ARM64 ISO installation and installed A-slot boot qualified"
