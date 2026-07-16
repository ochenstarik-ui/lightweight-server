#!/usr/bin/env bash
set -Eeuo pipefail

readonly XUI_INSTALL_URL="https://raw.githubusercontent.com/MHSanaei/3x-ui/main/install.sh"
readonly XUI_BINARY="/usr/local/x-ui/x-ui"
readonly XUI_DB="/etc/x-ui/x-ui.db"
readonly CLOUDFLARE_KEY_URL="https://pkg.cloudflareclient.com/pubkey.gpg"
readonly CLOUDFLARE_KEYRING="/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg"
readonly CLOUDFLARE_REPO="/etc/apt/sources.list.d/cloudflare-client.list"
readonly DEFAULT_PANEL_PORT="2053"
readonly DEFAULT_SUBSCRIPTION_PORT="2096"
readonly DEFAULT_WARP_PORT="40000"
readonly SSH_PORT_CONFIG="/etc/ochenstarik-server/ssh-port.conf"
readonly IP_FAMILY_CONFIG="/etc/ochenstarik-server/ip-family.conf"
readonly MANAGED_PORTS_CONFIG="/etc/ochenstarik-server/ufw-managed-ports.conf"

TMP_DIR=""

log() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [[ -n "$TMP_DIR" && "$TMP_DIR" == /tmp/* && -d "$TMP_DIR" ]]; then
    rm -rf -- "$TMP_DIR"
  fi
}
trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Не найдена команда: $1"
}

is_valid_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
  (( 10#$port >= 1 && 10#$port <= 65535 ))
}

port_is_forbidden() {
  local candidate="$1" forbidden
  shift
  for forbidden in "$@"; do
    [[ "$candidate" != "$forbidden" ]] || return 0
  done
  return 1
}

choose_port() {
  local variable_name="$1" label="$2" default_port="$3"
  shift 3
  local selected_port
  local -a forbidden_ports=("$@")

  while :; do
    read -rp "${label} [${default_port}]: " selected_port
    selected_port="${selected_port:-$default_port}"
    if ! is_valid_port "$selected_port"; then
      warn "Порт должен быть числом от 1 до 65535"
      continue
    fi
    selected_port="$((10#$selected_port))"
    if port_is_forbidden "$selected_port" "${forbidden_ports[@]}"; then
      warn "Порт ${selected_port} уже зарезервирован другой службой"
      continue
    fi
    printf -v "$variable_name" '%s' "$selected_port"
    return 0
  done
}

read_saved_ssh_port() {
  local saved_port
  SAVED_SSH_PORT=""
  [[ -e "$SSH_PORT_CONFIG" ]] || return 0
  [[ -f "$SSH_PORT_CONFIG" && ! -L "$SSH_PORT_CONFIG" ]] \
    || die "$SSH_PORT_CONFIG должен быть обычным файлом"
  saved_port="$(sed -n 's/^SSH_PORT=//p' "$SSH_PORT_CONFIG" | head -n1 | tr -d '\r')"
  is_valid_port "$saved_port" || die "Некорректный SSH-порт в $SSH_PORT_CONFIG"
  SAVED_SSH_PORT="$((10#$saved_port))"
}

read_ip_mode() {
  local mode=both
  if [[ -e "$IP_FAMILY_CONFIG" ]]; then
    [[ -f "$IP_FAMILY_CONFIG" && ! -L "$IP_FAMILY_CONFIG" ]] \
      || die "$IP_FAMILY_CONFIG должен быть обычным файлом"
    mode="$(sed -n 's/^IP_MODE=//p' "$IP_FAMILY_CONFIG" | head -n1 | tr -d '\r')"
  fi
  case "$mode" in ipv4|ipv6|both) printf '%s' "$mode" ;; *) die "Некорректный IP_MODE: $mode" ;; esac
}

record_managed_ufw_rule() {
  local rule="$1"
  install -d -m 700 -o root -g root "$(dirname "$MANAGED_PORTS_CONFIG")"
  [[ ! -L "$MANAGED_PORTS_CONFIG" ]] || die "$MANAGED_PORTS_CONFIG не должен быть символической ссылкой"
  touch "$MANAGED_PORTS_CONFIG"
  grep -Fqx -- "$rule" "$MANAGED_PORTS_CONFIG" || printf '%s\n' "$rule" >> "$MANAGED_PORTS_CONFIG"
  chown root:root "$MANAGED_PORTS_CONFIG"
  chmod 600 "$MANAGED_PORTS_CONFIG"
}

wait_for_tcp_listener() {
  local port="$1" description="$2" attempt
  for attempt in {1..20}; do
    if ss -H -ltn "sport = :${port}" | grep -q .; then
      log "${description} слушает TCP-порт ${port}"
      return 0
    fi
    sleep 1
  done
  die "${description} не открыл TCP-порт ${port}"
}

choose_public_access() {
  local answer
  printf '\nДоступ к панели 3x-ui и подпискам:\n'
  printf '  1) Приватный режим: не открывать порты панели и подписок в UFW (рекомендуется)\n'
  printf '  2) Публичный режим: открыть порты панели и подписок всему Интернету\n'
  while :; do
    read -rp 'Режим доступа [1]: ' answer
    answer="${answer:-1}"
    case "$answer" in
      1) XUI_PUBLIC_ACCESS=no; return 0 ;;
      2)
        warn "Публичный доступ к панели опасен. Используйте сложный путь, новые учётные данные, TLS и 2FA"
        XUI_PUBLIC_ACCESS=yes
        return 0
        ;;
      *) warn "Введите 1 или 2" ;;
    esac
  done
}

allow_ufw_port() {
  local port="$1" description="$2" mode
  mode="$(read_ip_mode)"
  log "UFW: открываю ${port}/tcp (${description})"
  record_managed_ufw_rule "${port}/tcp"
  if [[ "$mode" == ipv4 || "$mode" == both ]]; then
    ufw allow from 0.0.0.0/0 to any port "$port" proto tcp
  fi
  if [[ "$mode" == ipv6 || "$mode" == both ]]; then
    ufw allow from ::/0 to any port "$port" proto tcp
  fi
}

verify_ufw_port() {
  local port="$1" mode status
  mode="$(read_ip_mode)"
  status="$(LANG=C ufw status)"
  if [[ "$mode" == ipv4 || "$mode" == both ]]; then
    grep -Eq "^${port}/tcp[[:space:]]+ALLOW" <<< "$status" \
      || die "В UFW не найдено IPv4-правило для ${port}/tcp"
  fi
  if [[ "$mode" == ipv6 || "$mode" == both ]]; then
    grep -Eq "^${port}/tcp \(v6\)[[:space:]]+ALLOW" <<< "$status" \
      || die "В UFW не найдено IPv6-правило для ${port}/tcp"
  fi
}

set_xui_setting() {
  local key="$1" value="$2"
  sqlite3 "$XUI_DB" <<SQL
BEGIN IMMEDIATE;
UPDATE settings SET value = '${value}' WHERE key = '${key}';
INSERT INTO settings (key, value)
SELECT '${key}', '${value}'
WHERE NOT EXISTS (SELECT 1 FROM settings WHERE key = '${key}');
COMMIT;
SQL
}

configure_xui_ports() {
  local backup_file panel_value subscription_value

  [[ -x "$XUI_BINARY" ]] || die "После установки не найден $XUI_BINARY"
  [[ -f "$XUI_DB" && ! -L "$XUI_DB" ]] \
    || die "Поддерживается стандартная SQLite-база 3x-ui: $XUI_DB"

  backup_file="${XUI_DB}.bak.$(date +%F-%H%M%S-%N)"
  cp -a -- "$XUI_DB" "$backup_file"
  log "Резервная копия базы 3x-ui: ${backup_file}"

  systemctl stop x-ui.service >/dev/null 2>&1 || true
  if ! "$XUI_BINARY" setting -port "$PANEL_PORT"; then
    cp -a -- "$backup_file" "$XUI_DB"
    systemctl start x-ui.service >/dev/null 2>&1 || true
    die "Не удалось изменить порт панели 3x-ui"
  fi

  if ! set_xui_setting subPort "$SUBSCRIPTION_PORT" \
    || ! set_xui_setting subEnable true; then
    cp -a -- "$backup_file" "$XUI_DB"
    systemctl start x-ui.service >/dev/null 2>&1 || true
    die "Не удалось изменить порт подписок 3x-ui; база восстановлена"
  fi

  systemctl daemon-reload
  systemctl enable --now x-ui.service
  systemctl restart x-ui.service
  systemctl is-active --quiet x-ui.service || die "Служба x-ui не запущена"

  panel_value="$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='webPort' LIMIT 1;")"
  subscription_value="$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='subPort' LIMIT 1;")"
  [[ "$panel_value" == "$PANEL_PORT" ]] \
    || die "В базе 3x-ui указан неожиданный порт панели: ${panel_value:-пусто}"
  [[ "$subscription_value" == "$SUBSCRIPTION_PORT" ]] \
    || die "В базе 3x-ui указан неожиданный порт подписок: ${subscription_value:-пусто}"
  XUI_WEB_PATH="$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='webBasePath' LIMIT 1;")"
  XUI_SUB_PATH="$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='subPath' LIMIT 1;")"
  [[ "$XUI_WEB_PATH" == /* ]] || XUI_WEB_PATH="/${XUI_WEB_PATH}"
  [[ "$XUI_SUB_PATH" == /* ]] || XUI_SUB_PATH="/${XUI_SUB_PATH}"
}

install_cloudflare_warp() {
  local os_id version_codename architecture key_file keyring_file

  os_id="$(sed -n 's/^ID=//p' /etc/os-release | head -n1 | tr -d '\"')"
  version_codename="$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release | head -n1 | tr -d '\"')"
  architecture="$(dpkg --print-architecture)"
  [[ "$architecture" == amd64 || "$architecture" == arm64 ]] \
    || die "Cloudflare WARP поддерживает здесь только amd64 и arm64; получено: $architecture"

  case "${os_id}:${version_codename}" in
    ubuntu:jammy|ubuntu:noble|ubuntu:resolute|debian:bookworm|debian:trixie)
      ;;
    *)
      die "Неподдерживаемая Cloudflare WARP система: ${os_id} ${version_codename}"
      ;;
  esac

  key_file="${TMP_DIR}/cloudflare-warp.gpg"
  keyring_file="${TMP_DIR}/cloudflare-warp-archive-keyring.gpg"
  curl --fail --silent --show-error --location \
    --proto '=https' --tlsv1.2 "$CLOUDFLARE_KEY_URL" -o "$key_file"
  gpg --batch --yes --dearmor --output "$keyring_file" "$key_file"
  install -o root -g root -m 644 "$keyring_file" "$CLOUDFLARE_KEYRING"

  printf 'deb [signed-by=%s] https://pkg.cloudflareclient.com/ %s main\n' \
    "$CLOUDFLARE_KEYRING" "$version_codename" > "$CLOUDFLARE_REPO"
  chmod 644 "$CLOUDFLARE_REPO"

  apt-get update
  apt-get install -y cloudflare-warp
  systemctl enable --now warp-svc.service
  require_command warp-cli

  if ! warp-cli --accept-tos registration show >/dev/null 2>&1; then
    warp-cli --accept-tos registration new
  fi
  warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
  warp-cli --accept-tos tunnel protocol set MASQUE
  warp-cli --accept-tos mode proxy
  warp-cli --accept-tos proxy port "$WARP_PORT"
  warp-cli --accept-tos connect
}

verify_warp_proxy() {
  local trace attempt

  wait_for_tcp_listener "$WARP_PORT" "Cloudflare WARP local proxy"
  trace=""
  for attempt in {1..20}; do
    trace="$(curl --fail --silent --show-error --max-time 15 \
      --proxy "socks5h://127.0.0.1:${WARP_PORT}" \
      https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
    grep -Fqx 'warp=on' <<< "$trace" && break
    sleep 1
  done
  grep -Fqx 'warp=on' <<< "$trace" \
    || die "Проверка Cloudflare через локальный proxy не вернула warp=on"
  log "Cloudflare WARP работает через 127.0.0.1:${WARP_PORT}"
}

[[ "$EUID" -eq 0 ]] || die "Запустите этот скрипт от имени root"
for command_name in apt-get dpkg grep install sed systemctl tr; do
  require_command "$command_name"
done

read_saved_ssh_port
forbidden_common=("22" "80" "443")
[[ -z "$SAVED_SSH_PORT" ]] || forbidden_common+=("$SAVED_SSH_PORT")

PANEL_PORT=""
SUBSCRIPTION_PORT=""
WARP_PORT=""
XUI_PUBLIC_ACCESS=no
XUI_WEB_PATH="/"
XUI_SUB_PATH="/sub/"
choose_port PANEL_PORT "Порт панели 3x-ui" "$DEFAULT_PANEL_PORT" "${forbidden_common[@]}"
choose_port SUBSCRIPTION_PORT "Порт подписок 3x-ui" "$DEFAULT_SUBSCRIPTION_PORT" \
  "${forbidden_common[@]}" "$PANEL_PORT"
choose_port WARP_PORT "Локальный proxy-порт WARP" "$DEFAULT_WARP_PORT" \
  "${forbidden_common[@]}" "$PANEL_PORT" "$SUBSCRIPTION_PORT"
choose_public_access

printf '\nБудут использованы порты:\n'
printf '  3x-ui panel: %s/tcp\n' "$PANEL_PORT"
printf '  3x-ui subscriptions: %s/tcp\n' "$SUBSCRIPTION_PORT"
printf '  WARP local proxy: 127.0.0.1:%s/tcp\n\n' "$WARP_PORT"
if [[ "$XUI_PUBLIC_ACCESS" == yes ]]; then
  printf '  UFW: порты панели и подписок будут открыты публично\n\n'
else
  printf '  UFW: порты панели и подписок не будут открыты публично\n\n'
fi

export DEBIAN_FRONTEND=noninteractive
log "Установка системных зависимостей"
apt-get update
apt-get install -y ca-certificates curl gnupg iproute2 sqlite3 ufw
for command_name in curl gpg sqlite3 ss ufw; do
  require_command "$command_name"
done

TMP_DIR="$(mktemp -d)"
chmod 700 "$TMP_DIR"

log "Загрузка официального установщика 3x-ui"
XUI_INSTALLER="${TMP_DIR}/3x-ui-install.sh"
curl --fail --silent --show-error --location \
  --proto '=https' --tlsv1.2 "$XUI_INSTALL_URL" -o "$XUI_INSTALLER"
chmod 700 "$XUI_INSTALLER"
bash -n "$XUI_INSTALLER"
bash "$XUI_INSTALLER"

log "Настройка портов 3x-ui"
configure_xui_ports

log "Установка и настройка Cloudflare WARP"
install_cloudflare_warp

log "Настройка UFW"
allow_ufw_port 80 "HTTP"
allow_ufw_port 443 "HTTPS"
if [[ "$XUI_PUBLIC_ACCESS" == yes ]]; then
  allow_ufw_port "$PANEL_PORT" "панель 3x-ui"
  allow_ufw_port "$SUBSCRIPTION_PORT" "подписки 3x-ui"
else
  log "UFW: порты панели и подписок оставлены закрытыми для публичного Интернета"
fi
ufw --force enable

for port in 80 443; do
  verify_ufw_port "$port"
done
if [[ "$XUI_PUBLIC_ACCESS" == yes ]]; then
  for port in "$PANEL_PORT" "$SUBSCRIPTION_PORT"; do
    verify_ufw_port "$port"
  done
fi

wait_for_tcp_listener "$PANEL_PORT" "Панель 3x-ui"
wait_for_tcp_listener "$SUBSCRIPTION_PORT" "Сервис подписок 3x-ui"
verify_warp_proxy

printf '\nУстановка завершена.\n'
printf 'Панель 3x-ui:          http(s)://<server-ip>:%s%s\n' "$PANEL_PORT" "$XUI_WEB_PATH"
printf 'Подписки 3x-ui:        http(s)://<server-ip>:%s%s\n' "$SUBSCRIPTION_PORT" "$XUI_SUB_PATH"
printf 'Локальный WARP proxy:  socks5://127.0.0.1:%s\n' "$WARP_PORT"
printf '\nПорт WARP не открыт публично в UFW: локальный proxy не требует аутентификации.\n'
if [[ "$XUI_PUBLIC_ACCESS" != yes ]]; then
  printf 'Порты панели и подписок не открыты публично. Используйте SSH tunnel, management VPN или повторный запуск с явным публичным режимом.\n'
fi
printf 'Настройте TLS, сложный путь панели, новые учётные данные и двухфакторную аутентификацию в 3x-ui.\n'
