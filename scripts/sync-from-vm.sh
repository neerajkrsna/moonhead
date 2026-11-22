#!/usr/bin/env bash
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VM_HOST="${VM_HOST:-192.168.139.71}"
VM_USER="${VM_USER:-risvai}"
VM_PATH="${VM_PATH:-/home/risvai/core-os}"
SSH_KEY="${SSH_KEY:-}"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: scripts/sync-from-vm.sh [--dry-run]

Synchronizes implementation source from the Moonhead Ubuntu VM into this
repository. Generated artifacts, Git metadata, README, docs, and legacy
design files are never copied.

Environment:
  VM_HOST=192.168.139.71
  VM_USER=risvai
  VM_PATH=/home/risvai/core-os
  SSH_KEY=/path/to/private-key
EOF
}

while (( $# )); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if ! git -C "${REPO_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ERROR: repository not found at ${REPO_DIR}" >&2
  exit 1
fi

SSH_COMMAND=(ssh -o BatchMode=no)
if [[ -n "${SSH_KEY}" ]]; then
  if [[ ! -f "${SSH_KEY}" ]]; then
    echo "ERROR: SSH_KEY does not exist: ${SSH_KEY}" >&2
    exit 1
  fi
  SSH_COMMAND+=(-i "${SSH_KEY}" -o IdentitiesOnly=yes)
fi

echo "Checking ${VM_USER}@${VM_HOST}:${VM_PATH}..."
"${SSH_COMMAND[@]}" "${VM_USER}@${VM_HOST}" \
  "test -d '${VM_PATH}' && test -f '${VM_PATH}/Makefile'"

RSYNC_ARGS=(-a --delete --exclude '._*' --exclude target/ --exclude build/)
if (( DRY_RUN )); then
  RSYNC_ARGS+=(--dry-run --itemize-changes)
fi

sync_dir() {
  local source="$1"
  local destination="$2"
  rsync "${RSYNC_ARGS[@]}" -e "${SSH_COMMAND[*]}" \
    "${VM_USER}@${VM_HOST}:${VM_PATH}/${source}/" \
    "${REPO_DIR}/${destination}/"
}

sync_dir moonhead-ebpf moonhead-ebpf
sync_dir moonhead-init moonhead-init

rsync "${RSYNC_ARGS[@]}" -e "${SSH_COMMAND[*]}" \
  "${VM_USER}@${VM_HOST}:${VM_PATH}/kernel/fragments/" \
  "${REPO_DIR}/kernel/fragments/"
sync_dir profiles profiles
sync_dir scripts scripts
sync_dir tests tests

rsync "${RSYNC_ARGS[@]}" -e "${SSH_COMMAND[*]}" \
  "${VM_USER}@${VM_HOST}:${VM_PATH}/Makefile" \
  "${REPO_DIR}/Makefile"

if (( DRY_RUN )); then
  echo "Dry run complete; no local files were changed."
else
  echo "VM source sync complete."
fi
