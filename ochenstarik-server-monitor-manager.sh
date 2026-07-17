#!/usr/bin/env bash
set -Eeuo pipefail

readonly APP_NAME="ochenstarik-server-monitor-manager"
readonly MONITOR_USER="ochenstarik-monitor"
readonly MONITOR_HOME="/var/lib/${APP_NAME}"
readonly MONITOR_COMMAND="/usr/local/libexec/ochenstarik-server-monitor"
readonly AUTHORIZED_KEYS="${MONITOR_HOME}/.ssh/authorized_keys"
readonly MONITOR_SSH_CONFIG="/etc/ssh/sshd_config.d/90-ochenstarik-server-monitor.conf"
readonly MESH_DIR="/etc/${APP_NAME}"
readonly NODES_DIR="${MESH_DIR}/nodes"
readonly TOKENS_DIR="${MESH_DIR}/tokens"
readonly HUB_CONFIG="${MESH_DIR}/hub.conf"
readonly HUB_PRIVATE_KEY="${MESH_DIR}/hub.key"
readonly LINKS_FILE="${MESH_DIR}/links"
readonly HUB_HELPER="/usr/local/libexec/ochenstarik-smm-hub"
readonly CONTROL_POLICY_HELPER="/usr/local/libexec/ochenstarik-smm-policy-apply"
readonly HUB_CLI="/usr/local/sbin/ochenstarik-smm"
readonly WG_INTERFACE="smm0"
readonly WG_CONFIG="/etc/wireguard/${WG_INTERFACE}.conf"
readonly MESH_CIDR="10.77.0.0/24"
readonly HUB_ADDRESS="10.77.0.1"
readonly DEFAULT_WG_PORT="51820"
readonly CONTROL_PORT="7443"
readonly CONTROL_USER="ochenstarik-smm-control"
readonly AGENT_USER="ochenstarik-smm-agent"
readonly CONTROL_STATE="${MONITOR_HOME}/control"
readonly AGENT_STATE="${MONITOR_HOME}/agent"
readonly CONTROL_BINARY="/usr/local/lib/${APP_NAME}/control/ochenstarik-smm-control"
readonly AGENT_BINARY="/usr/local/lib/${APP_NAME}/agent/ochenstarik-smm-agent"
readonly CONTROL_ENV="${MESH_DIR}/control.env"
readonly AGENT_ENV="${MESH_DIR}/agent.env"
readonly CONTROL_CA_CERT="${MESH_DIR}/control-ca.crt"
readonly CONTROL_SERVICE="/etc/systemd/system/ochenstarik-smm-control.service"
readonly AGENT_SERVICE="/etc/systemd/system/ochenstarik-smm-agent.service"
readonly SMM_RELEASE_VERSION="${SMM_RELEASE_VERSION:-v0.1.0-alpha.3}"
readonly SMM_RELEASE_BASE_URL="${SMM_RELEASE_BASE_URL:-https://github.com/ochenstarik-ui/server-monitor-manager/releases/download/${SMM_RELEASE_VERSION}}"

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
    ca-certificates openssh-server openssh-client coreutils gawk sudo
  systemctl enable --now ssh
}

install_mesh_dependencies() {
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    wireguard-tools nftables iproute2 iputils-ping jq openssl
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
    read -r prefix action source target protocol port ttl extra <<< "$original_command"
    [[ "$prefix" == mesh && "$action" == connect && -n "$ttl" && -z "${extra:-}" ]] \
      || { echo "Некорректная команда" >&2; exit 2; }
    exec sudo -n "$HUB_HELPER" link-connect "$source" "$target" "$protocol" "$port" "$ttl"
    ;;
  "mesh disconnect "*)
    [[ -x "$HUB_HELPER" ]] || { echo "Mesh Hub не установлен" >&2; exit 1; }
    read -r prefix action source target protocol port extra <<< "$original_command"
    [[ "$prefix" == mesh && "$action" == disconnect && -n "$port" && -z "${extra:-}" ]] \
      || { echo "Некорректная команда" >&2; exit 2; }
    exec sudo -n "$HUB_HELPER" link-disconnect "$source" "$target" "$protocol" "$port"
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
printf 'SWAP_TOTAL_KB=%s\n' "$(read_mem_value SwapTotal)"
printf 'SWAP_FREE_KB=%s\n' "$(read_mem_value SwapFree)"
df -Pk / | awk 'NR == 2 {
  printf "DISK_TOTAL_KB=%s\nDISK_AVAILABLE_KB=%s\n", $2, $4
}'
df -Pi / | awk 'NR == 2 {
  printf "DISK_INODES_TOTAL=%s\nDISK_INODES_FREE=%s\n", $2, $4
}'
awk 'BEGIN { rx=0; tx=0 }
  FNR == 1 && FILENAME !~ "/lo/" { rx += $1 }
  FNR == 1 && FILENAME !~ "/lo/" { getline value < (FILENAME ~ /rx_bytes/ ? gensub(/rx_bytes$/, "tx_bytes", 1, FILENAME) : FILENAME); tx += value }
  END { printf "NETWORK_RX_BYTES=%.0f\nNETWORK_TX_BYTES=%.0f\n", rx, tx }
' /sys/class/net/*/statistics/rx_bytes 2>/dev/null || printf 'NETWORK_RX_BYTES=0\nNETWORK_TX_BYTES=0\n'
printf 'SYSTEMD_SSH=%s\n' "$(systemctl is-active ssh 2>/dev/null || true)"
printf 'SYSTEMD_WIREGUARD=%s\n' "$(systemctl is-active wg-quick@smm0.service 2>/dev/null || true)"
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

  install -d -m 0755 -o root -g root /etc/ssh/sshd_config.d
  cat > "$MONITOR_SSH_CONFIG" <<'EOF'
# Required by the restricted Server Monitor Manager identity only.
Match User ochenstarik-monitor
    PubkeyAuthentication yes
Match all
EOF
  chown root:root "$MONITOR_SSH_CONFIG"
  chmod 0644 "$MONITOR_SSH_CONFIG"
}

verify_sshd() {
  sshd -t
  sshd -T -C "user=${MONITOR_USER},host=localhost,addr=127.0.0.1" \
    | awk '$1 == "pubkeyauthentication" && $2 == "yes" { enabled=1 } END { exit !enabled }' \
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
readonly TOKENS_DIR="${STATE_DIR}/tokens"
readonly HUB_CONFIG="${STATE_DIR}/hub.conf"
readonly HUB_PRIVATE_KEY="${STATE_DIR}/hub.key"
readonly LINKS_FILE="${STATE_DIR}/links"
readonly AUDIT_FILE="${STATE_DIR}/audit.jsonl"
readonly VERSION_FILE="${STATE_DIR}/policy.version"
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

next_policy_version() {
  local version=0 tmp
  [[ ! -r "$VERSION_FILE" ]] || read -r version < "$VERSION_FILE"
  [[ "$version" =~ ^[0-9]+$ ]] || version=0
  version=$((version + 1))
  tmp="$(mktemp)"
  printf '%s\n' "$version" > "$tmp"
  install -m 0600 -o root -g root "$tmp" "$VERSION_FILE"
  rm -f -- "$tmp"
  printf '%s' "$version"
}

audit_link() {
  local action="$1" state="$2" source="$3" target="$4" protocol="$5" port="$6" version="$7"
  printf '{"time":"%s","action":"%s","state":"%s","source":"%s","target":"%s","protocol":"%s","port":%s,"version":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$action" "$state" "$source" "$target" "$protocol" "$port" "$version" \
    >> "$AUDIT_FILE"
  chmod 0600 "$AUDIT_FILE"
}

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
    for file in "$NODES_DIR"/*.node "$TOKENS_DIR"/*.token*; do
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

token_cleanup() {
  local file expires now
  now="$(date +%s)"
  for file in "$TOKENS_DIR"/*.token; do
    [[ -e "$file" ]] || continue
    expires="$(config_value EXPIRES "$file")"
    [[ "$expires" =~ ^[0-9]+$ ]] || { rm -f -- "$file"; continue; }
    (( expires > now )) || rm -f -- "$file"
  done
}

node_code() {
  local name="$1" address endpoint port payload code token token_hash expires file
  valid_name "$name" || die "Имя: строчные латинские буквы, цифры и дефис, максимум 32 символа"
  node_exists "$name" && die "Узел $name уже существует"
  token_cleanup
  for file in "$TOKENS_DIR"/*.token; do
    [[ -e "$file" ]] || continue
    [[ "$(config_value NAME "$file")" != "$name" ]] \
      || die "Для узла $name уже существует действующий enrollment-код"
  done
  address="$(next_address)"
  endpoint="$(config_value HUB_ENDPOINT "$HUB_CONFIG")"
  port="$(config_value WG_PORT "$HUB_CONFIG")"
  token="$(openssl rand -hex 32)"
  token_hash="$(printf '%s' "$token" | sha256sum | awk '{ print $1 }')"
  expires=$(( $(date +%s) + 600 ))
  file="${TOKENS_DIR}/${token_hash}.token"
  umask 077
  {
    printf 'NAME=%s\n' "$name"
    printf 'ADDRESS=%s\n' "$address"
    printf 'EXPIRES=%s\n' "$expires"
  } > "$file"
  payload="$(printf 'VERSION=2\nNAME=%s\nADDRESS=%s/32\nTOKEN=%s\nEXPIRES=%s\nHUB_PUBLIC_KEY=%s\nENDPOINT=%s:%s\nALLOWED_IPS=10.77.0.0/24\n' \
    "$name" "$address" "$token" "$expires" "$(wg pubkey < "$HUB_PRIVATE_KEY")" "$endpoint" "$port")"
  code="SMM2-$(printf '%s' "$payload" | base64url_encode)"
  unset token payload
  printf '\nОдноразовый enrollment-код для узла %s (действует 10 минут):\n%s\n\n' "$name" "$code"
  printf 'Приватный WireGuard-ключ будет создан только на Node. Не сохраняйте код в чатах или логах.\n'
}

node_enroll() {
  local request="${SMM_ENROLL_REQUEST:-}" payload version token token_hash token_file consuming_file
  local name address public_key stored_name stored_address expires now node_path ack
  local hub_public_key endpoint allowed_ips
  if [[ -z "$request" && -r /dev/tty ]]; then
    IFS= read -r -s -p 'Вставьте request-код SMMREQ1: ' request < /dev/tty
    printf '\n'
  fi
  [[ "$request" == SMMREQ1-* ]] || die "Ожидается request-код SMMREQ1-..."
  payload="$(base64url_decode "${request#SMMREQ1-}")" || die "Не удалось декодировать request-код"
  version="$(payload_value "$payload" VERSION)"
  token="$(payload_value "$payload" TOKEN)"
  name="$(payload_value "$payload" NAME)"
  address="$(payload_value "$payload" ADDRESS)"
  public_key="$(payload_value "$payload" PUBLIC_KEY)"
  [[ "$version" == 1 ]] || die "Неподдерживаемая версия request-кода"
  [[ "$token" =~ ^[a-f0-9]{64}$ ]] || die "Некорректный enrollment token"
  valid_name "$name" || die "Некорректное имя Node"
  [[ "$address" =~ ^10\.77\.0\.([2-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-4])/32$ ]] \
    || die "Некорректный адрес Node"
  [[ "$(printf '%s' "$public_key" | base64 -d 2>/dev/null | wc -c)" -eq 32 ]] \
    || die "Некорректный публичный WireGuard-ключ Node"
  token_hash="$(printf '%s' "$token" | sha256sum | awk '{ print $1 }')"
  token_file="${TOKENS_DIR}/${token_hash}.token"
  [[ -f "$token_file" ]] || die "Enrollment token не найден, уже использован или истёк"
  stored_name="$(config_value NAME "$token_file")"
  stored_address="$(config_value ADDRESS "$token_file")"
  expires="$(config_value EXPIRES "$token_file")"
  now="$(date +%s)"
  [[ "$stored_name" == "$name" && "${address%/32}" == "$stored_address" ]] \
    || die "Параметры Node не совпадают с enrollment token"
  [[ "$expires" =~ ^[0-9]+$ ]] && (( expires > now )) \
    || { rm -f -- "$token_file"; die "Enrollment token истёк"; }
  node_exists "$name" && die "Узел $name уже зарегистрирован"
  consuming_file="${token_file}.consuming"
  mv -- "$token_file" "$consuming_file" \
    || die "Enrollment token уже обрабатывается"
  node_path="$(node_file "$name")"
  umask 077
  {
    printf 'NAME=%s\n' "$name"
    printf 'ADDRESS=%s\n' "${address%/32}"
    printf 'PUBLIC_KEY=%s\n' "$public_key"
  } > "$node_path"
  render_wireguard_config
  rm -f -- "$consuming_file"
  hub_public_key="$(wg pubkey < "$HUB_PRIVATE_KEY")"
  endpoint="$(config_value HUB_ENDPOINT "$HUB_CONFIG"):$(config_value WG_PORT "$HUB_CONFIG")"
  allowed_ips="10.77.0.0/24"
  ack="$(printf '%s|%s|%s|%s|%s|%s|%s' \
    "$token" "$public_key" "$name" "$address" "$hub_public_key" "$endpoint" "$allowed_ips" \
    | sha256sum | awk '{ print $1 }')"
  unset token payload
  printf '\nNode зарегистрирован. Верните этот код в установщик Node:\nSMMACK1-%s\n\n' "$ack"
}

prune_links() {
  local tmp source target cidr protocol port expires version now target_ip
  tmp="$(mktemp)"
  now="$(date +%s)"
  if [[ -f "$LINKS_FILE" ]]; then
    while read -r source target cidr protocol port expires version extra; do
      [[ -z "${extra:-}" ]] || continue
      valid_name "$source" && valid_name "$target" || continue
      node_exists "$source" && node_exists "$target" || continue
      target_ip="$(node_value "$target" ADDRESS)"
      [[ "$cidr" == "${target_ip}/32" ]] || continue
      [[ "$protocol" == tcp || "$protocol" == udp ]] || continue
      [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || continue
      [[ "$expires" =~ ^[0-9]+$ ]] || continue
      [[ "${version:-}" =~ ^[0-9]+$ ]] || version=0
      if (( expires != 0 && expires <= now )); then
        audit_link expire Expired "$source" "$target" "$protocol" "$port" "$version"
        continue
      fi
      printf '%s %s %s %s %s %s %s\n' "$source" "$target" "$cidr" "$protocol" "$port" "$expires" "$version" >> "$tmp"
    done < "$LINKS_FILE"
  fi
  sort -u -o "$tmp" "$tmp"
  install -m 0600 -o root -g root "$tmp" "$LINKS_FILE"
  rm -f -- "$tmp"
}

restore_firewall() {
  local tmp body source target cidr protocol port expires version source_ip
  prune_links
  tmp="$(mktemp)"
  body="$(mktemp)"
  {
    printf 'table inet %s {\n' "$NFT_TABLE"
    printf '  chain forward {\n'
    printf '    type filter hook forward priority 10; policy accept;\n'
    printf '    iifname "%s" oifname "%s" ct state established,related accept\n' "$WG_INTERFACE" "$WG_INTERFACE"
    while read -r source target cidr protocol port expires version; do
      [[ -n "$source" ]] || continue
      source_ip="$(node_value "$source" ADDRESS)"
      printf '    iifname "%s" oifname "%s" ip saddr %s ip daddr %s %s dport %s accept\n' \
        "$WG_INTERFACE" "$WG_INTERFACE" "$source_ip" "$cidr" "$protocol" "$port"
    done < "$LINKS_FILE"
    printf '    iifname "%s" oifname "%s" drop\n' "$WG_INTERFACE" "$WG_INTERFACE"
    printf '  }\n}\n'
  } > "$body"
  if nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
    printf 'delete table inet %s\n' "$NFT_TABLE" > "$tmp"
  fi
  cat "$body" >> "$tmp"
  rm -f -- "$body"
  if ! nft --check -f "$tmp" || ! nft -f "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  rm -f -- "$tmp"
}

link_connect() {
  local source="$1" target="$2" protocol="$3" port="$4" ttl_minutes="$5"
  local target_ip cidr expires version tmp
  valid_name "$source" && valid_name "$target" || die "Некорректное имя узла"
  [[ "$source" != "$target" ]] || die "Источник и назначение совпадают"
  node_exists "$source" || die "Узел $source не найден"
  node_exists "$target" || die "Узел $target не найден"
  [[ "$protocol" == tcp || "$protocol" == udp ]] || die "Протокол должен быть tcp или udp"
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || die "Порт должен быть от 1 до 65535"
  [[ "$ttl_minutes" =~ ^[0-9]+$ ]] && (( ttl_minutes <= 525600 )) \
    || die "TTL должен быть от 0 до 525600 минут"
  target_ip="$(node_value "$target" ADDRESS)"
  cidr="${target_ip}/32"
  expires=0
  (( ttl_minutes == 0 )) || expires=$(( $(date +%s) + ttl_minutes * 60 ))
  version="$(next_policy_version)"
  audit_link connect Connecting "$source" "$target" "$protocol" "$port" "$version"
  tmp="$(mktemp)"
  if [[ -f "$LINKS_FILE" ]]; then
    awk -v source="$source" -v target="$target" -v protocol="$protocol" -v port="$port" \
      '!($1 == source && $2 == target && $4 == protocol && $5 == port)' "$LINKS_FILE" > "$tmp"
  fi
  printf '%s %s %s %s %s %s %s\n' "$source" "$target" "$cidr" "$protocol" "$port" "$expires" "$version" >> "$tmp"
  sort -u -o "$tmp" "$tmp"
  install -m 0600 -o root -g root "$tmp" "$LINKS_FILE"
  rm -f -- "$tmp"
  if ! restore_firewall; then
    audit_link connect Failed "$source" "$target" "$protocol" "$port" "$version"
    die "Не удалось применить nftables policy"
  fi
  audit_link connect Active "$source" "$target" "$protocol" "$port" "$version"
  log "Связь $source → $target: $protocol/$port включена"
  printf 'LINK_STATE=Active|VERSION=%s\n' "$version"
}

link_disconnect() {
  local source="$1" target="$2" protocol="$3" port="$4" version tmp
  valid_name "$source" && valid_name "$target" || die "Некорректное имя узла"
  [[ "$protocol" == tcp || "$protocol" == udp ]] || die "Протокол должен быть tcp или udp"
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || die "Некорректный порт"
  version="$(next_policy_version)"
  audit_link disconnect Disconnecting "$source" "$target" "$protocol" "$port" "$version"
  tmp="$(mktemp)"
  if [[ -f "$LINKS_FILE" ]]; then
    awk -v source="$source" -v target="$target" -v protocol="$protocol" -v port="$port" \
      '!($1 == source && $2 == target && $4 == protocol && $5 == port)' "$LINKS_FILE" > "$tmp"
  fi
  install -m 0600 -o root -g root "$tmp" "$LINKS_FILE"
  rm -f -- "$tmp"
  if ! restore_firewall; then
    audit_link disconnect Failed "$source" "$target" "$protocol" "$port" "$version"
    die "Не удалось применить отключение в nftables"
  fi
  audit_link disconnect Disabled "$source" "$target" "$protocol" "$port" "$version"
  log "Связь $source → $target: $protocol/$port отключена"
  printf 'LINK_STATE=Disabled|VERSION=%s\n' "$version"
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
  local source target cidr protocol port expires version
  prune_links
  [[ -f "$LINKS_FILE" ]] || return 0
  while read -r source target cidr protocol port expires version; do
    [[ -n "$source" && -n "$target" ]] || continue
    printf 'LINK=%s|%s|%s|%s|%s|%s|Active|%s\n' \
      "$source" "$target" "$cidr" "$protocol" "$port" "$expires" "$version"
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
    node-enroll) [[ $# -eq 1 ]] || die "Использование: $0 node-enroll"; node_enroll ;;
    node-remove) [[ $# -eq 2 ]] || die "Использование: $0 node-remove NAME"; remove_node "$2" ;;
    nodes) list_nodes ;;
    links) list_links ;;
    link-connect) [[ $# -eq 6 ]] || die "Использование: $0 link-connect SOURCE TARGET tcp|udp PORT TTL_MINUTES"; link_connect "$2" "$3" "$4" "$5" "$6" ;;
    link-disconnect) [[ $# -eq 5 ]] || die "Использование: $0 link-disconnect SOURCE TARGET tcp|udp PORT"; link_disconnect "$2" "$3" "$4" "$5" ;;
    render) render_wireguard_config ;;
    firewall-restore) restore_firewall ;;
    status) status ;;
    *) die "Команды: node-code, node-enroll, node-remove, nodes, links, link-connect, link-disconnect, status" ;;
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
ExecStart=${HUB_HELPER} firewall-restore

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 /etc/systemd/system/ochenstarik-smm-firewall.service
  cat > /etc/systemd/system/ochenstarik-smm-firewall.timer <<'EOF'
[Unit]
Description=Expire Server Monitor mesh policies

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=10s
Persistent=true
Unit=ochenstarik-smm-firewall.service

[Install]
WantedBy=timers.target
EOF
  chmod 0644 /etc/systemd/system/ochenstarik-smm-firewall.timer
  systemctl daemon-reload
  systemctl enable --now ochenstarik-smm-firewall.service
  systemctl enable --now ochenstarik-smm-firewall.timer
}

configure_hub_sudo() {
  {
    printf '%s ALL=(root) NOPASSWD: %s *\n' "$MONITOR_USER" "$HUB_HELPER"
    if getent passwd "$CONTROL_USER" >/dev/null; then
      printf '%s ALL=(root) NOPASSWD: %s *\n' "$CONTROL_USER" "$CONTROL_POLICY_HELPER"
    fi
  } > /etc/sudoers.d/ochenstarik-smm-hub
  chmod 0440 /etc/sudoers.d/ochenstarik-smm-hub
  visudo -cf /etc/sudoers.d/ochenstarik-smm-hub >/dev/null \
    || die "Некорректный sudoers-файл Mesh Hub"
}

create_control_policy_helper() {
  cat > "$CONTROL_POLICY_HELPER" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

readonly HUB_HELPER="/usr/local/libexec/ochenstarik-smm-hub"
action="${1:-}"

valid_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]]; }
valid_protocol() { [[ "$1" == tcp || "$1" == udp ]]; }
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }

case "$action" in
  link-connect)
    [[ $# -eq 6 ]] || exit 2
    valid_name "$2" && valid_name "$3" && valid_protocol "$4" && valid_port "$5" \
      && [[ "$6" =~ ^[0-9]+$ ]] && (( $6 <= 525600 )) || exit 2
    ;;
  link-disconnect)
    [[ $# -eq 5 ]] || exit 2
    valid_name "$2" && valid_name "$3" && valid_protocol "$4" && valid_port "$5" || exit 2
    ;;
  *) exit 2 ;;
esac

exec "$HUB_HELPER" "$@"
EOF
  chown root:root "$CONTROL_POLICY_HELPER"
  chmod 0750 "$CONTROL_POLICY_HELPER"
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

runtime_id() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'linux-x64\n' ;;
    aarch64|arm64) printf 'linux-arm64\n' ;;
    *) die "Control layer поддерживает только amd64 и arm64" ;;
  esac
}

download_control_layer() {
  local runtime archive archive_name checksum temporary
  runtime="$(runtime_id)"
  archive_name="server-monitor-manager-${runtime}.tar.gz"
  temporary="$(mktemp -d)"
  archive="${temporary}/${archive_name}"
  trap 'rm -rf -- "${temporary:-}"' RETURN
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl openssl tar
  curl -4 -fL --retry 5 --retry-delay 5 --connect-timeout 30 \
    "${SMM_RELEASE_BASE_URL}/${archive_name}" -o "$archive"
  curl -4 -fL --retry 5 --retry-delay 5 --connect-timeout 30 \
    "${SMM_RELEASE_BASE_URL}/${archive_name}.sha256" -o "${archive}.sha256"
  checksum="$(awk 'NR == 1 { print $1 }' "${archive}.sha256")"
  [[ "$checksum" =~ ^[a-fA-F0-9]{64}$ ]] || die "Некорректный release checksum"
  [[ "$(sha256sum "$archive" | awk '{ print $1 }')" == "$checksum" ]] \
    || die "Checksum control layer не совпал"
  tar -xzf "$archive" -C "$temporary"
  [[ -x "${temporary}/agent/ochenstarik-smm-agent" ]] || die "В release нет Agent"
  [[ -x "${temporary}/control/ochenstarik-smm-control" ]] || die "В release нет Control"
  install -d -m 0755 -o root -g root "$(dirname "$AGENT_BINARY")" "$(dirname "$CONTROL_BINARY")"
  install -m 0755 -o root -g root "${temporary}/agent/ochenstarik-smm-agent" "$AGENT_BINARY"
  install -m 0755 -o root -g root "${temporary}/control/ochenstarik-smm-control" "$CONTROL_BINARY"
  trap - RETURN
  rm -rf -- "$temporary"
}

ensure_system_user() {
  local user="$1" home="$2"
  if ! getent passwd "$user" >/dev/null; then
    useradd --system --home-dir "$home" --create-home --shell /usr/sbin/nologin "$user"
  fi
  install -d -m 0700 -o "$user" -g "$user" "$home"
}

create_control_certificates() {
  local endpoint="$1" san temporary
  [[ -f "${CONTROL_STATE}/control-ca.pfx" && -f "${CONTROL_STATE}/server.pfx" && -f "$CONTROL_CA_CERT" ]] \
    && return 0
  temporary="$(mktemp -d)"
  trap 'rm -rf -- "${temporary:-}"' RETURN
  if [[ "$endpoint" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    san="IP:${endpoint}"
  else
    san="DNS:${endpoint}"
  fi
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -sha256 -nodes \
    -days 3650 -subj '/CN=Ochenstarik SMM Control CA' \
    -keyout "${temporary}/ca.key" -out "${temporary}/ca.crt" >/dev/null 2>&1
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -sha256 -nodes \
    -subj "/CN=${endpoint}" -addext "subjectAltName=${san}" \
    -keyout "${temporary}/server.key" -out "${temporary}/server.csr" >/dev/null 2>&1
  openssl x509 -req -sha256 -days 825 -in "${temporary}/server.csr" \
    -CA "${temporary}/ca.crt" -CAkey "${temporary}/ca.key" -CAcreateserial \
    -copy_extensions copy -out "${temporary}/server.crt" >/dev/null 2>&1
  openssl pkcs12 -export -passout pass: -name smm-control-ca \
    -inkey "${temporary}/ca.key" -in "${temporary}/ca.crt" \
    -out "${temporary}/control-ca.pfx"
  openssl pkcs12 -export -passout pass: -name smm-control \
    -inkey "${temporary}/server.key" -in "${temporary}/server.crt" \
    -certfile "${temporary}/ca.crt" -out "${temporary}/server.pfx"
  install -m 0600 -o "$CONTROL_USER" -g "$CONTROL_USER" \
    "${temporary}/control-ca.pfx" "${CONTROL_STATE}/control-ca.pfx"
  install -m 0600 -o "$CONTROL_USER" -g "$CONTROL_USER" \
    "${temporary}/server.pfx" "${CONTROL_STATE}/server.pfx"
  install -m 0644 -o root -g root "${temporary}/ca.crt" "$CONTROL_CA_CERT"
  trap - RETURN
  rm -rf -- "$temporary"
}

configure_control_service() {
  cat > "$CONTROL_ENV" <<EOF
ASPNETCORE_URLS=https://0.0.0.0:${CONTROL_PORT}
ASPNETCORE_Kestrel__Certificates__Default__Path=${CONTROL_STATE}/server.pfx
Control__DatabasePath=${CONTROL_STATE}/control.db
Control__CertificateAuthorityPath=${CONTROL_STATE}/control-ca.pfx
Control__HeartbeatSeconds=30
Control__HubHelperPath=${CONTROL_POLICY_HELPER}
EOF
  chmod 0600 "$CONTROL_ENV"
  cat > "$CONTROL_SERVICE" <<EOF
[Unit]
Description=Ochenstarik Server Monitor Manager Control Hub
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${CONTROL_USER}
Group=${CONTROL_USER}
EnvironmentFile=${CONTROL_ENV}
ExecStart=${CONTROL_BINARY}
Restart=on-failure
RestartSec=10s
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
LockPersonality=true
RestrictSUIDSGID=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
ReadWritePaths=${CONTROL_STATE}

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$CONTROL_SERVICE"
  systemctl daemon-reload
  systemctl enable --now ochenstarik-smm-control.service
  systemctl restart ochenstarik-smm-control.service
}

install_control_hub() {
  local endpoint
  [[ -r "$HUB_CONFIG" ]] || die "Сначала установите роль Hub"
  endpoint="$(awk -F= '$1 == "HUB_ENDPOINT" { print $2; exit }' "$HUB_CONFIG")"
  [[ -n "$endpoint" ]] || die "В hub.conf отсутствует HUB_ENDPOINT"
  download_control_layer
  ensure_system_user "$CONTROL_USER" "$CONTROL_STATE"
  install -d -m 0700 -o root -g root "$MESH_DIR"
  create_control_policy_helper
  configure_hub_sudo
  create_control_certificates "$endpoint"
  configure_control_service
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
    ufw allow "${CONTROL_PORT}/tcp" comment 'Server Monitor Control' >/dev/null
  fi
  log "Control Hub установлен: https://${endpoint}:${CONTROL_PORT}"
  log "Создать код Agent: sudo $0 control-code ИМЯ"
}

install_hub() {
  install_monitoring
  install_mesh_dependencies
  read_hub_endpoint
  install -d -m 0700 -o root -g root "$MESH_DIR" "$NODES_DIR" "$TOKENS_DIR"
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
  touch "${MESH_DIR}/audit.jsonl"
  chmod 0600 "${MESH_DIR}/audit.jsonl"
  [[ -f "${MESH_DIR}/policy.version" ]] || printf '0\n' > "${MESH_DIR}/policy.version"
  chmod 0600 "${MESH_DIR}/policy.version"
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
  log "Создать код узла: sudo ochenstarik-smm node-code ai-agent"
  log "Включить SSH на 2 часа: sudo ochenstarik-smm link-connect ai-agent home tcp 22 120"
  log "Установить постоянный control layer: sudo $0 install-control-hub"
}

base64url_encode() {
  base64 -w0 | tr '+/' '-_' | tr -d '='
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

create_control_join_code() {
  local name="$1" endpoint token ca payload
  [[ -x "$CONTROL_BINARY" && -r "$CONTROL_ENV" && -r "$CONTROL_CA_CERT" ]] \
    || die "Control Hub не установлен"
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || die "Некорректное имя Agent"
  endpoint="$(awk -F= '$1 == "HUB_ENDPOINT" { print $2; exit }' "$HUB_CONFIG")"
  token="$(
    set -a
    # shellcheck disable=SC1090
    . "$CONTROL_ENV"
    set +a
    runuser -u "$CONTROL_USER" -m -- "$CONTROL_BINARY" token-create "$name"
  )"
  [[ "$token" =~ ^[A-Za-z0-9_-]{43}$ ]] || die "Control Hub не создал enrollment token"
  ca="$(base64 -w0 "$CONTROL_CA_CERT")"
  payload="$(printf 'VERSION=1\nNAME=%s\nURL=https://%s:%s\nTOKEN=%s\nCA=%s\n' \
    "$name" "$endpoint" "$CONTROL_PORT" "$token" "$ca")"
  printf 'SMMCTL1-%s\n' "$(printf '%s' "$payload" | base64url_encode)"
  unset token payload ca
}

create_device_join_code() {
  local device_id="$1" endpoint token ca payload
  [[ -x "$CONTROL_BINARY" && -r "$CONTROL_ENV" && -r "$CONTROL_CA_CERT" ]] \
    || die "Control Hub не установлен"
  [[ "$device_id" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || die "Некорректное имя устройства"
  endpoint="$(awk -F= '$1 == "HUB_ENDPOINT" { print $2; exit }' "$HUB_CONFIG")"
  token="$(
    set -a
    # shellcheck disable=SC1090
    . "$CONTROL_ENV"
    set +a
    runuser -u "$CONTROL_USER" -m -- "$CONTROL_BINARY" device-token-create "$device_id"
  )"
  [[ "$token" =~ ^[A-Za-z0-9_-]{43}$ ]] || die "Control Hub не создал device token"
  ca="$(base64 -w0 "$CONTROL_CA_CERT")"
  payload="$(printf 'VERSION=1\nDEVICE=%s\nURL=https://%s:%s\nTOKEN=%s\nCA=%s\n' \
    "$device_id" "$endpoint" "$CONTROL_PORT" "$token" "$ca")"
  printf 'SMMDEV1-%s\n' "$(printf '%s' "$payload" | base64url_encode)"
  unset token payload ca
}

read_control_join_code() {
  if [[ -n "${SMM_CONTROL_CODE:-}" ]]; then
    CONTROL_JOIN_CODE="$SMM_CONTROL_CODE"
  elif [[ -r /dev/tty ]]; then
    printf '\nНа Hub выполните: sudo %s control-code ИМЯ\n' "$0"
    IFS= read -r -s -p 'Вставьте одноразовый код SMMCTL1: ' CONTROL_JOIN_CODE < /dev/tty
    printf '\n'
  else
    die "Передайте код через SMM_CONTROL_CODE"
  fi
  CONTROL_JOIN_CODE="${CONTROL_JOIN_CODE//$'\r'/}"
  [[ "$CONTROL_JOIN_CODE" == SMMCTL1-* ]] || die "Ожидается код формата SMMCTL1-..."
}

configure_agent_service() {
  local node_id="$1" control_url="$2" ca_path="${AGENT_STATE}/control-ca.crt"
  cat > "$AGENT_ENV" <<EOF
SMM_NodeId=${node_id}
SMM_ControlUrl=${control_url}
SMM_StateDirectory=${AGENT_STATE}
SMM_CertificateAuthorityPath=${ca_path}
SMM_HeartbeatSeconds=30
EOF
  chmod 0600 "$AGENT_ENV"
  cat > "$AGENT_SERVICE" <<EOF
[Unit]
Description=Ochenstarik Server Monitor Manager Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${AGENT_USER}
Group=${AGENT_USER}
EnvironmentFile=${AGENT_ENV}
ExecStart=${AGENT_BINARY}
Restart=on-failure
RestartSec=10s
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
LockPersonality=true
RestrictSUIDSGID=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
ReadWritePaths=${AGENT_STATE}

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$AGENT_SERVICE"
}

install_control_agent() {
  local payload version name control_url token ca temporary ca_path
  read_control_join_code
  payload="$(base64url_decode "${CONTROL_JOIN_CODE#SMMCTL1-}")" \
    || die "Не удалось декодировать control code"
  version="$(payload_value "$payload" VERSION)"
  name="$(payload_value "$payload" NAME)"
  control_url="$(payload_value "$payload" URL)"
  token="$(payload_value "$payload" TOKEN)"
  ca="$(payload_value "$payload" CA)"
  [[ "$version" == 1 ]] || die "Неподдерживаемая версия control code"
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || die "Некорректное имя Agent"
  [[ "$control_url" =~ ^https://[A-Za-z0-9.-]+:[0-9]{1,5}$ ]] || die "Некорректный Control URL"
  [[ "$token" =~ ^[A-Za-z0-9_-]{43}$ ]] || die "Некорректный control token"
  temporary="$(mktemp)"
  trap 'rm -f -- "${temporary:-}"' RETURN
  printf '%s' "$ca" | base64 -d > "$temporary" 2>/dev/null \
    || die "Некорректный CA в control code"
  openssl x509 -in "$temporary" -noout -checkend 86400 >/dev/null \
    || die "Control CA недействителен или скоро истекает"
  download_control_layer
  ensure_system_user "$AGENT_USER" "$AGENT_STATE"
  install -d -m 0700 -o root -g root "$MESH_DIR"
  ca_path="${AGENT_STATE}/control-ca.crt"
  install -m 0600 -o "$AGENT_USER" -g "$AGENT_USER" "$temporary" "$ca_path"
  configure_agent_service "$name" "$control_url"
  runuser -u "$AGENT_USER" -- env \
    "SMM_NodeId=${name}" \
    "SMM_ControlUrl=${control_url}" \
    "SMM_StateDirectory=${AGENT_STATE}" \
    "SMM_CertificateAuthorityPath=${ca_path}" \
    "SMM_EnrollToken=${token}" \
    "$AGENT_BINARY"
  systemctl daemon-reload
  systemctl enable --now ochenstarik-smm-agent.service
  trap - RETURN
  rm -f -- "$temporary"
  unset token payload ca CONTROL_JOIN_CODE SMM_CONTROL_CODE
  log "Control Agent $name зарегистрирован и запущен"
}

read_join_code() {
  if [[ -n "${SMM_JOIN_CODE:-}" ]]; then
    JOIN_CODE="$SMM_JOIN_CODE"
  elif [[ -r /dev/tty ]]; then
    printf '\nНа главном сервере выполните: sudo ochenstarik-smm node-code ИМЯ\n'
    IFS= read -r -s -p 'Вставьте одноразовый код SMM2: ' JOIN_CODE < /dev/tty
    printf '\n'
  else
    die "Передайте код через SMM_JOIN_CODE"
  fi
  JOIN_CODE="${JOIN_CODE//$'\r'/}"
  [[ "$JOIN_CODE" == SMM2-* ]] || die "Ожидается код формата SMM2-..."
}

install_node_mesh() {
  local payload version name address token expires now private_key public_key
  local hub_public_key endpoint allowed_ips request_payload request_code ack expected_ack tmp ssh_port
  install_mesh_dependencies
  read_join_code
  payload="$(base64url_decode "${JOIN_CODE#SMM2-}")" || die "Не удалось декодировать код"
  version="$(payload_value "$payload" VERSION)"
  name="$(payload_value "$payload" NAME)"
  address="$(payload_value "$payload" ADDRESS)"
  token="$(payload_value "$payload" TOKEN)"
  expires="$(payload_value "$payload" EXPIRES)"
  hub_public_key="$(payload_value "$payload" HUB_PUBLIC_KEY)"
  endpoint="$(payload_value "$payload" ENDPOINT)"
  allowed_ips="$(payload_value "$payload" ALLOWED_IPS)"
  [[ "$version" == 2 ]] || die "Неподдерживаемая версия кода"
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || die "Некорректное имя узла"
  [[ "$address" =~ ^10\.77\.0\.([2-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-4])/32$ ]] \
    || die "Некорректный внутренний адрес"
  [[ "$endpoint" =~ ^[A-Za-z0-9.-]+:[0-9]{1,5}$ ]] || die "Некорректный endpoint"
  [[ "$allowed_ips" == "$MESH_CIDR" ]] || die "Некорректная mesh-подсеть"
  [[ "$token" =~ ^[a-f0-9]{64}$ ]] || die "Некорректный enrollment token"
  now="$(date +%s)"
  [[ "$expires" =~ ^[0-9]+$ ]] && (( expires > now )) || die "Enrollment-код истёк"
  [[ "$(printf '%s' "$hub_public_key" | base64 -d 2>/dev/null | wc -c)" -eq 32 ]] \
    || die "Некорректный публичный ключ Hub"
  private_key="$(wg genkey)"
  public_key="$(printf '%s' "$private_key" | wg pubkey)"
  request_payload="$(printf 'VERSION=1\nTOKEN=%s\nNAME=%s\nADDRESS=%s\nPUBLIC_KEY=%s\n' \
    "$token" "$name" "$address" "$public_key")"
  request_code="SMMREQ1-$(printf '%s' "$request_payload" | base64url_encode)"
  printf '\nПриватный WireGuard-ключ создан локально и не покидает Node.\n'
  printf 'Request-код:\n\n%s\n\n' "$request_code"
  printf 'На Hub выполните: sudo ochenstarik-smm node-enroll\n'
  printf 'Вставьте request-код по скрытому запросу и верните полученный SMMACK1.\n\n'
  expected_ack="$(printf '%s|%s|%s|%s|%s|%s|%s' \
    "$token" "$public_key" "$name" "$address" "$hub_public_key" "$endpoint" "$allowed_ips" \
    | sha256sum | awk '{ print $1 }')"
  if [[ -n "${SMM_ENROLL_ACK:-}" ]]; then
    ack="$SMM_ENROLL_ACK"
    ack="${ack//$'\r'/}"
    [[ "$ack" == "SMMACK1-${expected_ack}" ]] \
      || die "Hub не подтвердил регистрацию этого Node"
  elif [[ -r /dev/tty ]]; then
    while true; do
      IFS= read -r -s -p 'Вставьте ответ SMMACK1 от Hub: ' ack < /dev/tty
      printf '\n'
      ack="${ack//$'\r'/}"
      [[ "$ack" == "SMMACK1-${expected_ack}" ]] && break
      warn "Код не подтверждает этот Node. Повторите вставку или нажмите Ctrl+C."
    done
  else
    die "Передайте подтверждение через SMM_ENROLL_ACK"
  fi
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
    "$name" "$address" "$public_key" > "$MESH_DIR/node.conf"
  chmod 0600 "$MESH_DIR/node.conf"
  unset private_key token payload request_payload JOIN_CODE SMM_JOIN_CODE SMM_ENROLL_ACK ack expected_ack
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
  log "После установки Control Hub добавьте Agent: sudo $0 install-control-agent"
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
  printf 'Control Hub: %s\n' "$(systemctl is-active ochenstarik-smm-control.service 2>/dev/null || true)"
  printf 'Control Agent: %s\n' "$(systemctl is-active ochenstarik-smm-agent.service 2>/dev/null || true)"
}

install_server_part() {
  install_monitoring
  log "Серверная часть мониторинга установлена"
  log "Входящий порт не изменялся, новые правила UFW не создавались"
  show_status
}

confirm_action() {
  local prompt="$1" answer
  if [[ -r /dev/tty ]]; then
    IFS= read -r -p "$prompt [y/N]: " answer < /dev/tty
  else
    die "Для этой операции требуется интерактивный терминал"
  fi
  [[ "$answer" =~ ^[Yy]$ ]]
}

backup_state() {
  local backup_dir="/var/backups/${APP_NAME}" backup_file timestamp path
  local -a paths=()
  install -d -m 0700 -o root -g root "$backup_dir"
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup_file="${backup_dir}/${timestamp}.tar.gz"
  for path in \
    "$MESH_DIR" "$MONITOR_HOME" "$MONITOR_COMMAND" "$MONITOR_SSH_CONFIG" "$HUB_HELPER" "$HUB_CLI" \
    "$CONTROL_POLICY_HELPER" "$WG_CONFIG" \
    /etc/systemd/system/ochenstarik-smm-firewall.service \
    /etc/systemd/system/ochenstarik-smm-firewall.timer \
    /etc/sudoers.d/ochenstarik-smm-hub \
    /etc/sysctl.d/90-ochenstarik-smm-forward.conf \
    "$CONTROL_SERVICE" "$AGENT_SERVICE" "$CONTROL_BINARY" "$AGENT_BINARY" \
    "$CONTROL_STATE" "$AGENT_STATE" "$CONTROL_ENV" "$AGENT_ENV" "$CONTROL_CA_CERT"; do
    [[ -e "$path" || -L "$path" ]] && paths+=("${path#/}")
  done
  ((${#paths[@]} > 0)) || { warn "Нет установленных файлов для backup"; return 0; }
  tar -C / -czf "$backup_file" -- "${paths[@]}"
  chmod 0600 "$backup_file"
  log "Backup: $backup_file"
}

rollback_state() {
  local backup_dir="/var/backups/${APP_NAME}" latest
  latest="$(find "$backup_dir" -maxdepth 1 -type f -name '*.tar.gz' -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr | awk 'NR == 1 { sub(/^[^ ]+ /, ""); print }')"
  [[ -n "$latest" && -f "$latest" ]] || die "Backup для rollback не найден"
  confirm_action "Восстановить $latest" || { log "Отменено"; return 0; }
  tar -C / -xzf "$latest"
  systemctl daemon-reload
  [[ ! -f "$WG_CONFIG" ]] || systemctl restart "wg-quick@${WG_INTERFACE}.service"
  [[ ! -x "$HUB_HELPER" ]] || "$HUB_HELPER" firewall-restore
  [[ ! -x "$MONITOR_COMMAND" ]] || systemctl reload ssh
  log "Rollback завершён: $latest"
}

existing_public_key() {
  [[ -r "$AUTHORIZED_KEYS" ]] || die "Не найден существующий SSH-ключ мониторинга"
  sed -n 's/^.*\(ssh-ed25519 [A-Za-z0-9+\/=]*.*\)$/\1/p' "$AUTHORIZED_KEYS" | head -n 1
}

update_installed() {
  local role=monitor
  backup_state
  SERVER_MONITOR_PUBLIC_KEY="$(existing_public_key)"
  export SERVER_MONITOR_PUBLIC_KEY
  if [[ -r "$HUB_CONFIG" ]]; then
    role=hub
    SMM_HUB_ENDPOINT="$(awk -F= '$1 == "HUB_ENDPOINT" { print $2; exit }' "$HUB_CONFIG")"
    SMM_WG_PORT="$(awk -F= '$1 == "WG_PORT" { print $2; exit }' "$HUB_CONFIG")"
    export SMM_HUB_ENDPOINT SMM_WG_PORT
    install_hub
  elif [[ -r "$MESH_DIR/node.conf" ]]; then
    role=node
    install_monitoring
    install_mesh_dependencies
    systemctl enable --now "wg-quick@${WG_INTERFACE}.service"
    systemctl restart "wg-quick@${WG_INTERFACE}.service"
  else
    install_server_part
  fi
  unset SERVER_MONITOR_PUBLIC_KEY SMM_HUB_ENDPOINT SMM_WG_PORT
  log "Обновление роли $role завершено"
}

uninstall_monitor() {
  [[ ! -r "$HUB_CONFIG" && ! -r "$MESH_DIR/node.conf" ]] \
    || die "Сначала удалите роль командой uninstall-hub или uninstall-node"
  confirm_action "Удалить пользователя мониторинга и forced-command" || { log "Отменено"; return 0; }
  backup_state
  rm -f -- "$MONITOR_COMMAND" "$MONITOR_SSH_CONFIG"
  if getent passwd "$MONITOR_USER" >/dev/null; then
    userdel --remove "$MONITOR_USER" 2>/dev/null || userdel "$MONITOR_USER"
  fi
  systemctl reload ssh
  log "Серверная часть мониторинга удалена"
}

uninstall_node() {
  local ssh_port
  [[ -r "$MESH_DIR/node.conf" ]] || die "Роль Node не установлена"
  confirm_action "Отключить и удалить WireGuard Node" || { log "Отменено"; return 0; }
  backup_state
  systemctl disable --now "wg-quick@${WG_INTERFACE}.service" 2>/dev/null || true
  systemctl disable --now ochenstarik-smm-agent.service 2>/dev/null || true
  ssh_port="$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }')"
  if command -v ufw >/dev/null 2>&1 && [[ -n "$ssh_port" ]]; then
    ufw --force delete allow in on "$WG_INTERFACE" to any port "$ssh_port" proto tcp >/dev/null 2>&1 || true
  fi
  rm -f -- "$WG_CONFIG" "$MESH_DIR/node.conf" "$AGENT_SERVICE" "$AGENT_ENV"
  rm -rf -- "$AGENT_STATE" "$(dirname "$AGENT_BINARY")"
  getent passwd "$AGENT_USER" >/dev/null && userdel "$AGENT_USER" 2>/dev/null || true
  systemctl daemon-reload
  rmdir "$MESH_DIR" 2>/dev/null || true
  log "WireGuard Node удалён; monitoring identity оставлена"
}

uninstall_hub() {
  local wg_port
  [[ -r "$HUB_CONFIG" ]] || die "Роль Hub не установлена"
  confirm_action "Удалить Hub, все Node identities, Links и аудит" || { log "Отменено"; return 0; }
  backup_state
  wg_port="$(awk -F= '$1 == "WG_PORT" { print $2; exit }' "$HUB_CONFIG")"
  systemctl disable --now ochenstarik-smm-firewall.timer ochenstarik-smm-firewall.service 2>/dev/null || true
  systemctl disable --now ochenstarik-smm-control.service 2>/dev/null || true
  systemctl disable --now "wg-quick@${WG_INTERFACE}.service" 2>/dev/null || true
  nft delete table inet ochenstarik_smm >/dev/null 2>&1 || true
  if command -v ufw >/dev/null 2>&1; then
    ufw --force delete allow "$wg_port/udp" >/dev/null 2>&1 || true
    ufw --force route delete allow in on "$WG_INTERFACE" out on "$WG_INTERFACE" >/dev/null 2>&1 || true
  fi
  rm -f -- \
    /etc/systemd/system/ochenstarik-smm-firewall.service \
    /etc/systemd/system/ochenstarik-smm-firewall.timer \
    /etc/sudoers.d/ochenstarik-smm-hub \
    /etc/sysctl.d/90-ochenstarik-smm-forward.conf \
    "$HUB_HELPER" "$HUB_CLI" "$CONTROL_POLICY_HELPER" "$WG_CONFIG" \
    "$CONTROL_SERVICE" "$CONTROL_ENV" "$CONTROL_CA_CERT"
  rm -rf -- "$CONTROL_STATE" "$(dirname "$CONTROL_BINARY")"
  getent passwd "$CONTROL_USER" >/dev/null && userdel "$CONTROL_USER" 2>/dev/null || true
  rm -rf -- "$MESH_DIR"
  systemctl daemon-reload
  sysctl --system >/dev/null
  log "Mesh Hub удалён; monitoring identity оставлена"
}

main() {
  local action="${1:-install}"
  require_root
  detect_system
  case "$action" in
    install|install-monitor) install_server_part ;;
    hub|install-hub) install_hub ;;
    node|install-node) install_node ;;
    install-control-hub) install_control_hub ;;
    install-control-agent) install_control_agent ;;
    control-code) [[ $# -eq 2 ]] || die "Использование: $0 control-code NAME"; create_control_join_code "$2" ;;
    control-device-code) [[ $# -eq 2 ]] || die "Использование: $0 control-device-code DEVICE"; create_device_join_code "$2" ;;
    hub-code) [[ $# -eq 2 ]] || die "Использование: $0 hub-code NAME"; exec "$HUB_HELPER" node-code "$2" ;;
    status) show_status ;;
    update) update_installed ;;
    rollback) rollback_state ;;
    uninstall-monitor) uninstall_monitor ;;
    uninstall-node) uninstall_node ;;
    uninstall-hub) uninstall_hub ;;
    uninstall) die "Укажите роль: uninstall-monitor, uninstall-node или uninstall-hub" ;;
    *) die "Использование: $0 {install-monitor|install-hub|install-node|install-control-hub|install-control-agent|control-code NAME|control-device-code DEVICE|hub-code NAME|status|update|rollback|uninstall-monitor|uninstall-node|uninstall-hub}" ;;
  esac
}

main "$@"
