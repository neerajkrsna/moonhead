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

DEB_FILE=$(find "${BUILD_DIR}/debs" -maxdepth 1 -name 'moonhead-init_*.deb' | sort -V | tail -n 1)
if [[ -z "${DEB_FILE}" || ! -f "${DEB_FILE}" ]]; then
  echo "ERROR: moonhead-init .deb not found in ${BUILD_DIR}/debs (run 'make pid1' first)" >&2
  exit 1
fi
DEB_BASENAME=$(basename "${DEB_FILE}")

if [[ -n "${SSH_PUBKEY_FILE:-}" && ! -f "${SSH_PUBKEY_FILE}" ]]; then
  echo "ERROR: SSH_PUBKEY_FILE does not exist: ${SSH_PUBKEY_FILE}" >&2
  exit 1
fi
if [[ -n "${SSH_PUBKEY_FILE:-}" ]] &&
   ! grep -Eq '^(ssh-ed25519|ecdsa-sha2-nistp[0-9]+|ssh-rsa|sk-ssh-ed25519|sk-ecdsa-sha2-nistp256) ' \
  "${SSH_PUBKEY_FILE}"; then
  echo "ERROR: SSH_PUBKEY_FILE is not a supported OpenSSH public key." >&2
  exit 1
fi

rm -rf "${ROOTFS_DIR}"
mkdir -p "${ROOTFS_DIR}"

echo "[1/3] Assembling hardened zero-systemd rootfs via mmdebstrap (--variant=apt)..."
# shellcheck disable=SC2016,SC2097,SC2098
ADMIN_USER="${ADMIN_USER}" ADMIN_PASSWORD="${ADMIN_PASSWORD}" mmdebstrap \
  --variant=apt \
  --components=main,universe \
  --arch="${ARCH}" \
  --include="${PACKAGES}" \
  --customize-hook="copy-in ${DEB_FILE} /tmp/" \
  --customize-hook="chroot \"\$1\" dpkg -i \"/tmp/${DEB_BASENAME}\" && rm -f \"\$1/tmp/${DEB_BASENAME}\"" \
  --customize-hook='ln -sf /sbin/moonhead-init "$1/sbin/init"' \
  --customize-hook='mkdir -p "$1/mnt/data" "$1/mnt/moonhead-state" "$1/mnt/moonhead-esp" "$1/home" "$1/usr/local/sbin" "$1/etc/apt/preferences.d" "$1/etc/moonhead/services" "$1/etc/ssh/sshd_config.d" "$1/etc/sudoers.d"' \
  --customize-hook='printf "#!/bin/sh\nexit 101\n" > "$1/usr/sbin/policy-rc.d" && chmod 755 "$1/usr/sbin/policy-rc.d"' \
  --customize-hook='printf "Package: systemd systemd-sysv libsystemd-shared libpam-systemd\nPin: release *\nPin-Priority: -1\n" > "$1/etc/apt/preferences.d/no-systemd"' \
  --customize-hook='chroot "$1" apt-get update && DEBIAN_FRONTEND=noninteractive chroot "$1" apt-get install -y --no-install-recommends openssh-server systemd-standalone-sysusers chrony' \
  --customize-hook='printf "#!/bin/sh\ncase \"\$*\" in *-r*) kill -INT 1 ;; *) kill -TERM 1 ;; esac\n" > "$1/usr/local/sbin/shutdown"' \
  --customize-hook='printf "#!/bin/sh\nkill -INT 1\n" > "$1/usr/local/sbin/reboot"' \
  --customize-hook='printf "#!/bin/sh\nkill -TERM 1\n" > "$1/usr/local/sbin/poweroff"' \
  --customize-hook='chmod 755 "$1/usr/local/sbin/shutdown" "$1/usr/local/sbin/reboot" "$1/usr/local/sbin/poweroff"' \
  --customize-hook='cat << "HOOK" > "$1/usr/local/sbin/moonhead-udhcpc-hook"
#!/bin/sh
case "$1" in
  deconfig)
    ip addr flush dev "$interface"
    ;;
  bound|renew)
    ip addr replace "$ip/$mask" dev "$interface"
    [ -n "$router" ] && ip route replace default via "$router" dev "$interface"
    if [ -n "$dns" ]; then
      mkdir -p /run/moonhead
      : > /run/moonhead/resolv.conf
      for ns in $dns; do
        echo "nameserver $ns" >> /run/moonhead/resolv.conf
      done
    fi
    ;;
esac
HOOK
chmod 755 "$1/usr/local/sbin/moonhead-udhcpc-hook"' \
  --customize-hook='cat << "HOOK" > "$1/etc/moonhead/services/dhcp.toml"
name = "dhcp"
exec = "/bin/sh"
args = ["-c", "ip route show default | grep -q . && exec sleep infinity; IFACE=$(ls /sys/class/net | grep -v \"^lo$\" | head -n1); [ -n \"$IFACE\" ] && exec /bin/busybox udhcpc -f -i \"$IFACE\" -s /usr/local/sbin/moonhead-udhcpc-hook"]
cgroup = "foreground"
restart = true
HOOK' \
  --customize-hook='chroot "$1" ssh-keygen -A' \
  --customize-hook='printf "PermitRootLogin no\nPubkeyAuthentication yes\nPasswordAuthentication yes\nKbdInteractiveAuthentication no\nUseDNS no\n" > "$1/etc/ssh/sshd_config.d/99-moonhead.conf"' \
  --customize-hook='printf "name = \"sshd\"\nexec = \"/bin/sh\"\nargs = [\"-c\", \"mkdir -p /run/sshd && chmod 0755 /run/sshd && exec /usr/sbin/sshd -D\"]\ncgroup = \"foreground\"\nrestart = true\n" > "$1/etc/moonhead/services/sshd.toml"' \
  --customize-hook='printf "name = \"chronyd\"\nexec = \"/usr/sbin/chronyd\"\nargs = [\"-d\"]\ncgroup = \"batch\"\nrestart = true\n" > "$1/etc/moonhead/services/chronyd.toml"' \
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
  --customize-hook='printf "name = \"nftables\"\nexec = \"/usr/sbin/nft\"\nargs = [\"-f\", \"/etc/nftables.conf\"]\ncgroup = \"foreground\"\nrestart = false\n" > "$1/etc/moonhead/services/nftables.toml"' \
  --customize-hook="chroot \"\$1\" useradd -m -s /bin/bash -G sudo,adm \"${ADMIN_USER}\"" \
  --customize-hook='printf "%s:%s\n" "$ADMIN_USER" "$ADMIN_PASSWORD" | chroot "$1" chpasswd' \
  --customize-hook="printf \"%sudo ALL=(ALL:ALL) ALL\n\" > \"\$1/etc/sudoers.d/90-moonhead-admin\" && chmod 0440 \"\$1/etc/sudoers.d/90-moonhead-admin\"" \
  --customize-hook='echo "moonhead" > "$1/etc/hostname"' \
  --customize-hook='printf "127.0.0.1\tlocalhost\n127.0.1.1\tmoonhead\n" > "$1/etc/hosts"' \
  --customize-hook='printf "NAME=\"Moonhead OS\"\nVERSION=\"7.3.4\"\nVERSION_ID=\"7.3.4\"\nID=moonhead\nID_LIKE=debian\n" > "$1/etc/os-release"' \
  --customize-hook='chroot "$1" passwd -l root' \
  --customize-hook='rm -f "$1/etc/resolv.conf" && ln -sf /run/moonhead/resolv.conf "$1/etc/resolv.conf"' \
  "${SUITE}" "${ROOTFS_DIR}" "${MIRROR}"

if [[ -n "${SSH_PUBKEY_FILE:-}" && -f "${SSH_PUBKEY_FILE}" ]]; then
  echo "Injecting SSH public key from ${SSH_PUBKEY_FILE} for user '${ADMIN_USER}'..."
  mkdir -p "${ROOTFS_DIR}/home/${ADMIN_USER}/.ssh"
  cp "${SSH_PUBKEY_FILE}" "${ROOTFS_DIR}/home/${ADMIN_USER}/.ssh/authorized_keys"
  chmod 0700 "${ROOTFS_DIR}/home/${ADMIN_USER}/.ssh"
  chmod 0600 "${ROOTFS_DIR}/home/${ADMIN_USER}/.ssh/authorized_keys"
  chroot "${ROOTFS_DIR}" chown -R "${ADMIN_USER}:${ADMIN_USER}" "/home/${ADMIN_USER}/.ssh"
fi
if [[ -n "${UPDATE_PUBLIC_KEY_FILE:-}" ]]; then
  if [[ ! -f "${UPDATE_PUBLIC_KEY_FILE}" ]]; then
    echo "ERROR: UPDATE_PUBLIC_KEY_FILE does not exist: ${UPDATE_PUBLIC_KEY_FILE}" >&2
    exit 1
  fi
  if ! openssl pkey -pubin -in "${UPDATE_PUBLIC_KEY_FILE}" -noout >/dev/null 2>&1; then
    echo "ERROR: UPDATE_PUBLIC_KEY_FILE is not an OpenSSL public key." >&2
    exit 1
  fi
  mkdir -p "${ROOTFS_DIR}/etc/moonhead"
  cp "${UPDATE_PUBLIC_KEY_FILE}" "${ROOTFS_DIR}/etc/moonhead/update-public-key.pem"
  chmod 0644 "${ROOTFS_DIR}/etc/moonhead/update-public-key.pem"
fi

echo "[2/3] Verifying zero systemd packages in dpkg database..."
# shellcheck disable=SC2016
if chroot "${ROOTFS_DIR}" dpkg-query -W -f='${Package}\n' | grep -qE '^(systemd|dbus)$'; then
  echo "ERROR: systemd or dbus leaked into rootfs!" >&2
  exit 1
fi

echo "[3/3] Packing immutable erofs rootfs image..."
ROOTFS_IMAGE="${BUILD_DIR}/rootfs-${ARCH}.erofs"
rm -f "${BUILD_DIR}/rootfs.erofs"
mkfs.erofs -zlz4hc "${ROOTFS_IMAGE}" "${ROOTFS_DIR}"
chmod 0644 "${ROOTFS_IMAGE}"
echo "Built ${ROOTFS_IMAGE} ($(du -h "${ROOTFS_IMAGE}" | cut -f1))"
