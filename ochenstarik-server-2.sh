#!/usr/bin/env bash
set -Eeuo pipefail

readonly SSH_PORT_CONFIG="/etc/ochenstarik-server/ssh-port.conf"
readonly DEFAULT_SSH_PORT="20202"

log() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

is_valid_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
  (( 10#$port >= 1 && 10#$port <= 65535 ))
}

choose_ssh_port() {
  local default_port="$DEFAULT_SSH_PORT" saved_port selected_port

  if [[ -e "$SSH_PORT_CONFIG" ]]; then
    [[ -f "$SSH_PORT_CONFIG" && ! -L "$SSH_PORT_CONFIG" ]] \
      || die "$SSH_PORT_CONFIG must be a regular non-symlink file"
    saved_port="$(sed -n 's/^SSH_PORT=//p' "$SSH_PORT_CONFIG" | head -n1 | tr -d '\r')"
    if is_valid_port "$saved_port"; then
      default_port="$((10#$saved_port))"
    else
      warn "Ignoring invalid saved SSH port: ${saved_port:-empty}"
    fi
  fi

  while :; do
    read -rp "SSH port for step 3 [${default_port}]: " selected_port
    selected_port="${selected_port:-$default_port}"
    if is_valid_port "$selected_port"; then
      SSH_PORT="$((10#$selected_port))"
      return 0
    fi
    warn "SSH port must be a number between 1 and 65535"
  done
}

[[ "$EUID" -eq 0 ]] || die "Run this script as root"
SSH_PORT=""
choose_ssh_port
export DEBIAN_FRONTEND=noninteractive

log "Updating the operating system"
apt-get update
apt-get upgrade -y

log "Installing server and document-processing packages"
apt-get install -y \
  sudo ufw fail2ban curl ca-certificates openssl openssh-server logrotate \
  poppler-utils qpdf ghostscript ocrmypdf \
  tesseract-ocr tesseract-ocr-eng tesseract-ocr-rus \
  libreoffice pandoc antiword catdoc imagemagick libimage-exiftool-perl webp \
  ffmpeg mediainfo p7zip-full unzip zip unrar jq yq csvkit sqlite3 \
  python3-pip python3-venv mc

install -d -m 700 -o root -g root "$(dirname "$SSH_PORT_CONFIG")"
printf 'SSH_PORT=%s\n' "$SSH_PORT" > "$SSH_PORT_CONFIG"
chown root:root "$SSH_PORT_CONFIG"
chmod 600 "$SSH_PORT_CONFIG"
log "Saved SSH port ${SSH_PORT} for step 3"

log "Configuring UFW"
# Keep port 22 open until step 3 moves SSH to the selected port and the new login is tested.
ufw allow "22/tcp"
ufw allow "${SSH_PORT}/tcp"
ufw allow "80/tcp"
ufw allow "2096/tcp"
ufw allow "443/tcp"
ufw allow "40000/tcp"
ufw allow "63636/tcp"
ufw --force enable

log "Installed versions"
printf 'Timezone: %s\n' "$(timedatectl show --property=Timezone --value)"
ufw status verbose

printf '\nDone. Now run ochenstarik-server-user-3.sh as root.\n'
printf 'Step 3 will move SSH to port %s.\n' "$SSH_PORT"
printf 'Do not remove the UFW rule for port 22 until SSH login on port %s succeeds.\n' "$SSH_PORT"
