#!/usr/bin/env bash
set -Eeuo pipefail

readonly APP_NAME="ochenstarik-server-monitor-manager"
readonly MONITOR_USER="ochenstarik-monitor"
readonly MONITOR_HOME="/var/lib/${APP_NAME}"
readonly MONITOR_COMMAND="/usr/local/libexec/ochenstarik-server-monitor"
readonly AUTHORIZED_KEYS="${MONITOR_HOME}/.ssh/authorized_keys"
readonly MESH_DIR="/etc/${APP_NAME}"
readonly NODES_DIR="${MESH_DIR}/nodes"
readonly HUB_CONFIG="${MESH_DIR}/hub.conf"
readonly HUB_PRIVATE_KEY="${MESH_DIR}/hub.key"
readonly LINKS_FILE="${MESH_DIR}/links"
readonly HUB_HELPER="/usr/local/libexec/ochenstarik-smm-hub"
readonly HUB_CLI="/usr/local/sbin/ochenstarik-smm"
readonly WG_INTERFACE="smm0"
readonly WG_CONFIG="/etc/wireguard/${WG_INTERFACE}.conf"
readonly MESH_CIDR="10.77.0.0/24"
readonly HUB_ADDRESS="10.77.0.1"
readonly DEFAULT_WG_PORT="51820"

log() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

require_root() {
  [[ "$EUID" -eq 0 ]] || die "Запустите скрипт через sudo"
}

detect_system() {
  [[ -r /etc/os-release ]] || die "Не найден /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) ;;
    *) die "Поддерживаются Ubuntu и Debian; обнаружено: ${ID:-unknown}" ;;
  esac
  command -v systemctl >/dev/null 2>&1 || die "Требуется systemd"
}

read_public_key() {
  if [[ -n "${SERVER_MONITOR_PUBLIC_KEY:-}" ]]; then
    PUBLIC_KEY="$SERVER_MONITOR_PUBLIC_KEY"
    log "Публичный ключ получен из SERVER_MONITOR_PUBLIC_KEY"
  else
    printf '\nВ Windows-приложении нажмите «SSH-ключ» → «Копировать».\n'
    if [[ -r /dev/tty ]]; then
      IFS= read -r -p 'Вставьте публичный ключ: ' PUBLIC_KEY < /dev/tty
    else
      die "Нет интерактивного терминала. Передайте ключ через SERVER_MONITOR_PUBLIC_KEY"
    fi
  fi
  PUBLIC_KEY="${PUBLIC_KEY//$'\r'/}"
  [[ "$PUBLIC_KEY" =~ ^ssh-ed25519[[:space:]]+[A-Za-z0-9+/]+={0,3}([[:space:]].*)?$ ]] \
    || die "Ожидается публичный ключ формата ssh-ed25519 AAAA..."
}

install_monitor_dependencies() {
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates openssh-server openssh-client coreutils gawk
  systemctl enable --now ssh
}

install_mesh_dependencies() {
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    wireguard-tools nftables iproute2 jq openssl
}

verify_public_key() {
  local key_file
  key_file="$(mktemp)"
  trap 'rm -f -- "${key_file:-}"' RETURN
  printf '%s\n' "$PUBLIC_KEY" > "$key_file"
  ssh-keygen -l -f "$key_file" >/dev/null \
    || die "ssh-keygen отклонил публичный ключ"
  trap - RETURN
  rm -f -- "$key_file"
}

create_monitor_command() {
  install -d -m 0755 -o root -g root "$(dirname "$MONITOR_COMMAND")"
  [[ ! -L "$MONITOR_COMMAND" ]] \
    || die "Отказ от записи через символическую ссылку: $MONITOR_COMMAND"
  cat > "$MONITOR_COMMAND" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

readonly HUB_HELPER="/usr/local/libexec/ochenstarik-smm-hub"
original_command="${SSH_ORIGINAL_COMMAND:-metrics}"

case "$original_command" in
  ""|metrics) ;;
  "mesh nodes")
    [[ -x "$HUB_HELPER" ]] || { echo "Mesh Hub не установлен" >&2; exit 1; }
    exec sudo -n "$HUB_HELPER" nodes
    ;;
  "mesh links")
    [[ -x "$HUB_HELPER" ]] || { echo "Mesh Hub не установлен" >&2; exit 1; }
    exec sudo -n "$HUB_HELPER" links
    ;;
  "mesh status")
    [[ -x "$HUB_HELPER" ]] || { echo "Mesh Hub не установлен" >&2; exit 1; }
    exec sudo -n "$HUB_HELPER" status
    ;;
  "mesh connect "*)
    [[ -x "$HUB_HELPER" ]] || { echo "Mesh Hub не установлен" >&2; exit 1; }
    read -r prefix action source target extra <<< "$original_command"
    [[ "$prefix" == mesh && "$action" == connect && -n "$source" && -n "$target" && -z "${extra:-}" ]] \
      || { echo "Некорректная команда" >&2; exit 2; }
    exec sudo -n "$HUB_HELPER" link-connect "$source" "$target"
    ;;
  "mesh disconnect "*)
    [[ -x "$HUB_HELPER" ]] || { echo "Mesh Hub не установлен" >&2; exit 1; }
    read -r prefix action source target extra <<< "$original_command"
    [[ "$prefix" == mesh && "$action" == disconnect && -n "$source" && -n "$target" && -z "${extra:-}" ]] \
      || { echo "Некорректная команда" >&2; exit 2; }
    exec sudo -n "$HUB_HELPER" link-disconnect "$source" "$target"
    ;;
  *)
    echo "Разрешены только metrics и команды mesh" >&2
    exit 2
    ;;
esac

read_mem_value() {
  awk -v key="$1" '$1 == key ":" { print $2; exit }' /proc/meminfo
}

printf 'PROTOCOL=1\n'
printf 'HOSTNAME=%s\n' "$(hostname)"
printf 'UPTIME_SECONDS=%s\n' "$(cut -d. -f1 /proc/uptime)"
printf 'LOAD1=%s\n' "$(cut -d' ' -f1 /proc/loadavg)"
printf 'CPU_COUNT=%s\n' "$(getconf _NPROCESSORS_ONLN)"
printf 'MEM_TOTAL_KB=%s\n' "$(read_mem_value MemTotal)"
printf 'MEM_AVAILABLE_KB=%s\n' "$(read_mem_value MemAvailable)"
df -Pk / | awk 'NR == 2 {
  printf "DISK_TOTAL_KB=%s\nDISK_AVAILABLE_KB=%s\n", $2, $4
}'
printf 'KERNEL=%s\n' "$(uname -r)"
EOF
  chown root:root "$MONITOR_COMMAND"
  chmod 0755 "$MONITOR_COMMAND"
}

create_monitor_user() {
  if ! getent passwd "$MONITOR_USER" >/dev/null; then
    useradd \
      --system \
      --create-home \
      --home-dir "$MONITOR_HOME" \
      --shell /bin/bash \
      "$MONITOR_USER"
  fi
  usermod --home "$MONITOR_HOME" --shell /bin/bash "$MONITOR_USER"
  passwd -l "$MONITOR_USER" >/dev/null 2>&1 || true

  install -d -m 0750 -o "$MONITOR_USER" -g "$MONITOR_USER" "$MONITOR_HOME"
  install -d -m 0700 -o "$MONITOR_USER" -g "$MONITOR_USER" "${MONITOR_HOME}/.ssh"
  [[ ! -L "$AUTHORIZED_KEYS" ]] \
    || die "Отказ от записи через символическую ссылку: $AUTHORIZED_KEYS"
  printf 'restrict,command="%s" %s\n' "$MONITOR_COMMAND" "$PUBLIC_KEY" > "$AUTHORIZED_KEYS"
  chown "$MONITOR_USER:$MONITOR_USER" "$AUTHORIZED_KEYS"
  chmod 0600 "$AUTHORIZED_KEYS"
}

verify_sshd() {
  sshd -t
  sshd -T | grep -qi '^pubkeyauthentication yes$' \
    || die "В sshd отключена аутентификация по публичному ключу"
}

install_monitoring() {
  read_public_key
  install_monitor_dependencies
  verify_public_key
  create_monitor_command
  create_monitor_user
  verify_sshd
  systemctl reload ssh
}

create_hub_helper() {
  install -d -m 0755 -o root -g root "$(dirname "$HUB_HELPER")"
  cat > "$HUB_HELPER" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

readonly STATE_DIR="/etc/ochenstarik-server-monitor-manager"
readonly NODES_DIR="${STATE_DIR}/nodes"
readonly HUB_CONFIG="${STATE_DIR}/hub.conf"
readonly HUB_PRIVATE_KEY="${STATE_DIR}/hub.key"
readonly LINKS_FILE="${STATE_DIR}/links"
readonly WG_INTERFACE="smm0"
readonly WG_CONFIG="/etc/wireguard/${WG_INTERFACE}.conf"
readonly NFT_TABLE="ochenstarik_smm"

die() { printf '[x] %s\n' "$*" >&2; exit 1; }
log() { printf '[+] %s\n' "$*"; }
require_root() { [[ "$EUID" -eq 0 ]] || die "Требуются права root"; }
valid_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]]; }

config_value() {
  local key="$1" file="$2"
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$file"
}

node_file() { printf '%s/%s.node' "$NODES_DIR" "$1"; }
node_value() { config_value "$2" "$(node_file "$1")"; }
node_exists() { [[ -f "$(node_file "$1")" ]]; }

render_wireguard_config() {
  local tmp name file public_key address
  tmp="$(mktemp)"
  {
    printf '[Interface]\n'
    printf 'Address = %s/24\n' "$(config_value HUB_ADDRESS "$HUB_CONFIG")"
    printf 'ListenPort = %s\n' "$(config_value WG_PORT "$HUB_CONFIG")"
    printf 'PrivateKey = %s\n' "$(<"$HUB_PRIVATE_KEY")"
    for file in "$NODES_DIR"/*.node; do
      [[ -e "$file" ]] || continue
      name="$(config_value NAME "$file")"
      public_key="$(config_value PUBLIC_KEY "$file")"
      address="$(config_value ADDRESS "$file")"
      printf '\n# SMM-NODE %s\n' "$name"
      printf '[Peer]\nPublicKey = %s\nAllowedIPs = %s/32\n' "$public_key" "$address"
    done
  } > "$tmp"
  install -m 0600 -o root -g root "$tmp" "$WG_CONFIG"
  rm -f -- "$tmp"
  if ip link show "$WG_INTERFACE" >/dev/null 2>&1; then
    wg syncconf "$WG_INTERFACE" <(wg-quick strip "$WG_INTERFACE")
  fi
}

next_address() {
  local host address file used
  for host in $(seq 2 254); do
    address="10.77.0.${host}"
    used=false
    for file in "$NODES_DIR"/*.node; do
      [[ -e "$file" ]] || continue
      if [[ "$(config_value ADDRESS "$file")" == "$address" ]]; then
        used=true
        break
      fi
    done
    [[ "$used" == true ]] || { printf '%s' "$address"; return 0; }
  done
  die "В подсети 10.77.0.0/24 закончились адреса"
}

base64url_encode() {
  base64 -w0 | tr '+/' '-_' | tr -d '='
}

node_code() {
  local name="$1" private_key public_key address endpoint port payload code file
  valid_name "$name" || die "Имя: строчные латинские буквы, цифры и дефис, максимум 32 символа"
  node_exists "$name" && die "Узел $name уже существует"
  private_key="$(wg genkey)"
  public_key="$(printf '%s' "$private_key" | wg pubkey)"
  address="$(next_address)"
  endpoint="$(config_value HUB_ENDPOINT "$HUB_CONFIG")"
  port="$(config_value WG_PORT "$HUB_CONFIG")"
  file="$(node_file "$name")"
  umask 077
  {
    printf 'NAME=%s\n' "$name"
    printf 'ADDRESS=%s\n' "$address"
    printf 'PUBLIC_KEY=%s\n' "$public_key"
  } > "$file"
  render_wireguard_config
  payload="$(printf 'VERSION=1\nNAME=%s\nADDRESS=%s/32\nPRIVATE_KEY=%s\nHUB_PUBLIC_KEY=%s\nENDPOINT=%s:%s\nALLOWED_IPS=10.77.0.0/24\n' \
    "$name" "$address" "$private_key" "$(wg pubkey < "$HUB_PRIVATE_KEY")" "$endpoint" "$port")"
  code="SMM1-$(printf '%s' "$payload" | base64url_encode)"
  unset private_key payload
  printf '\nСекретный код конфигурации для узла %s:\n%s\n\n' "$name" "$code"
  printf 'Код содержит приватный ключ узла. Используйте его только на одном целевом сервере и не сохраняйте в чатах или логах.\n'
}

restore_firewall() {
  local tmp source target source_ip target_ip first=true
  tmp="$(mktemp)"
  nft delete table inet "$NFT_TABLE" >/dev/null 2>&1 || true
  {
    printf 'table inet %s {\n' "$NFT_TABLE"
    printf '  set links {\n    type ipv4_addr . ipv4_addr\n'
    if [[ -s "$LINKS_FILE" ]]; then
      printf '    elements = { '
      while read -r source target; do
        [[ -n "$source" && -n "$target" ]] || continue
        node_exists "$source" && node_exists "$target" || continue
        source_ip="$(node_value "$source" ADDRESS)"
        target_ip="$(node_value "$target" ADDRESS)"
        [[ "$first" == true ]] || printf ', '
        printf '%s . %s' "$source_ip" "$target_ip"
        first=false
      done < "$LINKS_FILE"
      printf ' }\n'
    fi
    printf '  }\n'
    printf '  chain forward {\n'
    printf '    type filter hook forward priority 10; policy accept;\n'
    printf '    iifname "%s" oifname "%s" ct state established,related accept\n' "$WG_INTERFACE" "$WG_INTERFACE"
    printf '    iifname "%s" oifname "%s" ip saddr . ip daddr @links accept\n' "$WG_INTERFACE" "$WG_INTERFACE"
    printf '    iifname "%s" oifname "%s" drop\n' "$WG_INTERFACE" "$WG_INTERFACE"
    printf '  }\n}\n'
  } > "$tmp"
  nft -f "$tmp"
  rm -f -- "$tmp"
}

link_connect() {
  local source="$1" target="$2" tmp
  valid_name "$source" && valid_name "$target" || die "Некорректное имя узла"
  [[ "$source" != "$target" ]] || die "Источник и назначение совпадают"
  node_exists "$source" || die "Узел $source не найден"
  node_exists "$target" || die "Узел $target не найден"
  if grep -Fxq "$source $target" "$LINKS_FILE" 2>/dev/null; then
    log "Связь $source → $target уже включена"
    return
  fi
  tmp="$(mktemp)"
  { [[ ! -f "$LINKS_FILE" ]] || cat "$LINKS_FILE"; printf '%s %s\n' "$source" "$target"; } \
    | sort -u > "$tmp"
  install -m 0600 -o root -g root "$tmp" "$LINKS_FILE"
  rm -f -- "$tmp"
  restore_firewall
  log "Связь $source → $target включена"
}

link_disconnect() {
  local source="$1" target="$2" tmp
  valid_name "$source" && valid_name "$target" || die "Некорректное имя узла"
  tmp="$(mktemp)"
  if [[ -f "$LINKS_FILE" ]]; then
    awk -v source="$source" -v target="$target" '!($1 == source && $2 == target)' "$LINKS_FILE" > "$tmp"
  fi
  install -m 0600 -o root -g root "$tmp" "$LINKS_FILE"
  rm -f -- "$tmp"
  restore_firewall
  log "Связь $source → $target отключена"
}

remove_node() {
  local name="$1" public_key tmp
  valid_name "$name" || die "Некорректное имя узла"
  node_exists "$name" || die "Узел $name не найден"
  public_key="$(node_value "$name" PUBLIC_KEY)"
  wg set "$WG_INTERFACE" peer "$public_key" remove 2>/dev/null || true
  rm -f -- "$(node_file "$name")"
  tmp="$(mktemp)"
  if [[ -f "$LINKS_FILE" ]]; then
    awk -v name="$name" '$1 != name && $2 != name' "$LINKS_FILE" > "$tmp"
  fi
  install -m 0600 -o root -g root "$tmp" "$LINKS_FILE"
  rm -f -- "$tmp"
  render_wireguard_config
  restore_firewall
  log "Узел $name удалён"
}

list_nodes() {
  local file name address public_key handshake now state age
  now="$(date +%s)"
  for file in "$NODES_DIR"/*.node; do
    [[ -e "$file" ]] || continue
    name="$(config_value NAME "$file")"
    address="$(config_value ADDRESS "$file")"
    public_key="$(config_value PUBLIC_KEY "$file")"
    handshake="$(wg show "$WG_INTERFACE" latest-handshakes 2>/dev/null | awk -v key="$public_key" '$1 == key { print $2; exit }')"
    handshake="${handshake:-0}"
    state=offline
    age=-1
    if [[ "$handshake" =~ ^[0-9]+$ && "$handshake" -gt 0 ]]; then
      age=$((now - handshake))
      (( age <= 180 )) && state=online
    fi
    printf 'NODE=%s|%s|%s|%s\n' "$name" "$address" "$state" "$age"
  done
}

list_links() {
  local source target
  [[ -f "$LINKS_FILE" ]] || return 0
  while read -r source target; do
    [[ -n "$source" && -n "$target" ]] || continue
    printf 'LINK=%s|%s|enabled\n' "$source" "$target"
  done < "$LINKS_FILE"
}

status() {
  printf 'ROLE=hub\nINTERFACE=%s\nADDRESS=%s\nENDPOINT=%s:%s\n' \
    "$WG_INTERFACE" \
    "$(config_value HUB_ADDRESS "$HUB_CONFIG")" \
    "$(config_value HUB_ENDPOINT "$HUB_CONFIG")" \
    "$(config_value WG_PORT "$HUB_CONFIG")"
  list_nodes
  list_links
}

main() {
  local action="${1:-status}"
  require_root
  [[ -r "$HUB_CONFIG" ]] || die "Mesh Hub не установлен"
  case "$action" in
    node-code) [[ $# -eq 2 ]] || die "Использование: $0 node-code NAME"; node_code "$2" ;;
    node-remove) [[ $# -eq 2 ]] || die "Использование: $0 node-remove NAME"; remove_node "$2" ;;
    nodes) list_nodes ;;
    links) list_links ;;
    link-connect) [[ $# -eq 3 ]] || die "Использование: $0 link-connect SOURCE TARGET"; link_connect "$2" "$3" ;;
    link-disconnect) [[ $# -eq 3 ]] || die "Использование: $0 link-disconnect SOURCE TARGET"; link_disconnect "$2" "$3" ;;
    render) render_wireguard_config ;;
    firewall-restore) restore_firewall ;;
    status) status ;;
    *) die "Команды: node-code, node-remove, nodes, links, link-connect, link-disconnect, status" ;;
  esac
}

main "$@"
EOF
  chown root:root "$HUB_HELPER"
  chmod 0750 "$HUB_HELPER"
  ln -sfn "$HUB_HELPER" "$HUB_CLI"
}

configure_hub_firewall_service() {
  cat > /etc/systemd/system/ochenstarik-smm-firewall.service <<EOF
[Unit]
Description=Ochenstarik Server Monitor mesh ACL
After=wg-quick@${WG_INTERFACE}.service
Wants=wg-quick@${WG_INTERFACE}.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${HUB_HELPER} firewall-restore

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 /etc/systemd/system/ochenstarik-smm-firewall.service
  systemctl daemon-reload
  systemctl enable --now ochenstarik-smm-firewall.service
}

configure_hub_sudo() {
  cat > /etc/sudoers.d/ochenstarik-smm-hub <<EOF
${MONITOR_USER} ALL=(root) NOPASSWD: ${HUB_HELPER} *
EOF
  chmod 0440 /etc/sudoers.d/ochenstarik-smm-hub
  visudo -cf /etc/sudoers.d/ochenstarik-smm-hub >/dev/null \
    || die "Некорректный sudoers-файл Mesh Hub"
}

read_hub_endpoint() {
  local endpoint port
  if [[ -n "${SMM_HUB_ENDPOINT:-}" ]]; then
    endpoint="$SMM_HUB_ENDPOINT"
  elif [[ -r /dev/tty ]]; then
    IFS= read -r -p 'Публичный IPv4 или домен главного сервера: ' endpoint < /dev/tty
  else
    die "Передайте адрес через SMM_HUB_ENDPOINT"
  fi
  endpoint="${endpoint//$'\r'/}"
  [[ "$endpoint" =~ ^[A-Za-z0-9.-]+$ ]] || die "Некорректный IPv4 или домен"

  if [[ -n "${SMM_WG_PORT:-}" ]]; then
    port="$SMM_WG_PORT"
  elif [[ -r /dev/tty ]]; then
    IFS= read -r -p "UDP-порт WireGuard [${DEFAULT_WG_PORT}]: " port < /dev/tty
    port="${port:-$DEFAULT_WG_PORT}"
  else
    port="$DEFAULT_WG_PORT"
  fi
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) \
    || die "Порт должен быть от 1 до 65535"
  HUB_ENDPOINT_VALUE="$endpoint"
  WG_PORT_VALUE="$port"
}

install_hub() {
  install_monitoring
  install_mesh_dependencies
  read_hub_endpoint
  install -d -m 0700 -o root -g root "$MESH_DIR" "$NODES_DIR"
  install -d -m 0700 -o root -g root /etc/wireguard
  [[ -f "$HUB_PRIVATE_KEY" ]] || { umask 077; wg genkey > "$HUB_PRIVATE_KEY"; }
  chmod 0600 "$HUB_PRIVATE_KEY"
  {
    printf 'HUB_ENDPOINT=%s\n' "$HUB_ENDPOINT_VALUE"
    printf 'WG_PORT=%s\n' "$WG_PORT_VALUE"
    printf 'HUB_ADDRESS=%s\n' "$HUB_ADDRESS"
    printf 'MESH_CIDR=%s\n' "$MESH_CIDR"
  } > "$HUB_CONFIG"
  chmod 0600 "$HUB_CONFIG"
  touch "$LINKS_FILE"
  chmod 0600 "$LINKS_FILE"
  create_hub_helper
  "$HUB_HELPER" render
  "$HUB_HELPER" firewall-restore
  cat > /etc/sysctl.d/90-ochenstarik-smm-forward.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF
  chmod 0644 /etc/sysctl.d/90-ochenstarik-smm-forward.conf
  sysctl -p /etc/sysctl.d/90-ochenstarik-smm-forward.conf >/dev/null
  "$HUB_HELPER" firewall-restore
  systemctl enable --now "wg-quick@${WG_INTERFACE}.service"
  configure_hub_firewall_service
  configure_hub_sudo
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
    ufw allow "$WG_PORT_VALUE/udp" comment 'Server Monitor Mesh' >/dev/null
    ufw route allow in on "$WG_INTERFACE" out on "$WG_INTERFACE" comment 'Server Monitor Mesh routed' >/dev/null
  fi
  log "Главный Mesh Hub установлен: ${HUB_ENDPOINT_VALUE}:${WG_PORT_VALUE}/udp"
  log "Создать код узла: sudo ochenstarik-smm node-code hermes"
  log "Включить связь: sudo ochenstarik-smm link-connect hermes home"
}

base64url_decode() {
  local data="$1" remainder
  data="${data//-/+}"
  data="${data//_/\/}"
  remainder=$(( ${#data} % 4 ))
  if (( remainder == 2 )); then data+='=='
  elif (( remainder == 3 )); then data+='='
  elif (( remainder == 1 )); then return 1
  fi
  printf '%s' "$data" | base64 -d
}

payload_value() {
  local payload="$1" key="$2"
  printf '%s\n' "$payload" | awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }'
}

read_join_code() {
  if [[ -n "${SMM_JOIN_CODE:-}" ]]; then
    JOIN_CODE="$SMM_JOIN_CODE"
  elif [[ -r /dev/tty ]]; then
    printf '\nНа главном сервере выполните: sudo ochenstarik-smm node-code ИМЯ\n'
    IFS= read -r -s -p 'Вставьте секретный код SMM1: ' JOIN_CODE < /dev/tty
    printf '\n'
  else
    die "Передайте код через SMM_JOIN_CODE"
  fi
  JOIN_CODE="${JOIN_CODE//$'\r'/}"
  [[ "$JOIN_CODE" == SMM1-* ]] || die "Ожидается код формата SMM1-..."
}

install_node_mesh() {
  local payload version name address private_key hub_public_key endpoint allowed_ips derived_public tmp ssh_port
  install_mesh_dependencies
  read_join_code
  payload="$(base64url_decode "${JOIN_CODE#SMM1-}")" || die "Не удалось декодировать код"
  version="$(payload_value "$payload" VERSION)"
  name="$(payload_value "$payload" NAME)"
  address="$(payload_value "$payload" ADDRESS)"
  private_key="$(payload_value "$payload" PRIVATE_KEY)"
  hub_public_key="$(payload_value "$payload" HUB_PUBLIC_KEY)"
  endpoint="$(payload_value "$payload" ENDPOINT)"
  allowed_ips="$(payload_value "$payload" ALLOWED_IPS)"
  [[ "$version" == 1 ]] || die "Неподдерживаемая версия кода"
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || die "Некорректное имя узла"
  [[ "$address" =~ ^10\.77\.0\.([2-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-4])/32$ ]] \
    || die "Некорректный внутренний адрес"
  [[ "$endpoint" =~ ^[A-Za-z0-9.-]+:[0-9]{1,5}$ ]] || die "Некорректный endpoint"
  [[ "$allowed_ips" == "$MESH_CIDR" ]] || die "Некорректная mesh-подсеть"
  derived_public="$(printf '%s' "$private_key" | wg pubkey 2>/dev/null)" \
    || die "Некорректный приватный WireGuard-ключ"
  [[ "$(printf '%s' "$hub_public_key" | base64 -d 2>/dev/null | wc -c)" -eq 32 ]] \
    || die "Некорректный публичный ключ Hub"
  install -d -m 0700 -o root -g root /etc/wireguard "$MESH_DIR"
  tmp="$(mktemp)"
  {
    printf '[Interface]\nAddress = %s\nPrivateKey = %s\n' "$address" "$private_key"
    printf '\n[Peer]\nPublicKey = %s\nEndpoint = %s\n' "$hub_public_key" "$endpoint"
    printf 'AllowedIPs = %s\nPersistentKeepalive = 25\n' "$allowed_ips"
  } > "$tmp"
  install -m 0600 -o root -g root "$tmp" "$WG_CONFIG"
  rm -f -- "$tmp"
  printf 'ROLE=node\nNAME=%s\nADDRESS=%s\nPUBLIC_KEY=%s\n' \
    "$name" "$address" "$derived_public" > "$MESH_DIR/node.conf"
  chmod 0600 "$MESH_DIR/node.conf"
  unset private_key payload JOIN_CODE SMM_JOIN_CODE
  systemctl enable --now "wg-quick@${WG_INTERFACE}.service"
  ssh_port="$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }')"
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active' && [[ -n "$ssh_port" ]]; then
    ufw allow in on "$WG_INTERFACE" to any port "$ssh_port" proto tcp comment 'Server Monitor Mesh SSH' >/dev/null
  fi
  if ping -c 1 -W 4 "$HUB_ADDRESS" >/dev/null 2>&1; then
    log "Узел $name подключён к Hub; адрес $address"
  else
    warn "Интерфейс поднят, но Hub пока не отвечает. Проверьте UDP-порт и команду sudo wg show."
  fi
}

install_node() {
  install_monitoring
  install_node_mesh
  log "Вторичный сервер установлен"
}

show_status() {
  local ssh_port="unknown"
  if command -v sshd >/dev/null 2>&1; then
    ssh_port="$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }')"
  fi
  printf 'Пользователь мониторинга: %s\n' "$MONITOR_USER"
  printf 'SSH-порт: %s\n' "${ssh_port:-unknown}"
  if [[ -r "$HUB_CONFIG" && -x "$HUB_HELPER" ]]; then
    "$HUB_HELPER" status
  elif [[ -r "$MESH_DIR/node.conf" ]]; then
    cat "$MESH_DIR/node.conf"
    wg show "$WG_INTERFACE" 2>/dev/null || true
  else
    printf 'ROLE=monitor-only\n'
  fi
  if [[ -x "$MONITOR_COMMAND" ]]; then
    runuser -u "$MONITOR_USER" -- "$MONITOR_COMMAND"
  else
    warn "Серверная часть ещё не установлена"
  fi
}

install_server_part() {
  install_monitoring
  log "Серверная часть мониторинга установлена"
  log "Входящий порт не изменялся, новые правила UFW не создавались"
  show_status
}

uninstall_server_part() {
  local answer
  if [[ -r /dev/tty ]]; then
    IFS= read -r -p 'Удалить пользователя мониторинга и forced-command? [y/N]: ' answer < /dev/tty
  else
    die "Для удаления требуется интерактивный терминал"
  fi
  [[ "$answer" =~ ^[Yy]$ ]] || { log "Отменено"; return 0; }
  rm -f -- "$MONITOR_COMMAND"
  if getent passwd "$MONITOR_USER" >/dev/null; then
    userdel --remove "$MONITOR_USER" 2>/dev/null || userdel "$MONITOR_USER"
  fi
  log "Серверная часть мониторинга удалена"
}

main() {
  local action="${1:-install}"
  require_root
  detect_system
  case "$action" in
    install) install_server_part ;;
    hub) install_hub ;;
    node) install_node ;;
    hub-code) [[ $# -eq 2 ]] || die "Использование: $0 hub-code NAME"; exec "$HUB_HELPER" node-code "$2" ;;
    status) show_status ;;
    uninstall) uninstall_server_part ;;
    *) die "Использование: $0 {install|hub|node|hub-code NAME|status|uninstall}" ;;
  esac
}

main "$@"
