#!/usr/bin/env bash
set -Eeuo pipefail

readonly SWAPFILE="/swapfile"
readonly SWAPSIZE="2G"
readonly SWAPPINESS="20"
readonly SYSCTL_FILE="/etc/sysctl.d/60-hermes-swap.conf"
readonly CONFIG_DIR="/etc/ochenstarik-server"
readonly LOCALE_BACKUP="${CONFIG_DIR}/locale-before-selection.conf"
readonly LOCALE_ABSENT_MARKER="${CONFIG_DIR}/locale-before-selection.absent"
readonly LOCALE_PACKAGES="${CONFIG_DIR}/locale-installed-packages.list"
readonly LEGACY_LOCALE_BACKUP="${CONFIG_DIR}/locale-before-russian.conf"
readonly LEGACY_LOCALE_ABSENT_MARKER="${CONFIG_DIR}/locale-before-russian.absent"
readonly LEGACY_LOCALE_PACKAGES="${CONFIG_DIR}/russian-locale-installed-packages.list"
readonly PROGRAM_PACKAGES="${CONFIG_DIR}/step1-installed-packages.list"

readonly -a PROGRAM_GROUP_TITLES=(
  "Терминал и повседневная работа"
  "Диагностика сети"
  "Мониторинг системы и дисков"
  "Безопасность и обслуживание Ubuntu"
  "Разработка и автоматизация"
  "Архивы, таблицы и локальные данные"
  "Документы, PDF и OCR"
  "Изображения, аудио и видео"
  "Резервное копирование и синхронизация"
)

readonly -a PROGRAM_GROUP_DESCRIPTIONS=(
  "git, wget, curl, jq/yq, ripgrep/fd/fzf, lnav, редакторы, mc, tmux, htop/btop, ncdu, rsync"
  "DNS/ping/MTR/traceroute, tcpdump, nmap, netcat, HTTPie, whois, ethtool и socat"
  "iotop, sysstat, SMART, датчики, atop, nethogs, vnStat и инструменты процессов"
  "auditd, AppArmor tools, Lynis, needrestart, автоматические обновления, debsums, ACL/xattr"
  "компилятор, ShellCheck, Python pip/venv и pipx"
  "7-Zip/ZIP/RAR, SQLite, csvkit, клиенты PostgreSQL и Redis"
  "Poppler, qpdf, Ghostscript, OCRmyPDF/Tesseract, LibreOffice, Pandoc, antiword/catdoc"
  "ImageMagick, ExifTool, WebP, FFmpeg и MediaInfo"
  "restic, BorgBackup и rclone"
)

readonly -a PROGRAM_GROUP_PACKAGES=(
  "git wget curl ca-certificates jq yq ripgrep fd-find fzf lnav tree less nano vim mc tmux screen htop btop ncdu lsof strace rsync"
  "dnsutils iputils-ping mtr-tiny traceroute tcpdump nmap netcat-openbsd httpie whois ethtool socat"
  "iotop sysstat smartmontools lm-sensors atop nethogs vnstat psmisc"
  "auditd apparmor-utils lynis needrestart unattended-upgrades debsums acl attr"
  "build-essential shellcheck python3-pip python3-venv pipx"
  "p7zip-full unzip zip unrar sqlite3 csvkit postgresql-client redis-tools"
  "poppler-utils qpdf ghostscript ocrmypdf tesseract-ocr tesseract-ocr-eng tesseract-ocr-rus libreoffice pandoc antiword catdoc"
  "imagemagick libimage-exiftool-perl webp ffmpeg mediainfo"
  "restic borgbackup rclone"
)

APT_UPDATED=no

log() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

package_is_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -Fqx 'install ok installed'
}

ensure_package_tools() {
  local command_name
  for command_name in apt-get apt-cache dpkg-query; do
    command -v "$command_name" >/dev/null 2>&1 \
      || die "Required command not found: $command_name"
  done
}

ensure_apt_updated() {
  [[ "$APT_UPDATED" == no ]] || return 0
  ensure_package_tools
  log "Обновление списка пакетов"
  apt-get update
  APT_UPDATED=yes
}

record_new_packages() {
  local destination="$1" package_name
  shift
  install -d -m 700 -o root -g root "$CONFIG_DIR"
  [[ ! -L "$destination" ]] || die "Отказ от записи через ссылку: $destination"
  touch "$destination"
  for package_name in "$@"; do
    grep -Fqx -- "$package_name" "$destination" \
      || printf '%s\n' "$package_name" >> "$destination"
  done
  chown root:root "$destination"
  chmod 600 "$destination"
}

migrate_legacy_locale_state() {
  local package_name
  install -d -m 700 -o root -g root "$CONFIG_DIR"
  [[ ! -L "$LOCALE_BACKUP" && ! -L "$LOCALE_ABSENT_MARKER" \
    && ! -L "$LOCALE_PACKAGES" ]] || die "Файл состояния локали не должен быть ссылкой"
  if [[ -f "$LEGACY_LOCALE_BACKUP" && ! -L "$LEGACY_LOCALE_BACKUP" \
    && ! -e "$LOCALE_BACKUP" ]]; then
    mv -- "$LEGACY_LOCALE_BACKUP" "$LOCALE_BACKUP"
  fi
  if [[ -f "$LEGACY_LOCALE_ABSENT_MARKER" \
    && ! -L "$LEGACY_LOCALE_ABSENT_MARKER" && ! -e "$LOCALE_ABSENT_MARKER" ]]; then
    mv -- "$LEGACY_LOCALE_ABSENT_MARKER" "$LOCALE_ABSENT_MARKER"
  fi
  if [[ -f "$LEGACY_LOCALE_PACKAGES" && ! -L "$LEGACY_LOCALE_PACKAGES" ]]; then
    touch "$LOCALE_PACKAGES"
    while IFS= read -r package_name || [[ -n "$package_name" ]]; do
      [[ -z "$package_name" ]] || grep -Fqx -- "$package_name" "$LOCALE_PACKAGES" \
        || printf '%s\n' "$package_name" >> "$LOCALE_PACKAGES"
    done < "$LEGACY_LOCALE_PACKAGES"
    rm -f -- "$LEGACY_LOCALE_PACKAGES"
  fi
}

save_original_locale() {
  migrate_legacy_locale_state

  if [[ ! -e "$LOCALE_BACKUP" && ! -e "$LOCALE_ABSENT_MARKER" ]]; then
    if [[ -f /etc/default/locale && ! -L /etc/default/locale ]]; then
      cp -a -- /etc/default/locale "$LOCALE_BACKUP"
      chmod 600 "$LOCALE_BACKUP"
    else
      : > "$LOCALE_ABSENT_MARKER"
      chmod 600 "$LOCALE_ABSENT_MARKER"
    fi
  fi
}

choose_terminal_language() {
  local answer selected_locale selected_language primary_language package_name index
  local current_locale="${LANG:-не задана}"
  local -a titles=(
    "Не менять язык терминала"
    "Русский — ru_RU.UTF-8"
    "English (US) — en_US.UTF-8"
    "Deutsch — de_DE.UTF-8"
    "Français — fr_FR.UTF-8"
    "Español — es_ES.UTF-8"
    "Italiano — it_IT.UTF-8"
    "Português (Brasil) — pt_BR.UTF-8"
    "Polski — pl_PL.UTF-8"
    "Українська — uk_UA.UTF-8"
    "Türkçe — tr_TR.UTF-8"
    "简体中文 — zh_CN.UTF-8"
    "日本語 — ja_JP.UTF-8"
    "한국어 — ko_KR.UTF-8"
    "Другая локаль из полного списка"
  )
  local -a locales=(
    "" ru_RU.UTF-8 en_US.UTF-8 de_DE.UTF-8 fr_FR.UTF-8 es_ES.UTF-8
    it_IT.UTF-8 pt_BR.UTF-8 pl_PL.UTF-8 uk_UA.UTF-8 tr_TR.UTF-8
    zh_CN.UTF-8 ja_JP.UTF-8 ko_KR.UTF-8 ""
  )
  local -a language_values=(
    "" ru_RU:ru en_US:en de_DE:de fr_FR:fr es_ES:es it_IT:it
    pt_BR:pt pl_PL:pl uk_UA:uk tr_TR:tr zh_CN:zh ja_JP:ja ko_KR:ko ""
  )
  local -a language_packages=(
    "" "language-pack-ru manpages-ru" language-pack-en language-pack-de
    language-pack-fr language-pack-es language-pack-it language-pack-pt
    language-pack-pl language-pack-uk language-pack-tr language-pack-zh-hans
    language-pack-ja language-pack-ko ""
  )
  local -a supported_locales packages=(locales) available_packages=() \
    newly_installed=() extra_packages=()

  while :; do
    printf '\nВыберите язык новых терминальных сессий (сейчас: %s):\n' "$current_locale"
    for index in "${!titles[@]}"; do
      printf '  %d) %s\n' "$((index + 1))" "${titles[index]}"
    done
    read -rp 'Номер языка [1 — не менять]: ' answer || die "Ввод прерван"
    answer="${answer:-1}"
    [[ "$answer" =~ ^[0-9]+$ ]] && ((answer >= 1 && answer <= ${#titles[@]})) && break
    warn "Введите номер от 1 до ${#titles[@]}"
  done

  ((answer == 1)) && { log "Язык терминала не изменён"; return 0; }
  ensure_apt_updated
  save_original_locale

  if ((answer == ${#titles[@]})); then
    package_is_installed locales || newly_installed+=(locales)
    apt-get install -y locales
    mapfile -t supported_locales < <(awk '{print $1}' /usr/share/i18n/SUPPORTED | sort -u)
    choose_numbered_option "Выберите локаль из полного списка:" selected_locale \
      "${supported_locales[@]}"
    primary_language="${selected_locale%%_*}"
    selected_language="${selected_locale%%.*}:${primary_language}"
    packages+=("language-pack-${primary_language}")
  else
    selected_locale="${locales[answer - 1]}"
    selected_language="${language_values[answer - 1]}"
    read -r -a extra_packages <<< "${language_packages[answer - 1]}"
    packages+=("${extra_packages[@]}")
  fi

  for package_name in "${packages[@]}"; do
    [[ -n "$package_name" ]] || continue
    if apt-cache show "$package_name" >/dev/null 2>&1; then
      available_packages+=("$package_name")
      package_is_installed "$package_name" || newly_installed+=("$package_name")
    else
      warn "Языковой пакет недоступен и будет пропущен: $package_name"
    fi
  done

  export DEBIAN_FRONTEND=noninteractive
  ((${#available_packages[@]} == 0)) || apt-get install -y "${available_packages[@]}"
  locale-gen "$selected_locale"
  update-locale LANG="$selected_locale" LANGUAGE="$selected_language" \
    LC_MESSAGES="$selected_locale"
  record_new_packages "$LOCALE_PACKAGES" "${newly_installed[@]}"

  log "Выбрана локаль ${selected_locale}. Она применится при следующем входе"
}

choose_and_install_programs() {
  local answer token group_index package_name
  local -a selected_groups=() group_packages=() requested=() available=() newly_installed=()
  local -A selected=() seen=()

  printf '\nВыберите наборы программ для установки:\n'
  for group_index in "${!PROGRAM_GROUP_TITLES[@]}"; do
    printf '  %d) %s\n     %s\n' "$((group_index + 1))" \
      "${PROGRAM_GROUP_TITLES[group_index]}" "${PROGRAM_GROUP_DESCRIPTIONS[group_index]}"
  done
  printf '  0) Не устанавливать дополнительные программы\n'
  printf '\nВведите номера через пробел, например: 1 2 4 9.\n'
  read -rp 'Выбор [Enter — установить все наборы]: ' answer || die "Ввод прерван"
  answer="${answer//,/ }"

  if [[ -z "${answer//[[:space:]]/}" ]]; then
    for group_index in "${!PROGRAM_GROUP_TITLES[@]}"; do
      selected_groups+=("$group_index")
    done
  elif [[ "$answer" =~ ^[[:space:]]*0[[:space:]]*$ ]]; then
    log "Установка дополнительных программ пропущена"
    return 0
  else
    for token in $answer; do
      [[ "$token" =~ ^[0-9]+$ ]] \
        || die "Некорректный номер набора: $token"
      ((token >= 1 && token <= ${#PROGRAM_GROUP_TITLES[@]})) \
        || die "Номер набора вне диапазона: $token"
      group_index="$((token - 1))"
      [[ -n "${selected[$group_index]:-}" ]] || selected_groups+=("$group_index")
      selected[$group_index]=yes
    done
  fi

  ensure_apt_updated
  for group_index in "${selected_groups[@]}"; do
    log "Выбран набор: ${PROGRAM_GROUP_TITLES[group_index]}"
    read -r -a group_packages <<< "${PROGRAM_GROUP_PACKAGES[group_index]}"
    for package_name in "${group_packages[@]}"; do
      [[ -n "${seen[$package_name]:-}" ]] && continue
      seen[$package_name]=yes
      requested+=("$package_name")
    done
  done

  for package_name in "${requested[@]}"; do
    if apt-cache show "$package_name" >/dev/null 2>&1; then
      available+=("$package_name")
      package_is_installed "$package_name" || newly_installed+=("$package_name")
    else
      warn "Пакет отсутствует в подключённых репозиториях и пропущен: $package_name"
    fi
  done

  ((${#available[@]} > 0)) || die "Ни один выбранный пакет не найден"
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y "${available[@]}"
  record_new_packages "$PROGRAM_PACKAGES" "${newly_installed[@]}"
  log "Выбранные программы установлены"
}

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
choose_terminal_language
choose_and_install_programs

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
