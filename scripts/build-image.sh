#!/usr/bin/env bash
set -euo pipefail

ARCH="${ARCH:-arm64}"
SUITE="${SUITE:-resolute}"
MIRROR="${MIRROR:-http://ports.ubuntu.com/ubuntu-ports}"
BUILD_DIR="${BUILD_DIR:-./build/${ARCH}}"
ROOTFS_DIR="${BUILD_DIR}/rootfs"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
if [[ -z "${ADMIN_PASSWORD}" ]]; then
  if [[ ! -t 0 ]]; then
    echo "ERROR: Set ADMIN_PASSWORD or run interactively to enter it." >&2
    exit 1
  fi
  read -r -s -p "Password for ${ADMIN_USER}: " ADMIN_PASSWORD
  echo >&2
fi
if [[ -z "${ADMIN_PASSWORD}" ]]; then
  echo "ERROR: ADMIN_PASSWORD must not be empty." >&2
  exit 1
fi
if [[ "${ADMIN_PASSWORD}" == *$'\n'* || "${ADMIN_PASSWORD}" == *$'\r'* ]]; then
  echo "ERROR: ADMIN_PASSWORD must not contain newlines." >&2
  exit 1
fi
PACKAGES=$(paste -sd, ./profiles/base.packages)

DEB_FILE=$(find "${BUILD_DIR}/debs" -maxdepth 1 -name 'coreos-pid1_*.deb' | sort -V | tail -n 1)
if [[ -z "${DEB_FILE}" || ! -f "${DEB_FILE}" ]]; then
  echo "ERROR: coreos-pid1 .deb not found in ${BUILD_DIR}/debs (run 'make pid1' first)" >&2
  exit 1
fi
DEB_BASENAME=$(basename "${DEB_FILE}")

if [[ -z "${SSH_PUBKEY_FILE:-}" ]]; then
  for candidate in "${HOME}/.ssh/id_ed25519.pub" "${HOME}/.ssh/id_rsa.pub"; do
    if [[ -f "${candidate}" ]]; then
      SSH_PUBKEY_FILE="${candidate}"
      break
    fi
  done
fi

rm -rf "${ROOTFS_DIR}"
mkdir -p "${ROOTFS_DIR}"

echo "[1/3] Assembling production zero-systemd rootfs via mmdebstrap (--variant=apt)..."
ADMIN_USER="${ADMIN_USER}" ADMIN_PASSWORD="${ADMIN_PASSWORD}" mmdebstrap \
  --variant=apt \
  --components=main,universe \
  --arch="${ARCH}" \
  --include="${PACKAGES}" \
  --customize-hook="copy-in ${DEB_FILE} /tmp/" \
  --customize-hook="chroot \"\$1\" dpkg -i \"/tmp/${DEB_BASENAME}\" && rm -f \"\$1/tmp/${DEB_BASENAME}\"" \
  --customize-hook='ln -sf /sbin/coreos-pid1 "$1/sbin/init"' \
  --customize-hook='mkdir -p "$1/mnt/data" "$1/home" "$1/usr/local/sbin" "$1/etc/apt/preferences.d" "$1/etc/coreos/services" "$1/etc/ssh/sshd_config.d" "$1/etc/sudoers.d"' \
  --customize-hook='printf "#!/bin/sh\nexit 101\n" > "$1/usr/sbin/policy-rc.d" && chmod 755 "$1/usr/sbin/policy-rc.d"' \
  --customize-hook='printf "Package: systemd systemd-sysv libsystemd-shared libpam-systemd\nPin: release *\nPin-Priority: -1\n" > "$1/etc/apt/preferences.d/no-systemd"' \
  --customize-hook='chroot "$1" apt-get update && DEBIAN_FRONTEND=noninteractive chroot "$1" apt-get install -y --no-install-recommends openssh-server systemd-standalone-sysusers chrony' \
  --customize-hook='printf "#!/bin/sh\ncase \"\$*\" in *-r*) kill -INT 1 ;; *) kill -TERM 1 ;; esac\n" > "$1/usr/local/sbin/shutdown"' \
  --customize-hook='printf "#!/bin/sh\nkill -INT 1\n" > "$1/usr/local/sbin/reboot"' \
  --customize-hook='printf "#!/bin/sh\nkill -TERM 1\n" > "$1/usr/local/sbin/poweroff"' \
  --customize-hook='chmod 755 "$1/usr/local/sbin/shutdown" "$1/usr/local/sbin/reboot" "$1/usr/local/sbin/poweroff"' \
  --customize-hook='cat << "HOOK" > "$1/usr/local/sbin/coreos-install"
#!/usr/bin/env bash
set -euo pipefail

TARGET_DEV="${1:-}"
if [[ -z "${TARGET_DEV}" || ! -b "${TARGET_DEV}" ]]; then
  echo "Usage: sudo coreos-install <block-device>   (e.g., /dev/sda or /dev/nvme0n1)" >&2
  echo "Available disks:" >&2
  lsblk -d -o NAME,SIZE,MODEL,TYPE 2>/dev/null || ls -l /dev/sd* /dev/nvme* /dev/vd* 2>/dev/null || true
  exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: coreos-install must be run as root (use sudo)." >&2
  exit 1
fi

case "$(uname -m)" in
  aarch64) EFI_BOOT_NAME="BOOTAA64.EFI" ;;
  *)       EFI_BOOT_NAME="BOOTX64.EFI" ;;
esac

ISO_MNT=""
for candidate in /mnt/iso /run/initramfs/live /media/cdrom; do
  if [[ -f "${candidate}/live/rootfs.erofs" ]]; then
    ISO_MNT="${candidate}"
    break
  fi
done

if [[ -z "${ISO_MNT}" ]]; then
  mkdir -p /mnt/coreos-iso
  for dev in /dev/sr* /dev/sd* /dev/nvme*p* /dev/vd*; do
    [[ -b "${dev}" ]] || continue
    if mount -t iso9660 -o ro "${dev}" /mnt/coreos-iso 2>/dev/null; then
      if [[ -f /mnt/coreos-iso/live/rootfs.erofs ]]; then
        ISO_MNT="/mnt/coreos-iso"
        break
      fi
      umount /mnt/coreos-iso
    fi
  done
fi

if [[ -z "${ISO_MNT}" ]]; then
  echo "ERROR: Could not locate live ISO media containing /live/rootfs.erofs." >&2
  exit 1
fi

part_path() {
  if [[ "$1" =~ [0-9]$ ]]; then
    echo "${1}p${2}"
  else
    echo "${1}${2}"
  fi
}

echo "[1/4] Partitioning ${TARGET_DEV} (GPT: COREOS_ESP + COREOS_ROOT + COREOS_DATA)..."
sgdisk --zap-all "${TARGET_DEV}" >/dev/null
ROOT_BYTES=$(stat -c%s "${ISO_MNT}/live/rootfs.erofs")
ROOT_MIB=$(( (ROOT_BYTES + 1048575) / 1048576 + 16 ))

sgdisk -n 1:2048:+64M             -t 1:EF00 -c 1:COREOS_ESP  "${TARGET_DEV}" >/dev/null
sgdisk -n 2:0:+${ROOT_MIB}M       -t 2:8300 -c 2:COREOS_ROOT "${TARGET_DEV}" >/dev/null
sgdisk -n 3:0:0                   -t 3:8300 -c 3:COREOS_DATA "${TARGET_DEV}" >/dev/null
partprobe "${TARGET_DEV}" 2>/dev/null || blockdev --rereadpt "${TARGET_DEV}" 2>/dev/null || true
sleep 1

P1=$(part_path "${TARGET_DEV}" 1)
P2=$(part_path "${TARGET_DEV}" 2)
P3=$(part_path "${TARGET_DEV}" 3)

echo "[2/4] Formatting EFI System Partition (${P1}) and writing kernel + bootloader..."
mkfs.vfat -F 32 -n "COREOS_ESP" "${P1}" >/dev/null
mmd -i "${P1}" ::/EFI ::/EFI/BOOT
mcopy -i "${P1}" "${ISO_MNT}/live/disk-boot.efi" "::/EFI/BOOT/${EFI_BOOT_NAME}"
mcopy -i "${P1}" "${ISO_MNT}/live/vmlinuz" ::/vmlinuz

echo "[3/4] Writing immutable erofs rootfs to ${P2}..."
dd if="${ISO_MNT}/live/rootfs.erofs" of="${P2}" bs=4M conv=fsync status=progress

echo "[4/4] Formatting full-disk persistent COREOS_DATA partition (${P3})..."
mkfs.ext4 -F -L "COREOS_DATA" "${P3}" >/dev/null

echo ""
echo "CORE-OS installed cleanly to ${TARGET_DEV}."
echo "Disconnect/eject the ISO image and run: sudo reboot"
HOOK
chmod 755 "$1/usr/local/sbin/coreos-install"' \
  --customize-hook='cat << "HOOK" > "$1/usr/local/sbin/coreos-udhcpc-hook"
#!/bin/sh
case "$1" in
  deconfig)
    ip addr flush dev "$interface"
    ;;
  bound|renew)
    ip addr replace "$ip/$mask" dev "$interface"
    [ -n "$router" ] && ip route replace default via "$router" dev "$interface"
    if [ -n "$dns" ]; then
      mkdir -p /run/coreos
      : > /run/coreos/resolv.conf
      for ns in $dns; do
        echo "nameserver $ns" >> /run/coreos/resolv.conf
      done
    fi
    ;;
esac
HOOK
chmod 755 "$1/usr/local/sbin/coreos-udhcpc-hook"' \
  --customize-hook='cat << "HOOK" > "$1/etc/coreos/services/dhcp.toml"
name = "dhcp"
exec = "/bin/sh"
args = ["-c", "ip route show default | grep -q . && exec sleep infinity; IFACE=$(ls /sys/class/net | grep -v \"^lo$\" | head -n1); [ -n \"$IFACE\" ] && exec /bin/busybox udhcpc -f -i \"$IFACE\" -s /usr/local/sbin/coreos-udhcpc-hook"]
cgroup = "foreground"
restart = true
HOOK' \
  --customize-hook='chroot "$1" ssh-keygen -A' \
  --customize-hook='printf "PermitRootLogin no\nPubkeyAuthentication yes\nPasswordAuthentication yes\nUseDNS no\n" > "$1/etc/ssh/sshd_config.d/99-coreos.conf"' \
  --customize-hook='printf "name = \"sshd\"\nexec = \"/bin/sh\"\nargs = [\"-c\", \"mkdir -p /run/sshd && chmod 0755 /run/sshd && exec /usr/sbin/sshd -D\"]\ncgroup = \"foreground\"\nrestart = true\n" > "$1/etc/coreos/services/sshd.toml"' \
  --customize-hook='printf "name = \"chronyd\"\nexec = \"/usr/sbin/chronyd\"\nargs = [\"-d\"]\ncgroup = \"batch\"\nrestart = true\n" > "$1/etc/coreos/services/chronyd.toml"' \
  --customize-hook='cat << "HOOK" > "$1/etc/nftables.conf"
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    iif "lo" accept
    ct state established,related accept
    ip protocol icmp accept
    ip6 nexthdr ipv6-icmp accept
    tcp dport 22 accept
  }
  chain forward {
    type filter hook forward priority 0; policy drop;
  }
  chain output {
    type filter hook output priority 0; policy accept;
  }
}
HOOK
chmod 755 "$1/etc/nftables.conf"' \
  --customize-hook='printf "name = \"nftables\"\nexec = \"/usr/sbin/nft\"\nargs = [\"-f\", \"/etc/nftables.conf\"]\ncgroup = \"foreground\"\nrestart = false\n" > "$1/etc/coreos/services/nftables.toml"' \
  --customize-hook="chroot \"\$1\" useradd -m -s /bin/bash -G sudo,adm \"${ADMIN_USER}\"" \
  --customize-hook='printf "%s:%s\n" "$ADMIN_USER" "$ADMIN_PASSWORD" | chroot "$1" chpasswd' \
  --customize-hook="printf \"${ADMIN_USER} ALL=(ALL) NOPASSWD:ALL\n\" > \"\$1/etc/sudoers.d/90-coreos-admin\" && chmod 0440 \"\$1/etc/sudoers.d/90-coreos-admin\"" \
  --customize-hook='echo "coreos" > "$1/etc/hostname"' \
  --customize-hook='printf "127.0.0.1\tlocalhost\n127.0.1.1\tcoreos\n" > "$1/etc/hosts"' \
  --customize-hook='printf "NAME=\"CORE-OS\"\nVERSION=\"7.3-lts\"\nID=coreos\nID_LIKE=debian\n" > "$1/etc/os-release"' \
  --customize-hook='chroot "$1" passwd -d root' \
  --customize-hook='rm -f "$1/etc/resolv.conf" && ln -sf /run/coreos/resolv.conf "$1/etc/resolv.conf"' \
  "${SUITE}" "${ROOTFS_DIR}" "${MIRROR}"

if [[ -n "${SSH_PUBKEY_FILE:-}" && -f "${SSH_PUBKEY_FILE}" ]]; then
  echo "Injecting SSH public key from ${SSH_PUBKEY_FILE} for user '${ADMIN_USER}'..."
  mkdir -p "${ROOTFS_DIR}/home/${ADMIN_USER}/.ssh"
  cp "${SSH_PUBKEY_FILE}" "${ROOTFS_DIR}/home/${ADMIN_USER}/.ssh/authorized_keys"
  chmod 0700 "${ROOTFS_DIR}/home/${ADMIN_USER}/.ssh"
  chmod 0600 "${ROOTFS_DIR}/home/${ADMIN_USER}/.ssh/authorized_keys"
  chroot "${ROOTFS_DIR}" chown -R "${ADMIN_USER}:${ADMIN_USER}" "/home/${ADMIN_USER}/.ssh"
fi

echo "[2/3] Verifying zero systemd packages in dpkg database..."
if chroot "${ROOTFS_DIR}" dpkg-query -W -f='${Package}\n' | grep -qE '^(systemd|dbus)$'; then
  echo "ERROR: systemd or dbus leaked into rootfs!" >&2
  exit 1
fi

echo "[3/3] Packing immutable erofs rootfs image..."
mkfs.erofs -zlz4hc "${BUILD_DIR}/rootfs.erofs" "${ROOTFS_DIR}"
echo "Built ${BUILD_DIR}/rootfs.erofs ($(du -h "${BUILD_DIR}/rootfs.erofs" | cut -f1))"
