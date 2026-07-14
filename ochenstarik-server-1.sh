#!/usr/bin/env bash
set -Eeuo pipefail

readonly SWAPFILE="/swapfile"
readonly SWAPSIZE="2G"
readonly SWAPPINESS="20"
readonly SYSCTL_FILE="/etc/sysctl.d/60-hermes-swap.conf"

log() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

choose_numbered_option() {
  local prompt="$1" result_variable="$2" answer index
  shift 2
  local -a options=("$@")

  ((${#options[@]} > 0)) || die "No options are available for: ${prompt}"
  while :; do
    printf '\n%s\n' "$prompt"
    for index in "${!options[@]}"; do
      printf '  %d) %s\n' "$((index + 1))" "${options[index]}"
    done
    read -rp "Enter the option number: " answer || die "Input was interrupted"
    if [[ "$answer" =~ ^[0-9]+$ ]] && ((answer >= 1 && answer <= ${#options[@]})); then
      printf -v "$result_variable" '%s' "${options[answer - 1]}"
      return 0
    fi
    warn "Enter a number from 1 to ${#options[@]}"
  done
}

choose_timezone_from_full_list() {
  local result_variable="$1" region selected_timezone
  local -a regions region_timezones

  mapfile -t regions < <(timedatectl list-timezones | awk -F/ 'NF > 1 && !seen[$1]++ { print $1 }')
  choose_numbered_option "Select a region:" region "${regions[@]}"
  mapfile -t region_timezones < <(timedatectl list-timezones | awk -F/ -v selected_region="$region" '$1 == selected_region')
  choose_numbered_option "Select a timezone in ${region}:" selected_timezone "${region_timezones[@]}"
  printf -v "$result_variable" '%s' "$selected_timezone"
}

choose_timezone() {
  local current_timezone timezone candidate
  local full_list_option="Other timezone (select by region)"
  local -a timezone_options=()

  current_timezone="$(timedatectl show --property=Timezone --value 2>/dev/null || true)"
  current_timezone="${current_timezone:-Asia/Novosibirsk}"

  for candidate in \
    "$current_timezone" \
    UTC \
    Europe/Moscow \
    Europe/Kaliningrad \
    Asia/Yekaterinburg \
    Asia/Omsk \
    Asia/Novosibirsk \
    Asia/Krasnoyarsk \
    Asia/Irkutsk \
    Asia/Yakutsk \
    Asia/Vladivostok \
    Asia/Magadan \
    Asia/Kamchatka; do
    if timedatectl list-timezones | grep -Fqx -- "$candidate" &&
       [[ ! " ${timezone_options[*]} " =~ " ${candidate} " ]]; then
      timezone_options+=("$candidate")
    fi
  done
  timezone_options+=("$full_list_option")

  choose_numbered_option "Select the server timezone (current: ${current_timezone}):" timezone "${timezone_options[@]}"
  if [[ "$timezone" == "$full_list_option" ]]; then
    choose_timezone_from_full_list timezone
  fi

  timedatectl list-timezones | grep -Fqx -- "$timezone" || die "Unknown timezone: $timezone"
  timedatectl set-timezone "$timezone"
  log "Timezone set to ${timezone}"
}

[[ "$EUID" -eq 0 ]] || die "Run this script as root"
for command_name in awk blkid fallocate grep mkswap swapon sysctl timedatectl; do
  command -v "$command_name" >/dev/null 2>&1 || die "Required command not found: $command_name"
done

choose_timezone

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
printf 'Timezone: %s\n' "$(timedatectl show --property=Timezone --value)"
swapon --show
printf '\nNow run ochenstarik-server-2.sh as root.\n'
