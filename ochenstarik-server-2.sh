#!/usr/bin/env bash
set -Eeuo pipefail

readonly CONFIG_DIR="/etc/ochenstarik-server"
readonly SSH_PORT_CONFIG="${CONFIG_DIR}/ssh-port.conf"
readonly IP_FAMILY_CONFIG="${CONFIG_DIR}/ip-family.conf"
readonly MANAGED_PORTS_CONFIG="${CONFIG_DIR}/ufw-managed-ports.conf"
readonly IPV6_SYSCTL_FILE="/etc/sysctl.d/99-zz-ochenstarik-disable-ipv6.conf"
readonly UFW_DEFAULTS="/etc/default/ufw"
readonly DEFAULT_SSH_PORT="20202"

log() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Не найдена команда: $1"
}

is_valid_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
  ((10#$port >= 1 && 10#$port <= 65535))
}

read_saved_value() {
  local file="$1" key="$2"
  [[ -e "$file" ]] || return 0
  [[ -f "$file" && ! -L "$file" ]] \
    || die "$file должен быть обычным файлом, а не символической ссылкой"
  sed -n "s/^${key}=//p" "$file" | head -n1 | tr -d '\r'
}

select_action() {
  local choice default_choice=1

  [[ ! -e "$IP_FAMILY_CONFIG" ]] || default_choice=2
  printf 'Выберите действие:\n'
  printf '  1) Новая установка или полное обновление пакетов\n'
  printf '  2) Изменить режим IPv4/IPv6 без установки пакетов\n'
  printf '  3) Добавить открытые порты без установки пакетов\n'
  while :; do
    read -rp "Номер действия [${default_choice}]: " choice || die "Ввод был прерван"
    choice="${choice:-$default_choice}"
    case "$choice" in
      1) ACTION=install; return 0 ;;
      2) ACTION=ip-mode; return 0 ;;
      3) ACTION=add-ports; return 0 ;;
      *) warn "Введите 1, 2 или 3" ;;
    esac
  done
}

choose_ssh_port() {
  local default_port="$DEFAULT_SSH_PORT" saved_port selected_port

  saved_port="$(read_saved_value "$SSH_PORT_CONFIG" SSH_PORT)"
  if [[ -n "$saved_port" ]]; then
    if is_valid_port "$saved_port"; then
      default_port="$((10#$saved_port))"
    else
      warn "Сохранённый SSH-порт некорректен: $saved_port"
    fi
  fi

  while :; do
    read -rp "SSH-порт для этапа 3 [${default_port}]: " selected_port \
      || die "Ввод был прерван"
    selected_port="${selected_port:-$default_port}"
    if is_valid_port "$selected_port"; then
      SSH_PORT="$((10#$selected_port))"
      return 0
    fi
    warn "SSH-порт должен быть числом от 1 до 65535"
  done
}

choose_ip_mode() {
  local saved_mode default_choice choice

  saved_mode="$(read_saved_value "$IP_FAMILY_CONFIG" IP_MODE)"
  case "$saved_mode" in
    ipv4) default_choice=1 ;;
    ipv6) default_choice=2 ;;
    both) default_choice=3 ;;
    *) default_choice=1 ;;
  esac

  printf '\nВыберите семейства IP для входящих подключений:\n'
  printf '  1) Только IPv4 — IPv6 отключается системно и в UFW\n'
  printf '  2) Только IPv6 — открытые входящие порты доступны лишь по IPv6\n'
  printf '  3) IPv4 + IPv6\n'
  while :; do
    read -rp "Режим [${default_choice}]: " choice || die "Ввод был прерван"
    choice="${choice:-$default_choice}"
    case "$choice" in
      1) IP_MODE=ipv4; return 0 ;;
      2) IP_MODE=ipv6; return 0 ;;
      3) IP_MODE=both; return 0 ;;
      *) warn "Введите 1, 2 или 3" ;;
    esac
  done
}

add_managed_rule() {
  local rule="$1"
  [[ -n "${RULE_SEEN[$rule]:-}" ]] && return 0
  MANAGED_RULES+=("$rule")
  RULE_SEEN["$rule"]=1
}

load_managed_rules() {
  local rule port protocol
  MANAGED_RULES=()
  RULE_SEEN=()
  [[ -e "$MANAGED_PORTS_CONFIG" ]] || return 0
  [[ -f "$MANAGED_PORTS_CONFIG" && ! -L "$MANAGED_PORTS_CONFIG" ]] \
    || die "$MANAGED_PORTS_CONFIG должен быть обычным файлом"

  while IFS= read -r rule || [[ -n "$rule" ]]; do
    rule="${rule//$'\r'/}"
    [[ -n "$rule" && "$rule" != \#* ]] || continue
    [[ "$rule" =~ ^([0-9]+)/(tcp|udp)$ ]] \
      || die "Некорректное правило в $MANAGED_PORTS_CONFIG: $rule"
    port="${BASH_REMATCH[1]}"
    protocol="${BASH_REMATCH[2]}"
    is_valid_port "$port" || die "Некорректный порт в $MANAGED_PORTS_CONFIG: $port"
    add_managed_rule "$((10#$port))/${protocol}"
  done < "$MANAGED_PORTS_CONFIG"
}

add_default_rules() {
  local saved_ssh_port

  saved_ssh_port="${SSH_PORT:-$(read_saved_value "$SSH_PORT_CONFIG" SSH_PORT)}"
  is_valid_port "$saved_ssh_port" || saved_ssh_port="$DEFAULT_SSH_PORT"
  for rule in \
    22/tcp "$((10#$saved_ssh_port))/tcp" 80/tcp 2096/tcp 443/tcp \
    40000/tcp 63636/tcp; do
    add_managed_rule "$rule"
  done
}

collect_additional_ports() {
  local input normalized token port protocol rule
  local -a tokens additions=()
  local -A additions_seen=()

  printf '\nВведите порты через пробел или запятую. TCP используется по умолчанию.\n'
  printf 'Пример: 80 443/tcp 53/udp 40000\n'
  while :; do
    read -rp 'Порты: ' input || die "Ввод был прерван"
    normalized="${input//,/ }"
    read -r -a tokens <<< "$normalized"
    additions=()
    additions_seen=()
    ((${#tokens[@]} > 0)) || { warn "Введите хотя бы один порт"; continue; }

    for token in "${tokens[@]}"; do
      if [[ ! "$token" =~ ^([0-9]+)(/(tcp|udp))?$ ]]; then
        warn "Некорректное правило: $token"
        additions=()
        break
      fi
      port="${BASH_REMATCH[1]}"
      protocol="${BASH_REMATCH[3]:-tcp}"
      if ! is_valid_port "$port"; then
        warn "Порт должен быть от 1 до 65535: $port"
        additions=()
        break
      fi
      rule="$((10#$port))/${protocol}"
      if [[ -z "${additions_seen[$rule]:-}" ]]; then
        additions+=("$rule")
        additions_seen["$rule"]=1
      fi
    done
    ((${#additions[@]} > 0)) && break
  done

  for rule in "${additions[@]}"; do
    add_managed_rule "$rule"
  done
}

save_configuration() {
  local config_file
  install -d -m 700 -o root -g root "$CONFIG_DIR"
  for config_file in "$SSH_PORT_CONFIG" "$IP_FAMILY_CONFIG" "$MANAGED_PORTS_CONFIG"; do
    [[ ! -L "$config_file" ]] || die "Отказ от записи через символическую ссылку: $config_file"
  done
  printf 'SSH_PORT=%s\n' "$SSH_PORT" > "$SSH_PORT_CONFIG"
  printf '%s\n' "${MANAGED_RULES[@]}" > "$MANAGED_PORTS_CONFIG"
  chown root:root "$SSH_PORT_CONFIG" "$MANAGED_PORTS_CONFIG"
  chmod 600 "$SSH_PORT_CONFIG" "$MANAGED_PORTS_CONFIG"
}

set_ufw_ipv6_setting() {
  local value="$1"
  [[ -f "$UFW_DEFAULTS" && ! -L "$UFW_DEFAULTS" ]] \
    || die "Не найден безопасный файл $UFW_DEFAULTS"
  if grep -q '^IPV6=' "$UFW_DEFAULTS"; then
    sed -i "s/^IPV6=.*/IPV6=${value}/" "$UFW_DEFAULTS"
  else
    printf '\nIPV6=%s\n' "$value" >> "$UFW_DEFAULTS"
  fi
}

disable_ipv6_systemwide() {
  cat > "$IPV6_SYSCTL_FILE" <<'EOF'
# Managed by ochenstarik-server-2.sh
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
  chmod 644 "$IPV6_SYSCTL_FILE"
  sysctl -p "$IPV6_SYSCTL_FILE" >/dev/null
  [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || true)" == 1 ]] \
    || die "Не удалось отключить IPv6"
}

enable_ipv6_systemwide() {
  local sysctl_path
  local -a sysctl_paths=(/proc/sys/net/ipv6/conf/*/disable_ipv6)

  rm -f -- "$IPV6_SYSCTL_FILE"
  for sysctl_path in "${sysctl_paths[@]}"; do
    [[ -e "$sysctl_path" ]] || continue
    printf '0\n' > "$sysctl_path" || die "Не удалось включить IPv6 через $sysctl_path"
  done
}

check_session_safety() {
  local client_ip client_port server_ip server_port

  [[ -n "${SSH_CONNECTION:-}" ]] || return 0
  read -r client_ip client_port server_ip server_port <<< "$SSH_CONNECTION"
  if [[ "$IP_MODE" == ipv4 && "$server_ip" == *:* ]]; then
    die "Текущая SSH-сессия использует IPv6. Сначала подключитесь по IPv4 или используйте консоль провайдера"
  fi
  if [[ "$IP_MODE" == ipv6 && "$server_ip" == *.* ]]; then
    die "Текущая SSH-сессия использует IPv4. Для режима IPv6 подключитесь по IPv6 или используйте консоль провайдера"
  fi
}

verify_ipv6_connectivity() {
  ip -6 address show scope global | grep -q 'inet6' \
    || die "На сервере нет глобального IPv6-адреса"
  ip -6 route show default | grep -q '^default' \
    || die "На сервере нет маршрута IPv6 по умолчанию"
}

delete_managed_ufw_rules() {
  local rule port protocol attempt

  for rule in "${MANAGED_RULES[@]}"; do
    port="${rule%/*}"
    protocol="${rule#*/}"
    for attempt in {1..5}; do
      ufw --force delete allow "$rule" >/dev/null 2>&1 || break
    done
    ufw --force delete allow from 0.0.0.0/0 to any port "$port" proto "$protocol" \
      >/dev/null 2>&1 || true
    ufw --force delete allow from ::/0 to any port "$port" proto "$protocol" \
      >/dev/null 2>&1 || true
  done
}

allow_rule_for_selected_families() {
  local rule="$1" port protocol
  port="${rule%/*}"
  protocol="${rule#*/}"

  if [[ "$IP_MODE" == ipv4 || "$IP_MODE" == both ]]; then
    ufw allow from 0.0.0.0/0 to any port "$port" proto "$protocol"
  fi
  if [[ "$IP_MODE" == ipv6 || "$IP_MODE" == both ]]; then
    ufw allow from ::/0 to any port "$port" proto "$protocol"
  fi
}

apply_ip_mode_and_firewall() {
  local rule

  check_session_safety
  if [[ "$IP_MODE" == ipv4 ]]; then
    delete_managed_ufw_rules
    set_ufw_ipv6_setting no
    disable_ipv6_systemwide
  else
    enable_ipv6_systemwide
    [[ "$IP_MODE" != ipv6 ]] || verify_ipv6_connectivity
    set_ufw_ipv6_setting yes
    ufw reload >/dev/null 2>&1 || true
    delete_managed_ufw_rules
  fi

  ufw default deny incoming
  ufw default allow outgoing
  for rule in "${MANAGED_RULES[@]}"; do
    log "Открываю ${rule} для режима ${IP_MODE}"
    allow_rule_for_selected_families "$rule"
  done
  ufw --force enable
  [[ ! -L "$IP_FAMILY_CONFIG" ]] \
    || die "Отказ от записи через символическую ссылку: $IP_FAMILY_CONFIG"
  printf 'IP_MODE=%s\n' "$IP_MODE" > "$IP_FAMILY_CONFIG"
  chown root:root "$IP_FAMILY_CONFIG"
  chmod 600 "$IP_FAMILY_CONFIG"
}

[[ "$EUID" -eq 0 ]] || die "Запустите этот скрипт от имени root"
declare -a MANAGED_RULES=()
declare -A RULE_SEEN=()
ACTION=""
SSH_PORT=""
IP_MODE=""
select_action

if [[ "$ACTION" == install ]]; then
  choose_ssh_port
  choose_ip_mode
  export DEBIAN_FRONTEND=noninteractive

  log "Обновляю операционную систему"
  apt-get update
  apt-get upgrade -y

  log "Устанавливаю обязательные пакеты SSH, брандмауэра и защиты"
  apt-get install -y \
    sudo ufw fail2ban curl ca-certificates openssl openssh-server logrotate iproute2

  for command_name in ip sed sysctl ufw; do
    require_command "$command_name"
  done
  install -d -m 700 -o root -g root "$CONFIG_DIR"
  load_managed_rules
  add_default_rules
  save_configuration
  apply_ip_mode_and_firewall
  log "SSH-порт ${SSH_PORT} сохранён для этапа 3"
else
  for command_name in ip sed sysctl ufw; do
    require_command "$command_name"
  done
  install -d -m 700 -o root -g root "$CONFIG_DIR"
  SSH_PORT="$(read_saved_value "$SSH_PORT_CONFIG" SSH_PORT)"
  is_valid_port "$SSH_PORT" || SSH_PORT="$DEFAULT_SSH_PORT"
  load_managed_rules
  add_default_rules

  if [[ "$ACTION" == ip-mode ]]; then
    choose_ip_mode
  else
    IP_MODE="$(read_saved_value "$IP_FAMILY_CONFIG" IP_MODE)"
    case "$IP_MODE" in ipv4|ipv6|both) ;; *) choose_ip_mode ;; esac
    collect_additional_ports
  fi
  save_configuration
  apply_ip_mode_and_firewall
fi

log "Текущая конфигурация"
printf 'Режим IP: %s\n' "$IP_MODE"
printf 'IPv6 в ядре: %s\n' "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || printf 'недоступно')"
ufw status verbose

printf '\nГотово. Следующий этап: ochenstarik-server-user-3.sh\n'
printf 'Этап 3 перенесёт SSH на порт %s.\n' "$SSH_PORT"
printf 'Не удаляйте правило порта 22, пока не проверите вход по порту %s.\n' "$SSH_PORT"
