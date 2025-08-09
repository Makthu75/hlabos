#!/usr/bin/env bash
set -euo pipefail

# =========================
# Konfig
# =========================
UBU_VERSION="${UBU_VERSION:-24.04.3}"  # z.B. 24.04, 24.04.3
ISO_URL_DEFAULT="https://releases.ubuntu.com/${UBU_VERSION}/ubuntu-${UBU_VERSION}-live-server-amd64.iso"
ISO_URL="${ISO_URL:-$ISO_URL_DEFAULT}"
ISO_NAME="ubuntu-${UBU_VERSION}-live-server-amd64.iso"

WORKDIR="${WORKDIR:-$HOME/iso-work}"
OUT_ISO="${OUT_ISO:-$HOME/ubuntu-homelab-${UBU_VERSION}.iso}"
VOLID="${VOLID:-UBUNTU-HOMELAB}"

# Voreinstellungen (werden im Installer angezeigt, sind aber änderbar)
DEF_LOCALE="${DEF_LOCALE:-de_DE.UTF-8}"
DEF_KEYBOARD_LAYOUT="${DEF_KEYBOARD_LAYOUT:-de}"
DEF_TIMEZONE="${DEF_TIMEZONE:-Europe/Berlin}"
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

SUDO="sudo"; [[ $EUID -eq 0 ]] && SUDO=""

# =========================
# Abhängigkeiten
# =========================
need_apt() { command -v apt-get >/dev/null 2>&1 || { echo "apt-get benötigt"; exit 1; }; }
ensure_pkgs() {
  local miss=()
  for p in "$@"; do dpkg -s "$p" >/dev/null 2>&1 || miss+=("$p"); done
  if ((${#miss[@]})); then
    $SUDO apt-get update -y
    DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y --no-install-recommends "${miss[@]}"
  fi
}
need_apt
# xorriso = Pflicht; p7zip-full = ISO-Dateiliste/Extraktion; wget/ca-certs = Download
ensure_pkgs xorriso p7zip-full wget ca-certificates

mkdir -p "$WORKDIR"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# =========================
# ISO holen (falls nicht schon vorhanden)
# =========================
if [[ -f "$ISO_NAME" ]]; then
  echo "ISO vorhanden, überspringe Download: $ISO_NAME"
else
  echo "Lade Ubuntu ISO: $ISO_URL"
  wget -O "$ISO_NAME" "$ISO_URL"
fi

# =========================
# grub.cfg aus der ISO finden & extrahieren
# =========================
GRUB_PATH=""
if 7z l "$ISO_NAME" >/tmp/iso.lst 2>/dev/null; then
  GRUB_PATH="$(awk '/boot\/grub\/grub.cfg$/{print $NF}' /tmp/iso.lst | head -n1 || true)"
fi
if [[ -z "$GRUB_PATH" ]]; then
  echo "Konnte boot/grub/grub.cfg in der ISO nicht finden."; exit 1
fi
7z x -y -o"$TMPDIR" "$ISO_NAME" "$GRUB_PATH" >/dev/null
[[ -f "$TMPDIR/$GRUB_PATH" ]] || { echo "Extraktion von $GRUB_PATH fehlgeschlagen"; exit 1; }

# =========================
# grub.cfg patchen (Autoinstall-Parameter anhängen)
# =========================
sed -i 's|\(linux .*\) ---|\1 autoinstall ds=nocloud;s=/cdrom/nocloud/ ---|g' "$TMPDIR/$GRUB_PATH"

# =========================
# NoCloud-Seed bauen
# =========================
NOCLOUD_DIR="$TMPDIR/nocloud"
mkdir -p "$NOCLOUD_DIR"

cat > "$NOCLOUD_DIR/meta-data" <<'EOF'
instance-id: ubuntu-homelab
EOF

USER_DATA="$NOCLOUD_DIR/user-data"
{
  echo "#cloud-config"
  echo "autoinstall:"
  echo "  version: 1"

  # Diese Sektionen sind INTERAKTIV (im TUI) – mit unseren Defaults:
  echo "  interactive-sections:"
  echo "    - locale"
  echo "    - keyboard"
  echo "    - timezone"
  echo "    - identity"
  echo "    - ssh"
  echo "    - network"
  echo "    - storage"

  # Defaults (änderbar im TUI)
  echo "  locale: ${DEF_LOCALE}"
  echo "  keyboard:"
  echo "    layout: ${DEF_KEYBOARD_LAYOUT}"
  echo "  timezone: ${DEF_TIMEZONE}"

  echo "  identity:"
  echo "    hostname: ${DEF_HOSTNAME}"
  echo "    username: ${DEF_USERNAME}"
  # Passwort absichtlich NICHT gesetzt -> Installationsdialog fragt nach

  # SSH: interaktiv, aber mit sinnvoller Vorbelegung
  echo "  ssh:"
  echo "    install-server: true"
  echo "    allow-pw: true"

  # Pakete
  echo "  packages:"
  for p in "${EXTRA_PACKAGES[@]}"; do echo "    - $p"; done

  # NetworkManager als Renderer (Startwerte folgen unten)
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

# =========================
# Late-Commands (Dienste aktivieren, Updates, mDNS, Firewall)
# =========================
cat >> "$USER_DATA" <<'EOF'

  late-commands:
    # Nutzergruppen
    - curtin in-target -- /usr/bin/usermod -aG libvirt,lxd,libvirt-qemu,kvm ${DEF_USERNAME}

    # SSH sicherstellen (falls der Installer es nicht automatisch enabled)
    - curtin in-target -- /usr/bin/systemctl enable --now ssh || true

    # NetworkManager aktivieren & alles managen lassen
    - curtin in-target -- /usr/bin/systemctl enable --now NetworkManager
    - curtin in-target -- /bin/bash -c 'mkdir -p /etc/NetworkManager/conf.d; echo -e "[keyfile]\nunmanaged-devices=none" > /etc/NetworkManager/conf.d/manage-all.conf || true'
    - curtin in-target -- /usr/bin/systemctl reload NetworkManager || true

    # Standarddienste aktivieren
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

# =========================
# Neues ISO bauen – Bootstrukturen der Original-ISO beibehalten
# =========================
echo "Baue neue ISO (Bootdaten behalten): $OUT_ISO"
xorriso -indev "$ISO_NAME" -outdev "$OUT_ISO" \
  -map "$TMPDIR/$GRUB_PATH" "/$GRUB_PATH" \
  -map "$NOCLOUD_DIR" /nocloud \
  -boot_image any keep \
  -volid "$VOLID" \
  -joliet on \
  -rockridge on
echo "Fertig: $OUT_ISO"

# =========================
# Optional: auf USB schreiben
# =========================
if [[ -n "$USB_DEVICE" ]]; then
  if [[ ! -b "$USB_DEVICE" ]]; then
    echo "Fehler: $USB_DEVICE ist kein Blockgerät."; exit 1
  fi
  if [[ "$FORCE" != "--force" ]]; then
    echo ">>> ACHTUNG: Schreibe ISO auf ${USB_DEVICE} (ALLE Daten weg!)"
    read -p "Weiter mit dd? Tippe YES: " REPLY
    [[ "$REPLY" == "YES" ]] || { echo "Abgebrochen."; exit 1; }
  fi
  $SUDO dd if="$OUT_ISO" of="$USB_DEVICE" bs=4M status=progress oflag=sync
  sync
  echo "USB-Stick ist bereit."
fi
