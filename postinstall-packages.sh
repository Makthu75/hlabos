#!/usr/bin/env bash
set -euo pipefail

# =========================================
# postinstall-packages.sh
#   Installiert alle benötigten Pakete für Homelab/NAS
#   Optimiert für Ubuntu Server 25.04 (auch "minimized")
#   -> Docker: standardmäßig Upstream (aktuellste Version)
# =========================================

ASSUME_YES=0
INSTALL_NM="${INSTALL_NM:-0}"      # per ENV: INSTALL_NM=1
INSTALL_SSH="${INSTALL_SSH:-0}"    # per ENV: INSTALL_SSH=1

# Docker-Quelle: Upstream ist Default
DOCKER_MODE="${DOCKER_MODE:-upstream}"   # "upstream" | "ubuntu"

usage() {
  cat <<'EOF'
Usage: postinstall-packages.sh [--yes] [--with-nm] [--with-ssh] [--docker-upstream|--docker-ubuntu] [-h|--help]

Optionen:
  --yes            : keine Rückfragen (non-interaktiv)
  --with-nm        : zusätzlich NetworkManager installieren   (alternativ: INSTALL_NM=1)
  --with-ssh       : zusätzlich OpenSSH-Server installieren   (alternativ: INSTALL_SSH=1)
  --docker-upstream: Docker aus offiziellem Docker-Repo (Default; neueste Version)
  --docker-ubuntu  : Docker aus Ubuntu-Repo (docker.io)
  -h, --help       : diese Hilfe anzeigen

Installiert (idempotent):
- Basis/Tools: curl, git, jq, ca-certificates, htop, lm-sensors, smartmontools, nvme-cli
- Komfort/Minimized-Fixes: software-properties-common, gnupg, bash-completion, net-tools
- Sicherheit: ufw, fail2ban
- mDNS: avahi-daemon, libnss-mdns
- Virtualisierung: qemu-kvm, qemu-utils, libvirt-daemon-system, libvirt-clients, virtinst, bridge-utils
- LXD
- Docker:
    * Default: Upstream (docker-ce, docker-ce-cli, containerd.io, docker-buildx-plugin, docker-compose-plugin)
    * Optional: Ubuntu (docker.io, docker-compose-plugin)
- Storage: zfsutils-linux, zfs-auto-snapshot
- NAS: samba, nfs-kernel-server

Hinweis: Dieses Script KONFIGURIERT keine Dienste/Netzwerke.
         Für Dienst-/Netz-Konfiguration bitte anschließend 'postconfig-hlabos.sh' ausführen.
EOF
}

# -------- Flags parsen --------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) ASSUME_YES=1; shift ;;
    --with-nm) INSTALL_NM=1; shift ;;
    --with-ssh) INSTALL_SSH=1; shift ;;
    --docker-upstream) DOCKER_MODE="upstream"; shift ;;
    --docker-ubuntu) DOCKER_MODE="ubuntu"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unbekannte Option: $1"; usage; exit 1 ;;
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
  software-properties-common
  gnupg
  bash-completion
  net-tools
)

SEC_PKGS=( ufw fail2ban )
MDNS_PKGS=( avahi-daemon libnss-mdns )

VIRT_PKGS=( qemu-kvm qemu-utils libvirt-daemon-system libvirt-clients virtinst bridge-utils )
LXD_PKGS=( lxd )
# Docker wird separat je nach Modus installiert
ZFS_PKGS=( zfsutils-linux zfs-auto-snapshot )
NAS_PKGS=( samba nfs-kernel-server )

install_docker_ubuntu() {
  log "Docker (Ubuntu-Repo) wird installiert ..."
  apt_install docker.io docker-compose-plugin
}

install_docker_upstream() {
  log "Docker (Upstream) wird eingerichtet ..."
  # Konflikt-Pakete entfernen (ohne Datenverlust)
  # (Images/Volumes bleiben in /var/lib/docker erhalten)
  apt-get remove -y docker.io docker-doc docker-compose docker-compose-plugin podman-docker || true
  apt-get remove -y containerd runc || true

  # Repo-Key & Source einrichten
  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
  fi

  . /etc/os-release
  local arch="$(dpkg --print-architecture)"
  local codename="${VERSION_CODENAME:-noble}"

  cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable
EOF

  apt-get update -y
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

# -------- Installation --------
log "Installiere Basis-/Minimized-Fixes"
apt_install "${BASE_PKGS[@]}"

log "Installiere Sicherheit & mDNS"
apt_install "${SEC_PKGS[@]}" "${MDNS_PKGS[@]}"

log "Installiere Virtualisierung/Container/Storage/NAS"
apt_install "${VIRT_PKGS[@]}" "${LXD_PKGS[@]}" "${ZFS_PKGS[@]}" "${NAS_PKGS[@]}"

# NetworkManager/SSH optional
if [[ "$INSTALL_NM" == "1" ]]; then
  log "Installiere NetworkManager (--with-nm / INSTALL_NM=1)"
  apt_install network-manager
fi
if [[ "$INSTALL_SSH" == "1" ]]; then
  log "Installiere OpenSSH-Server (--with-ssh / INSTALL_SSH=1)"
  apt_install openssh-server
fi

# Docker je nach Modus
case "$DOCKER_MODE" in
  upstream) install_docker_upstream ;;
  ubuntu)   install_docker_ubuntu ;;
  *) err "Unbekannter DOCKER_MODE: $DOCKER_MODE (erwarte 'upstream' oder 'ubuntu')" ;;
esac

log "Paket-Installation abgeschlossen. Für Dienst-/Netz-Konfiguration bitte 'postconfig-hlabos.sh' ausführen."
