#!/usr/bin/env bash
set -Eeuo pipefail

readonly SWAPFILE="/swapfile"
readonly SWAPSIZE="2G"
readonly SWAPPINESS="20"
readonly SYSCTL_FILE="/etc/sysctl.d/60-hermes-swap.conf"

log() { printf '[+] %s\n' "$*"; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

[[ "$EUID" -eq 0 ]] || die "Run this script as root"
for command_name in awk blkid fallocate mkswap swapon sysctl; do
  command -v "$command_name" >/dev/null 2>&1 || die "Required command not found: $command_name"
done

log "Configuring ${SWAPSIZE} swap file"
if [[ ! -e "$SWAPFILE" ]]; then
  fallocate -l "$SWAPSIZE" "$SWAPFILE"
  chmod 600 "$SWAPFILE"
  mkswap "$SWAPFILE"
elif [[ ! -f "$SWAPFILE" || -L "$SWAPFILE" ]]; then
  die "$SWAPFILE exists but is not a regular non-symlink file"
else
  chmod 600 "$SWAPFILE"
  swap_type="$(blkid -p -s TYPE -o value "$SWAPFILE" 2>/dev/null || true)"
  [[ "$swap_type" == swap ]] || die "$SWAPFILE exists but does not contain a swap signature"
fi

if ! swapon --show=NAME --noheadings | awk '{$1=$1}; $0 == "/swapfile" { found=1 } END { exit !found }'; then
  swapon "$SWAPFILE"
fi

if ! awk '$1 == "/swapfile" && $3 == "swap" { found=1 } END { exit !found }' /etc/fstab; then
  cp -a /etc/fstab "/etc/fstab.bak.$(date +%F-%H%M%S-%N)"
  printf '%s none swap sw 0 0\n' "$SWAPFILE" >> /etc/fstab
fi

cat > "$SYSCTL_FILE" <<EOF
# Managed by ochenstarik-server-1.sh
vm.swappiness=${SWAPPINESS}
EOF
chmod 644 "$SYSCTL_FILE"
sysctl -p "$SYSCTL_FILE" >/dev/null

log "Server memory setup is complete"
swapon --show
printf '\nNow run ochenstarik-server-2.sh as root.\n'