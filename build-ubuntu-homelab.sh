#!/usr/bin/env bash
set -euo pipefail

# ======================================================
# Konfig (kannst du oben im Script anpassen oder via ENV)
# ======================================================
UBU_VERSION="${UBU_VERSION:-24.04}"
ISO_URL="${ISO_URL:-https://releases.ubuntu.com/${UBU_VERSION}/ubuntu-${UBU_VERSION}-live-server-amd64.iso}"
ISO_NAME="ubuntu-${UBU_VERSION}-live-server-amd64.iso"

WORKDIR="${WORKDIR:-$HOME/iso-work}"
MOUNTDIR="${MOUNTDIR:-$HOME/iso-mount}"
OUT_ISO="${OUT_ISO:-$HOME/ubuntu-homelab-${UBU_VERSION}.iso}"
VOLID="${VOLID:-UBUNTU-HOMELAB}"

# Identity-Defaults (im TUI änderbar)
DEF_HOSTNAME="${DEF_HOSTNAME:-homelab}"
DEF_USERNAME="${DEF_USERNAME:-admin}"

# Netzwerk-Defaults (im TUI änderbar)
# Wenn IFACE leer bleibt -> DHCP-Default, Interface wählst du im TUI.
IFACE="${IFACE:-}"                 # z.B. enp3s0
DEF_ADDRESS="${DEF_ADDRESS:-192.168.1.50/24}"
DEF_GATEWAY="${DEF_GATEWAY:-192.168.1.1}"
DEF_NAMESERVERS="${DEF_NAMESERVERS:-[192.168.1.1,1.1.1.1]}"
DEF_SEARCHDOMAINS="${DEF_SEARCHDOMAINS:-[lan]}"

# Pakete für Homeserver/NAS
EXTRA_PACKAGES=(
  # Virtualisierung/Container/Storage
  qemu-kvm qemu-utils libvirt-daemon-system bridge-utils
  lxd
  zfsutils-linux zfs-auto-snapshot
  docker.io docker-compose-plugin

  # NAS-Services
  samba nfs-kernel-server

  # Netzwerk/Management
  network-manager avahi-daemon libnss-mdns

  # Monitoring/Hardware
  smartmontools nvme-cli lm-sensors htop

  # Sicherheit/Updates
  unattended-upgrades fail2ban ufw

  # Komfort
  curl git jq ca-certificates
)

# USB-Parameter
USB_DEVICE="${1:-}"     # z.B. /dev/sdb oder leer
FORCE="${2:-}"          # --force zum Überspringen der YES-Abfrage

# ======================================================
# Vorbereitungs-Checks
# ======================================================
need() { command -v "$1" >/dev/null 2>&1 || { echo "Fehlend: $1"; MISSING=1; }; }
MISSING=0
need xorriso
need wget
need sudo
# Für Hybrid-ISO (ältere/kompatible Pfade)
need isohybrid || true
if (( MISSING )); then
  echo "Bitte installiere fehlende Tools, z.B.: sudo apt update && sudo apt install -y xorriso isolinux syslinux-utils wget"
  exit 1
fi

mkdir -p "$WORKDIR" "$MOUNTDIR"

# ======================================================
# ISO herunterladen
# ======================================================
if [[ ! -f "$ISO_NAME" ]]; then
  echo "Lade Ubuntu ISO: $ISO_URL"
  wget -O "$ISO_NAME" "$ISO_URL"
fi

# ======================================================
# ISO entpacken
# ======================================================
echo "Entpacke ISO nach $WORKDIR ..."
sudo umount "$MOUNTDIR" 2>/dev/null || true
sudo mount -o loop "$ISO_NAME" "$MOUNTDIR"
rm -rf "$WORKDIR"/*
cp -aT "$MOUNTDIR" "$WORKDIR"
sudo umount "$MOUNTDIR"

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

  # Diese Sektionen bleiben interaktiv -> Defaults unten sind nur Startwerte
  echo "  interactive-sections:"
  echo "    - identity"
  echo "    - network"
  echo "    - storage"

  # Identity-Defaults (Passwort ABSICHTLICH nicht gesetzt -> wird im TUI abgefragt)
  echo "  identity:"
  echo "    hostname: ${DEF_HOSTNAME}"
  echo "    username: ${DEF_USERNAME}"

  # Pakete
  echo "  packages:"
  for p in "${EXTRA_PACKAGES[@]}"; do echo "    - $p"; done

  # Netplan-Renderer NetworkManager (Defaults folgen darunter)
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
      # DHCP als Startwert; Interface wählst du im TUI
      default:
        dhcp4: true
EOF
fi

# Late-Commands: Dienste aktivieren, Auto-Updates (wöchentlich So 02:00), mDNS
cat >> "$USER_DATA" <<'EOF'

  late-commands:
    # Nutzergruppen
    - curtin in-target -- /usr/bin/usermod -aG libvirt,lxd,libvirt-qemu,kvm ${DEF_USERNAME}

    # NetworkManager aktivieren und alles managen lassen
    - curtin in-target -- /usr/bin/systemctl enable --now NetworkManager
    - curtin in-target -- /bin/bash -c 'mkdir -p /etc/NetworkManager/conf.d; echo -e "[keyfile]\nunmanaged-devices=none" > /etc/NetworkManager/conf.d/manage-all.conf || true'
    - curtin in-target -- /usr/bin/systemctl reload NetworkManager || true

    # Standarddienste aktivieren
    - curtin in-target -- /usr/bin/systemctl enable --now docker || true
    - curtin in-target -- /usr/bin/systemctl enable --now smbd nmbd || true
    - curtin in-target -- /usr/bin/systemctl enable --now nfs-server || true
    - curtin in-target -- /usr/bin/virsh net-autostart default || true
    - curtin in-target -- /usr/bin/virsh net-start default || true

    # SMART-Monitoring
    - curtin in-target -- /usr/bin/systemctl enable --now smartd || true

    # Unattended-Upgrades: wöchentlich, Reboot bei Bedarf um 02:00
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

    # Systemd-Timer so umbauen, dass Upgrades sonntags 02:00 laufen
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

    # Avahi/mDNS aktivieren + Standard-Dienste veröffentlichen
    - curtin in-target -- /usr/bin/systemctl enable --now avahi-daemon

    # SSH über mDNS announcen
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

    # Samba (SMB) über mDNS announcen
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

    # NFS über mDNS announcen
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

    # Firewall (UFW): mDNS erlauben; SSH offen (SMB/NFS kannst du nach Bedarf ergänzen)
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

# ======================================================
# ISO neu bauen
# ======================================================
echo "Baue neue ISO: $OUT_ISO"
pushd "$WORKDIR" >/dev/null
xorriso -as mkisofs \
  -r -V "$VOLID" \
  -o "$OUT_ISO" \
  -J -l -iso-level 3 -cache-inodes \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -partition_offset 16 \
  -b isolinux/isolinux.bin -c isolinux/boot.cat \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e boot/grub/efi.img -no-emul-boot \
  .
popd >/dev/null

echo "Fertig: $OUT_ISO"

# ======================================================
# Optional: direkt auf USB schreiben
# ======================================================
if [[ -n "$USB_DEVICE" ]]; then
  if [[ ! -b "$USB_DEVICE" ]]; then
    echo "Fehler: $USB_DEVICE ist kein Blockgerät."
    exit 1
  fi

  # kleine Sicherheit: Wechseldatenträger?
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

  sudo dd if="$OUT_ISO" of="$USB_DEVICE" bs=4M status=progress oflag=sync
  sync
  echo "USB-Stick ist bereit."
fi
