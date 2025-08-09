#!/usr/bin/env bash
set -euo pipefail

# ======================================================
# Konfig
# ======================================================
UBU_VERSION="${UBU_VERSION:-24.04.3}"
UBU_RELEASE="${UBU_RELEASE:-noble}"
ISO_URL="${ISO_URL:-https://releases.ubuntu.com/${UBU_RELEASE}/ubuntu-${UBU_VERSION}-live-server-amd64.iso}"
ISO_NAME="ubuntu-${UBU_VERSION}-live-server-amd64.iso"

WORKDIR="${WORKDIR:-$HOME/iso-work}"
MOUNTDIR="${MOUNTDIR:-$HOME/iso-mount}"
OUT_ISO="${OUT_ISO:-$HOME/ubuntu-homelab-${UBU_VERSION}.iso}"
VOLID="${VOLID:-UBUNTU-HOMELAB}"

DEF_HOSTNAME="${DEF_HOSTNAME:-homelab}"
DEF_USERNAME="${DEF_USERNAME:-admin}"

# Netzwerk-Defaults (im TUI änderbar)
IFACE="${IFACE:-}"                 # z.B. enp3s0; leer = DHCP-Default
DEF_ADDRESS="${DEF_ADDRESS:-192.168.1.50/24}"
DEF_GATEWAY="${DEF_GATEWAY:-192.168.1.1}"
DEF_NAMESERVERS="${DEF_NAMESERVERS:-[192.168.1.1,1.1.1.1]}"
DEF_SEARCHDOMAINS="${DEF_SEARCHDOMAINS:-[lan]}"

# Homeserver/NAS-Pakete
EXTRA_PACKAGES=(
  qemu-kvm qemu-utils libvirt-daemon-system bridge-utils
  lxd
  zfsutils-linux zfs-auto-snapshot
  docker.io docker-compose-plugin
  samba nfs-kernel-server
  network-manager avahi-daemon libnss-mdns
  smartmontools nvme-cli lm-sensors htop
  unattended-upgrades fail2ban ufw
  curl git jq ca-certificates
)

# USB-Parameter
USB_DEVICE="${1:-}"     # z.B. /dev/sdb
FORCE="${2:-}"          # --force = ohne Rückfrage schreiben

# SUDO Helper (im Container evtl. nicht vorhanden)
SUDO="sudo"
if [[ $EUID -eq 0 ]]; then SUDO=""; fi

# ======================================================
# Abhängigkeiten sicherstellen (apt)
# ======================================================
ensure_apt() {
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "Dieses Script erwartet ein Debian/Ubuntu-ähnliches System mit apt-get."
    exit 1
  fi
}

ensure_pkgs() {
  local pkgs=("$@")
  local missing=()
  for p in "${pkgs[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if ((${#missing[@]})); then
    echo "Installiere fehlende Pakete: ${missing[*]}"
    $SUDO apt-get update -y
    DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y --no-install-recommends "${missing[@]}"
  fi
}

ensure_apt
# Build-Tooling + Komfort
BUILD_PKGS=(xorriso isolinux syslinux-utils wget ca-certificates libarchive-tools)
ensure_pkgs "${BUILD_PKGS[@]}"

# Werkverzeichnisse
mkdir -p "$WORKDIR" "$MOUNTDIR"

# ======================================================
# ISO holen
# ======================================================
if [[ ! -f "$ISO_NAME" ]]; then
  echo "Lade Ubuntu ISO: $ISO_URL"
  wget -O "$ISO_NAME" "$ISO_URL"
fi

# ======================================================
# ISO entpacken (Mount → Fallback bsdtar)
# ======================================================
echo "Entpacke ISO nach $WORKDIR ..."
rm -rf "$WORKDIR"/*
set +e
$SUDO umount "$MOUNTDIR" 2>/dev/null
$SUDO mount -o loop "$ISO_NAME" "$MOUNTDIR" 2>/dev/null
MOUNT_RC=$?
set -e

if [[ $MOUNT_RC -eq 0 ]]; then
  cp -aT "$MOUNTDIR" "$WORKDIR"
  $SUDO umount "$MOUNTDIR"
else
  echo "Loop-Mount nicht möglich (Container?). Nutze Fallback mit bsdtar."
  # libarchive-tools liefert bsdtar
  bsdtar -C "$WORKDIR" -xf "$ISO_NAME"
fi

# ======================================================
# NoCloud seed einbetten
# ======================================================
mkdir -p "$WORKDIR/nocloud"

cat > "$WORKDIR/nocloud/meta-data" <<'EOF'
instance-id: ubuntu-homelab
EOF

USER_DATA="$WORKDIR/nocloud/user-data"
{
  echo "#cloud-config"
  echo "autoinstall:"
  echo "  version: 1"
  echo "  locale: de_DE.UTF-8"
  echo "  keyboard:"
  echo "    layout: de"
  echo "  timezone: Europe/Berlin"

  echo "  interactive-sections:"
  echo "    - identity"
  echo "    - network"
  echo "    - storage"

  echo "  identity:"
  echo "    hostname: ${DEF_HOSTNAME}"
  echo "    username: ${DEF_USERNAME}"

  echo "  packages:"
  for p in "${EXTRA_PACKAGES[@]}"; do echo "    - $p"; done

  echo "  network:"
  echo "    version: 2"
  echo "    renderer: NetworkManager"
} > "$USER_DATA"

if [[ -n "${IFACE}" ]]; then
  cat >> "$USER_DATA" <<EOF
    ethernets:
      ${IFACE}:
        dhcp4: false
        addresses: [${DEF_ADDRESS}]
        routes:
          - to: default
            via: ${DEF_GATEWAY}
        nameservers:
          addresses: ${DEF_NAMESERVERS}
          search: ${DEF_SEARCHDOMAINS}
EOF
else
  cat >> "$USER_DATA" <<'EOF'
    ethernets:
      default:
        dhcp4: true
EOF
fi

# Late-Commands
cat >> "$USER_DATA" <<'EOF'

  late-commands:
    # Nutzergruppen
    - curtin in-target -- /usr/bin/usermod -aG libvirt,lxd,libvirt-qemu,kvm ${DEF_USERNAME}

    # NetworkManager aktivieren
    - curtin in-target -- /usr/bin/systemctl enable --now NetworkManager
    - curtin in-target -- /bin/bash -c 'mkdir -p /etc/NetworkManager/conf.d; echo -e "[keyfile]\nunmanaged-devices=none" > /etc/NetworkManager/conf.d/manage-all.conf || true'
    - curtin in-target -- /usr/bin/systemctl reload NetworkManager || true

    # Dienste aktivieren
    - curtin in-target -- /usr/bin/systemctl enable --now docker || true
    - curtin in-target -- /usr/bin/systemctl enable --now smbd nmbd || true
    - curtin in-target -- /usr/bin/systemctl enable --now nfs-server || true
    - curtin in-target -- /usr/bin/virsh net-autostart default || true
    - curtin in-target -- /usr/bin/virsh net-start default || true
    - curtin in-target -- /usr/bin/systemctl enable --now smartd || true

    # Unattended-Upgrades: wöchentlich, Reboot 02:00 So
    - curtin in-target -- /usr/bin/dpkg-reconfigure -f noninteractive unattended-upgrades || true
    - curtin in-target -- /bin/bash -c 'cat >/etc/apt/apt.conf.d/20auto-upgrades <<EOT
APT::Periodic::Update-Package-Lists "7";
APT::Periodic::Unattended-Upgrade "7";
APT::Periodic::AutocleanInterval "7";
EOT'
    - curtin in-target -- /bin/bash -c 'sed -i "s#^//\\s*\\\"\\\${distro_id}:\\\${distro_codename}-updates\\\";#\\\"\\\${distro_id}:\\\${distro_codename}-updates\\\";#g" /etc/apt/apt.conf.d/50unattended-upgrades'
    - curtin in-target -- /bin/bash -c 'sed -i "s#^//\\s*\\\"\\\${distro_id}:\\\${distro_codename}-security\\\";#\\\"\\\${distro_id}:\\\${distro_codename}-security\\\";#g" /etc/apt/apt.conf.d/50unattended-upgrades'
    - curtin in-target -- /bin/bash -c 'sed -i "s#^//\\s*Unattended-Upgrade::Automatic-Reboot \"false\";#Unattended-Upgrade::Automatic-Reboot \"true\";#g" /etc/apt/apt.conf.d/50unattended-upgrades'
    - curtin in-target -- /bin/bash -c 'grep -q "^Unattended-Upgrade::Automatic-Reboot-Time" /etc/apt/apt.conf.d/50unattended-upgrades || echo "Unattended-Upgrade::Automatic-Reboot-Time \"02:00\";" >> /etc/apt/apt.conf.d/50unattended-upgrades'

    # Timer → Sonntags 02:00
    - curtin in-target -- /bin/bash -c 'mkdir -p /etc/systemd/system/apt-daily-upgrade.timer.d'
    - curtin in-target -- /bin/bash -c 'cat >/etc/systemd/system/apt-daily-upgrade.timer.d/override.conf <<EOT
[Timer]
OnCalendar=
OnCalendar=Sun 02:00
Persistent=true
RandomizedDelaySec=0
EOT'
    - curtin in-target -- /usr/bin/systemctl daemon-reload
    - curtin in-target -- /usr/bin/systemctl enable --now apt-daily-upgrade.timer

    # Avahi/mDNS
    - curtin in-target -- /usr/bin/systemctl enable --now avahi-daemon
    - curtin in-target -- /bin/bash -c 'mkdir -p /etc/avahi/services; cat >/etc/avahi/services/ssh.service <<EOT
<?xml version="1.0" standalone="no"?><!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">%h SSH</name>
  <service>
    <type>_ssh._tcp</type>
    <port>22</port>
  </service>
</service-group>
EOT'
    - curtin in-target -- /bin/bash -c 'cat >/etc/avahi/services/smb.service <<EOT
<?xml version="1.0" standalone="no"?><!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">%h SMB</name>
  <service>
    <type>_smb._tcp</type>
    <port>445</port>
  </service>
</service-group>
EOT'
    - curtin in-target -- /bin/bash -c 'cat >/etc/avahi/services/nfs.service <<EOT
<?xml version="1.0" standalone="no"?><!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">%h NFS</name>
  <service>
    <type>_nfs._tcp</type>
    <port>2049</port>
  </service>
</service-group>
EOT'
    - curtin in-target -- /usr/bin/systemctl reload avahi-daemon || /usr/bin/systemctl restart avahi-daemon

    # Firewall
    - curtin in-target -- /usr/sbin/ufw allow OpenSSH || true
    - curtin in-target -- /usr/sbin/ufw allow 5353/udp || true
    - curtin in-target -- /usr/sbin/ufw --force enable || true
EOF

# ======================================================
# Bootmenüs patchen (GRUB/BIOS & GRUB/UEFI)
# ======================================================
GRUB_CFG="$WORKDIR/boot/grub/grub.cfg"
if [[ -f "$GRUB_CFG" ]]; then
  echo "Patche $GRUB_CFG ..."
  sed -i 's|\(linux.*\) ---|\1 autoinstall ds=nocloud;s=/cdrom/nocloud/ ---|g' "$GRUB_CFG"
fi
if [[ -f "$WORKDIR/isolinux/txt.cfg" ]]; then
  echo "Patche isolinux/txt.cfg ..."
  sed -i 's|\(append .*\) ---|\1 autoinstall ds=nocloud;s=/cdrom/nocloud/ ---|g' "$WORKDIR/isolinux/txt.cfg"
fi

# Pfad zur isohybrid MBR prüfen (isolinux Paket liefert das)
ISOHDPFX="/usr/lib/ISOLINUX/isohdpfx.bin"
if [[ ! -f "$ISOHDPFX" ]]; then
  echo "Warnung: $ISOHDPFX nicht gefunden. Prüfe, ob 'isolinux' installiert ist."
fi

# ======================================================
# ISO neu bauen
# ======================================================
echo "Baue neue ISO: $OUT_ISO"
pushd "$WORKDIR" >/dev/null
xorriso -as mkisofs \
  -r -V "$VOLID" \
  -o "$OUT_ISO" \
  -J -l -iso-level 3 -cache-inodes \
  -isohybrid-mbr "$ISOHDPFX" \
  -partition_offset 16 \
  -b isolinux/isolinux.bin -c isolinux/boot.cat \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e boot/grub/efi.img -no-emul-boot \
  .
popd >/dev/null

echo "Fertig: $OUT_ISO"

# ======================================================
# Optional: auf USB schreiben
# ======================================================
if [[ -n "$USB_DEVICE" ]]; then
  if [[ ! -b "$USB_DEVICE" ]]; then
    echo "Fehler: $USB_DEVICE ist kein Blockgerät."
    exit 1
  fi

  # Sicherheitshinweis
  RM_FLAG=$(lsblk -no RM "$USB_DEVICE" 2>/dev/null || echo 0)
  if [[ "$RM_FLAG" != "1" ]]; then
    echo "Warnung: $USB_DEVICE wirkt nicht wie ein Wechseldatenträger (RM=$RM_FLAG)."
  fi

  if [[ "$FORCE" == "--force" ]]; then
    echo ">>> Schreibe ISO auf ${USB_DEVICE} (FORCE-Modus, keine Rückfrage) ..."
  else
    echo ">>> ACHTUNG: Schreibe ISO auf ${USB_DEVICE} (ALLE Daten dort gehen verloren!)"
    read -p "Weiter mit dd? Tippe YES in Großbuchstaben: " REPLY
    [[ "$REPLY" == "YES" ]] || { echo "Abgebrochen vor dd."; exit 1; }
  fi

  $SUDO dd if="$OUT_ISO" of="$USB_DEVICE" bs=4M status=progress oflag=sync
  sync
  echo "USB-Stick ist bereit."
fi
