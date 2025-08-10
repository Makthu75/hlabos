#!/usr/bin/env bash
set -euo pipefail

# =========================================
# postinstall-packages.sh
#   Installiert alle benötigten Pakete für Homelab/NAS
#   Geeignet für Ubuntu Server 25.04 (auch "minimized")
# =========================================

ASSUME_YES=0
INSTALL_NM="${INSTALL_NM:-0}"     # per ENV: INSTALL_NM=1
INSTALL_SSH="${INSTALL_SSH:-0}"   # per ENV: INSTALL_SSH=1

usage() {
  cat <<'EOF'
Usage: postinstall-packages.sh [--yes] [--with-nm] [--with-ssh] [-h|--help]

Optionen:
  --yes        : keine Rückfragen (non-interaktiv)
  --with-nm    : zusätzlich NetworkManager installieren  (alternativ: INSTALL_NM=1)
  --with-ssh   : zusätzlich OpenSSH-Server installieren  (alternativ: INSTALL_SSH=1)
  -h, --help   : diese Hilfe anzeigen

Installiert (idempotent):
- Basis/Tools: curl, git, jq, ca-certificates, htop, lm-sensors, smartmontools, nvme-cli
- Komfort/Minimized-Fixes: software-properties-common, gnupg, bash-completion, net-tools
- Sicherheit: ufw, fail2ban
- mDNS: avahi-daemon, libnss-mdns
- Virtualisierung: qemu-kvm, qemu-utils, libvirt-daemon-system, libvirt-clients, virtinst, bridge-utils
- LXD
- Docker (docker.io, docker-compose-plugin)
- Storage: zfsutils-linux, zfs-auto-snapshot
- NAS: samba, nfs-kernel-server

Hinweis:
- Dieses Script KONFIGURIERT NICHTS (keine Dienste/Netz). Dafür ist dein postconfig-Script zuständig.
EOF
}

# -------- Flags parsen --------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) ASSUME_YES=1; shift ;;
    --with-nm) INSTALL_NM=1; shift ;;
    --with-ssh) INSTALL_SSH=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unbekannte Option: $1"; usage; exit 1 ;;
  case_esac_done=true
  esac
done

# -------- Root benötigt --------
if [[ $EUID -ne 0 ]]; then
  echo "Bitte als root starten (z. B. 'sudo bash postinstall-packages.sh')."
  exit 1
fi

log() { printf "\033[1;32m[+]\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m[!]\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m[x]\033[0m %s\n" "$*" >&2; exit 1; }

apt_install() {
  local pkgs=("$@") miss=()
  for p in "${pkgs[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || miss+=("$p")
  done
  if ((${#miss[@]})); then
    log "Installiere Pakete: ${miss[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends "${miss[@]}"
  else
    log "Alle Pakete bereits vorhanden: ${pkgs[*]}"
  fi
}

# -------- Paketgruppen --------
BASE_PKGS=(
  curl git jq ca-certificates
  htop lm-sensors smartmontools nvme-cli
  software-properties-common   # wichtig bei "minimized"
  gnupg                        # für APT-Keys/Repos
  bash-completion              # Komfort
  net-tools                    # optional (ifconfig, netstat)
)

SEC_PKGS=( ufw fail2ban )
MDNS_PKGS=( avahi-daemon libnss-mdns )

VIRT_PKGS=( qemu-kvm qemu-utils libvirt-daemon-system libvirt-clients virtinst bridge-utils )
LXD_PKGS=( lxd )
DOCKER_PKGS=( docker.io docker-compose-plugin )
ZFS_PKGS=( zfsutils-linux zfs-auto-snapshot )
NAS_PKGS=( samba nfs-kernel-server )

# -------- Installation --------
log "Installiere Basis-/Minimized-Fixes"
apt_install "${BASE_PKGS[@]}"

log "Installiere Sicherheit & mDNS"
apt_install "${SEC_PKGS[@]}" "${MDNS_PKGS[@]}"

log "Installiere Virtualisierung/Container/Storage/NAS"
apt_install "${VIRT_PKGS[@]}" "${LXD_PKGS[@]}" "${DOCKER_PKGS[@]}" "${ZFS_PKGS[@]}" "${NAS_PKGS[@]}"

if [[ "$INSTALL_NM" == "1" ]]; then
  log "Installiere NetworkManager (--with-nm / INSTALL_NM=1)"
  apt_install network-manager
fi

if [[ "$INSTALL_SSH" == "1" ]]; then
  log "Installiere OpenSSH-Server (--with-ssh / INSTALL_SSH=1)"
  apt_install openssh-server
fi

log "Paket-Installation abgeschlossen. Für Dienst-/Netz-Konfiguration bitte 'postconfig-hlabos.sh' ausführen."
