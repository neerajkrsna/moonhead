#!/usr/bin/env bash
set -euo pipefail

STATE_DIR=/mnt/moonhead-state
LOG_FILE=/mnt/data/boot-success.log
mkdir -p /mnt/data
exec >> "${LOG_FILE}" 2>&1
echo "[$(date -Iseconds)] checking slot health"
mkdir -p "${STATE_DIR}"
STATE_DEV=$(findfs PARTLABEL=MOONHEAD_STATE 2>/dev/null || true)
if [[ -z "${STATE_DEV}" ]]; then
  echo "[moonhead] no installed A/B state partition; leaving live boot unmodified"
  exit 0
fi
if ! findmnt -rn "${STATE_DIR}" >/dev/null; then
  mount -t ext4 "${STATE_DEV}" "${STATE_DIR}"
fi

CMDLINE=$(cat /proc/cmdline)
case "${CMDLINE}" in
  *PARTUUID=c02e0500-0000-4000-8000-000000000002*) SLOT=A ;;
  *PARTUUID=c02e0500-0000-4000-8000-000000000004*) SLOT=B ;;
  *) echo "ERROR: cannot determine active Moonhead OS slot." >&2; exit 1 ;;
esac

READY=0
for _ in $(seq 1 30); do
  if [[ -S /run/moonhead/pid1.sock ]] && pgrep -x sshd >/dev/null; then
    READY=1
    break
  fi
  sleep 1
done
if [[ "${READY}" -ne 1 ]]; then
  echo "ERROR: PID 1 or sshd did not become ready; preserving rollback state." >&2
  exit 1
fi
echo "[$(date -Iseconds)] slot ${SLOT} is healthy"

grub-editenv "${STATE_DIR}/grubenv" set \
  "healthy_slot=${SLOT}" \
  "slot=${SLOT}" \
  boot_pending=0 \
  boot_attempts=0

PENDING_VERSION=$(grub-editenv "${STATE_DIR}/grubenv" list |
  sed -n 's/^pending_version=//p')
if [[ -n "${PENDING_VERSION}" ]]; then
  grub-editenv "${STATE_DIR}/grubenv" set "version=${PENDING_VERSION}"
  grub-editenv "${STATE_DIR}/grubenv" unset pending_version
fi
sync
