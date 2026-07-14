#!/usr/bin/env bash
set -Eeuo pipefail

readonly SSH_PORT="20202"
readonly TIMEZONE="Asia/Novosibirsk"

log() { printf '[+] %s\n' "$*"; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

[[ "$EUID" -eq 0 ]] || die "Run this script as root"
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

log "Setting timezone to ${TIMEZONE}"
timedatectl set-timezone "$TIMEZONE"

log "Configuring UFW"
# Keep port 22 open until step 3 moves SSH to 20202 and the new login is tested.
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

printf '\nDone. Now run ochenstarik-server-3.sh as root.\n'
printf 'Do not remove the UFW rule for port 22 until SSH login on port %s succeeds.\n' "$SSH_PORT"
