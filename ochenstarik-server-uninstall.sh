#!/usr/bin/env bash
set -Eeuo pipefail

readonly CONFIG_DIR="/etc/ochenstarik-server"
readonly MANAGED_PORTS_CONFIG="${CONFIG_DIR}/ufw-managed-ports.conf"
readonly IP_FAMILY_CONFIG="${CONFIG_DIR}/ip-family.conf"
readonly SSH_PORT_CONFIG="${CONFIG_DIR}/ssh-port.conf"
readonly IPV6_SYSCTL_FILE="/etc/sysctl.d/99-zz-ochenstarik-disable-ipv6.conf"
readonly SWAPFILE="/swapfile"
readonly SWAP_SYSCTL_FILE="/etc/sysctl.d/60-hermes-swap.conf"
readonly SSHD_DROPIN="/etc/ssh/sshd_config.d/00-hermes-hardening.conf"
readonly FAIL2BAN_JAIL="/etc/fail2ban/jail.d/hermes.local"
readonly SETUP_ENV="/root/setup-data/env.txt"
readonly SETUP_HASH="/root/setup-data/password.hash"
readonly TELEGRAM_CONFIG="${CONFIG_DIR}/telegram.conf"
readonly TELEGRAM_SCRIPT="/usr/local/libexec/ochenstarik-ssh-login-telegram.sh"
readonly TELEGRAM_LEGACY_SCRIPT="/usr/local/libexec/ssh-login-telegram.sh"
readonly TELEGRAM_LOG="/var/log/ochenstarik-ssh-login-telegram.log"
readonly TELEGRAM_LOGROTATE="/etc/logrotate.d/ochenstarik-ssh-login-telegram"
readonly PAM_SSHD="/etc/pam.d/sshd"
readonly XRAY_STATE_DIR="/etc/ochenstarik-xray"
readonly XRAY_CONFIG_DIR="/usr/local/etc/xray"
readonly XRAY_SHARE_DIR="/usr/local/share/xray"
readonly XRAY_LOG_DIR="/var/log/xray"
readonly XRAY_HELPER="/usr/local/sbin/ochenstarik-xray-routing"
readonly XRAY_SERVICE="/etc/systemd/system/ochenstarik-xray-routing.service"
readonly BACKUP_CONFIG="${CONFIG_DIR}/backup.conf"
readonly BACKUP_RUNNER="/usr/local/sbin/ochenstarik-server-backup"
readonly LOCALE_BACKUP="${CONFIG_DIR}/locale-before-russian.conf"
readonly LOCALE_ABSENT_MARKER="${CONFIG_DIR}/locale-before-russian.absent"
readonly LOCALE_PACKAGES="${CONFIG_DIR}/russian-locale-installed-packages.list"

log() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

ask_yes_no() {
  local prompt="$1" default_answer="${2:-no}" answer suffix
  [[ "$default_answer" == yes || "$default_answer" == no ]] \
    || die "Некорректный ответ по умолчанию"
  [[ "$default_answer" == yes ]] && suffix='[Y/n]' || suffix='[y/N]'
  while :; do
    read -rp "$prompt $suffix " answer || die "Ввод прерван"
    answer="${answer:-$default_answer}"
    case "${answer,,}" in
      y|yes|д|да) return 0 ;;
      n|no|н|нет) return 1 ;;
      *) warn "Ответьте yes/no или да/нет" ;;
    esac
  done
}

service_exists() {
  command -v systemctl >/dev/null 2>&1 && systemctl cat "$1" >/dev/null 2>&1
}

stop_disable_service() {
  local unit="$1"
  service_exists "$unit" || return 0
  systemctl disable --now "$unit" >/dev/null 2>&1 || true
  systemctl reset-failed "$unit" >/dev/null 2>&1 || true
}

is_valid_port() {
  [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

current_ssh_port() {
  local port=""
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    port="${SSH_CONNECTION##* }"
    is_valid_port "$port" && printf '%s' "$((10#$port))"
  fi
}

remove_ufw_rules() {
  local rule port protocol active_port
  command -v ufw >/dev/null 2>&1 || return 0
  active_port="$(current_ssh_port)"

  if LANG=C ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow 22/tcp >/dev/null
    log "Порт 22/tcp открыт перед сбросом SSH"
  fi

  [[ -f "$MANAGED_PORTS_CONFIG" && ! -L "$MANAGED_PORTS_CONFIG" ]] || return 0
  while IFS= read -r rule || [[ -n "$rule" ]]; do
    [[ "$rule" =~ ^([0-9]{1,5})/(tcp|udp)$ ]] || continue
    port="$((10#${BASH_REMATCH[1]}))"
    protocol="${BASH_REMATCH[2]}"
    if [[ "$protocol" == tcp && "$port" == 22 ]]; then
      continue
    fi
    if [[ -n "$active_port" && "$protocol" == tcp && "$port" == "$active_port" ]]; then
      warn "Правило текущего SSH-порта ${port}/tcp оставлено для защиты соединения"
      continue
    fi
    while ufw --force delete allow from 0.0.0.0/0 to any port "$port" proto "$protocol" \
      >/dev/null 2>&1; do :; done
    while ufw --force delete allow from ::/0 to any port "$port" proto "$protocol" \
      >/dev/null 2>&1; do :; done
    while ufw --force delete allow "${port}/${protocol}" >/dev/null 2>&1; do :; done
  done < "$MANAGED_PORTS_CONFIG"
  ufw reload >/dev/null 2>&1 || true
  log "Управляемые правила UFW удалены"
}

restore_ipv6_defaults() {
  rm -f -- "$IPV6_SYSCTL_FILE"
  if command -v sysctl >/dev/null 2>&1; then
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
  fi
  if [[ -f /etc/default/ufw && ! -L /etc/default/ufw ]]; then
    if grep -q '^IPV6=' /etc/default/ufw; then
      sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
    else
      printf '\nIPV6=yes\n' >> /etc/default/ufw
    fi
  fi
  command -v ufw >/dev/null 2>&1 && ufw reload >/dev/null 2>&1 || true
}

reset_ssh_and_user() {
  local ssh_service="" configured_user="" login_user="${SUDO_USER:-}"

  if [[ -f "$SETUP_ENV" && ! -L "$SETUP_ENV" ]]; then
    configured_user="$(sed -n 's/^NEW_USERNAME=//p' "$SETUP_ENV" | head -n1 | tr -d '\r')"
  fi

  rm -f -- "$SSHD_DROPIN" "$FAIL2BAN_JAIL"
  if command -v sshd >/dev/null 2>&1; then
    sshd -t || die "После удаления drop-in конфигурация SSH не прошла проверку"
  fi
  for ssh_service in ssh sshd; do
    if service_exists "$ssh_service"; then
      systemctl restart "$ssh_service"
      log "SSH перезапущен; проверьте новый вход через порт 22"
      break
    fi
  done
  service_exists fail2ban && systemctl restart fail2ban >/dev/null 2>&1 || true

  if [[ -n "$configured_user" && "$configured_user" != root ]] && id "$configured_user" >/dev/null 2>&1; then
    rm -f -- "/etc/sudoers.d/${configured_user}"
    if ask_yes_no "Удалить созданного администратора ${configured_user} вместе с домашней папкой?" no; then
      if [[ -n "$login_user" && "$configured_user" == "$login_user" ]]; then
        warn "Нельзя удалить пользователя текущей sudo/SSH-сессии: ${configured_user}"
      else
        read -rp "Для удаления введите имя пользователя ${configured_user}: " confirmation
        if [[ "$confirmation" == "$configured_user" ]]; then
          userdel --remove "$configured_user"
          log "Пользователь ${configured_user} удалён"
        else
          warn "Имя не совпало; пользователь оставлен"
        fi
      fi
    else
      warn "Пользователь ${configured_user} и его членство в группах оставлены"
    fi
  fi

  rm -f -- "$SETUP_ENV" "$SETUP_HASH"
  rmdir /root/setup-data >/dev/null 2>&1 || true
}

remove_telegram() {
  if [[ -f "$PAM_SSHD" && ! -L "$PAM_SSHD" ]]; then
    cp -a -- "$PAM_SSHD" "${PAM_SSHD}.bak.before-ochenstarik-uninstall.$(date +%F-%H%M%S)"
    sed -i "\|${TELEGRAM_SCRIPT}|d;\|${TELEGRAM_LEGACY_SCRIPT}|d" "$PAM_SSHD"
  fi
  rm -f -- "$TELEGRAM_CONFIG" "$TELEGRAM_SCRIPT" "$TELEGRAM_LEGACY_SCRIPT" \
    "$TELEGRAM_LOG" "$TELEGRAM_LOGROTATE"
  find "$CONFIG_DIR" -maxdepth 1 -type f -name 'telegram.conf.bak.*' -delete 2>/dev/null || true
  command -v sshd >/dev/null 2>&1 && sshd -t \
    || warn "Не удалось проверить SSH после удаления Telegram PAM-hook"
}

remove_xray() {
  stop_disable_service ochenstarik-xray-rollback.timer
  stop_disable_service ochenstarik-xray-rollback.service
  stop_disable_service ochenstarik-xray-routing.service
  [[ ! -x "$XRAY_HELPER" ]] || "$XRAY_HELPER" stop >/dev/null 2>&1 || true
  if command -v nft >/dev/null 2>&1; then
    nft list table ip ochenstarik_xray >/dev/null 2>&1 \
      && nft delete table ip ochenstarik_xray || true
    nft list table ip6 ochenstarik_xray6 >/dev/null 2>&1 \
      && nft delete table ip6 ochenstarik_xray6 || true
  fi
  stop_disable_service xray.service
  stop_disable_service xray@.service
  rm -f -- "$XRAY_HELPER" "$XRAY_SERVICE" /etc/systemd/system/xray.service \
    /etc/systemd/system/xray@.service /usr/local/bin/xray
  rm -rf -- "$XRAY_STATE_DIR" "$XRAY_CONFIG_DIR" "$XRAY_SHARE_DIR" "$XRAY_LOG_DIR"
}

remove_panel_and_warp() {
  stop_disable_service x-ui.service
  if command -v warp-cli >/dev/null 2>&1; then
    warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
    warp-cli --accept-tos registration delete >/dev/null 2>&1 || true
  fi
  stop_disable_service warp-svc.service

  rm -f -- /etc/systemd/system/x-ui.service /usr/bin/x-ui /usr/local/bin/x-ui
  rm -rf -- /usr/local/x-ui /etc/x-ui

  if command -v apt-get >/dev/null 2>&1 && dpkg-query -W -f='${Status}' cloudflare-warp \
    2>/dev/null | grep -Fqx 'install ok installed'; then
    DEBIAN_FRONTEND=noninteractive apt-get purge -y cloudflare-warp
  fi
  rm -f -- /etc/apt/sources.list.d/cloudflare-client.list \
    /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
}

read_backup_root() {
  local value="/var/backups/ochenstarik-server"
  if [[ -f "$BACKUP_CONFIG" && ! -L "$BACKUP_CONFIG" ]]; then
    [[ "$(stat -c '%u' "$BACKUP_CONFIG")" == 0 ]] \
      || die "Файл $BACKUP_CONFIG должен принадлежать root"
    value="$(bash -c 'set -efu; source "$1"; printf "%s" "$BACKUP_ROOT"' \
      _ "$BACKUP_CONFIG")"
  fi
  [[ "$value" == /* && "$value" != / ]] || die "Опасный путь резервных копий: $value"
  case "$value" in
    /var|/var/backups|/home|/root|/mnt|/media|/etc|/usr|/opt)
      warn "Общий каталог ${value} не будет очищен автоматически"
      printf ''
      return 0
      ;;
  esac
  printf '%s' "$value"
}

remove_backup_automation() {
  local schedule backup_root
  for schedule in daily weekly monthly; do
    stop_disable_service "ochenstarik-backup-${schedule}.timer"
  done
  rm -f -- /etc/systemd/system/ochenstarik-backup@.service \
    /etc/systemd/system/ochenstarik-backup-daily.timer \
    /etc/systemd/system/ochenstarik-backup-weekly.timer \
    /etc/systemd/system/ochenstarik-backup-monthly.timer "$BACKUP_RUNNER"

  backup_root="$(read_backup_root)"
  if [[ -n "$backup_root" && -d "$backup_root" ]] \
    && ask_yes_no "Удалить все архивы из ${backup_root}?" no; then
    read -rp 'Для необратимого удаления введите УДАЛИТЬ БЭКАПЫ: ' confirmation
    if [[ "$confirmation" == 'УДАЛИТЬ БЭКАПЫ' ]]; then
      if command -v chattr >/dev/null 2>&1; then
        find "$backup_root" -xdev -type f -exec chattr -i -- {} + 2>/dev/null || true
      fi
      rm -rf -- "$backup_root/initial" "$backup_root/daily" \
        "$backup_root/weekly" "$backup_root/monthly"
      log "Архивы проекта удалены"
    else
      warn "Фраза не совпала; архивы оставлены"
    fi
  else
    warn "Архивы оставлены; они не помешают повторной установке"
  fi
  rm -f -- "$BACKUP_CONFIG"
}

restore_locale() {
  local package_name
  local -a packages=()
  if [[ -f "$LOCALE_BACKUP" && ! -L "$LOCALE_BACKUP" ]]; then
    cp -a -- "$LOCALE_BACKUP" /etc/default/locale
    log "Предыдущая системная локаль восстановлена"
  elif [[ -f "$LOCALE_ABSENT_MARKER" && ! -L "$LOCALE_ABSENT_MARKER" ]]; then
    rm -f -- /etc/default/locale
    log "Созданный скриптом файл локали удалён"
  fi

  if [[ -f "$LOCALE_PACKAGES" && ! -L "$LOCALE_PACKAGES" ]]; then
    while IFS= read -r package_name || [[ -n "$package_name" ]]; do
      [[ "$package_name" =~ ^[a-z0-9][a-z0-9+.-]*$ ]] && packages+=("$package_name")
    done < "$LOCALE_PACKAGES"
    if ((${#packages[@]} > 0)) && ask_yes_no \
      "Удалить пакеты русификации, которые ранее отсутствовали?" yes; then
      DEBIAN_FRONTEND=noninteractive apt-get purge -y "${packages[@]}"
    fi
  fi
  rm -f -- "$LOCALE_BACKUP" "$LOCALE_ABSENT_MARKER" "$LOCALE_PACKAGES"
}

remove_swap() {
  [[ -e "$SWAP_SYSCTL_FILE" || -e "$SWAPFILE" ]] || return 0
  ask_yes_no "Отключить и удалить ${SWAPFILE}?" yes || return 0
  swapoff "$SWAPFILE" >/dev/null 2>&1 || true
  if [[ -f /etc/fstab && ! -L /etc/fstab ]]; then
    cp -a -- /etc/fstab "/etc/fstab.bak.before-ochenstarik-uninstall.$(date +%F-%H%M%S)"
    sed -i '\|^[[:space:]]*/swapfile[[:space:]].*[[:space:]]swap[[:space:]]|d' /etc/fstab
  fi
  rm -f -- "$SWAP_SYSCTL_FILE"
  if [[ -f "$SWAPFILE" && ! -L "$SWAPFILE" ]]; then
    rm -f -- "$SWAPFILE"
  else
    warn "${SWAPFILE} не является обычным файлом и не удалён"
  fi
  sysctl --system >/dev/null 2>&1 || true
}

[[ "$EUID" -eq 0 ]] || die "Запустите скрипт от имени root"

cat <<'WARNING'

Этот скрипт удалит настройки, службы и данные, созданные проектом lightweight-server.
Он не откатывает обновления Ubuntu и не удаляет общие системные пакеты (OpenSSH,
UFW, curl, мультимедийные библиотеки и другие), потому что они могли существовать
до установки и нужны для доступа к серверу. Их наличие не мешает установке заново.

Сначала будет открыт SSH-порт 22. Не закрывайте текущую сессию, пока не проверите
новый вход после очистки.
WARNING

read -rp 'Для продолжения введите СБРОСИТЬ СЕРВЕР: ' final_confirmation
[[ "$final_confirmation" == 'СБРОСИТЬ СЕРВЕР' ]] || die "Очистка отменена"

remove_ufw_rules
restore_ipv6_defaults
reset_ssh_and_user
remove_telegram
remove_xray
remove_panel_and_warp
remove_backup_automation
restore_locale
remove_swap

rm -f -- "$SSH_PORT_CONFIG" "$IP_FAMILY_CONFIG" "$MANAGED_PORTS_CONFIG"
find "$CONFIG_DIR" -maxdepth 1 -type f -name '*.bak.*' -delete 2>/dev/null || true
rmdir "$CONFIG_DIR" >/dev/null 2>&1 || true
systemctl daemon-reload >/dev/null 2>&1 || true

log "Очистка компонентов lightweight-server завершена"
printf '\nПроверьте вход в новой сессии: ssh -p 22 root@IP_СЕРВЕРА\n'
printf 'После проверки можно снова запускать скрипты установки по порядку.\n'
if [[ -n "$(current_ssh_port)" && "$(current_ssh_port)" != 22 ]]; then
  printf 'Правило текущего старого SSH-порта %s/tcp оставлено. Удалите его после проверки нового входа.\n' \
    "$(current_ssh_port)"
fi
