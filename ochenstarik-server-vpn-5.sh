#!/usr/bin/env bash
set -Eeuo pipefail

readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly XRAY_DIR="/usr/local/etc/xray"
readonly STATE_DIR="/etc/ochenstarik-xray"
readonly NFT_FILE="${STATE_DIR}/routing.nft"
readonly ROUTE_HELPER="/usr/local/sbin/ochenstarik-xray-routing"
readonly ROUTE_SERVICE="/etc/systemd/system/ochenstarik-xray-routing.service"
readonly TPROXY_PORT="12345"
readonly SOCKS_PORT="10808"

log() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

TMP_DIR=""
cleanup() {
  [[ -z "$TMP_DIR" ]] || rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

public_ipv4() {
  local ip
  ip="$(curl -fsS -4 --max-time 12 https://api.ipify.org 2>/dev/null \
    || curl -fsS -4 --max-time 12 https://ipv4.icanhazip.com 2>/dev/null \
    || true)"
  printf '%s' "$ip" | tr -d '\r\n'
}

valid_ipv4() {
  local ip="$1" octet
  local -a octets
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r -a octets <<< "$ip"
  for octet in "${octets[@]}"; do
    (( 10#$octet <= 255 )) || return 1
  done
}

stop_rollback_timer() {
  systemctl stop ochenstarik-xray-rollback.timer >/dev/null 2>&1 || true
  systemctl reset-failed ochenstarik-xray-rollback.timer \
    ochenstarik-xray-rollback.service >/dev/null 2>&1 || true
}

[[ "$EUID" -eq 0 ]] || die "Запустите этот скрипт от имени root"

if [[ "${1:-}" == "--disable" ]]; then
  systemctl disable --now ochenstarik-xray-routing.service >/dev/null 2>&1 || true
  [[ ! -x "$ROUTE_HELPER" ]] || "$ROUTE_HELPER" stop
  log "Системная маршрутизация через Xray отключена"
  if command -v curl >/dev/null 2>&1; then
    printf 'Текущий внешний IP: %s\n' "$(public_ipv4)"
  fi
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
log "Установка системных зависимостей"
apt-get update
apt-get install -y curl ca-certificates jq nftables iproute2 python3

if systemctl is-active --quiet ochenstarik-xray-routing.service; then
  warn "Обнаружена действующая маршрутизация Xray; временно отключаю её для проверки прямого IP"
  systemctl disable --now ochenstarik-xray-routing.service
elif systemctl is-enabled --quiet ochenstarik-xray-routing.service 2>/dev/null; then
  systemctl disable ochenstarik-xray-routing.service
fi

BEFORE_IP="$(public_ipv4)"
valid_ipv4 "$BEFORE_IP" || die "Не удалось определить исходный внешний IPv4"
printf 'Внешний IP до подключения VPN: %s\n' "$BEFORE_IP"

printf 'Вставьте прямую ссылку vless:// или HTTPS-ссылку подписки 3x-ui. Ввод будет скрыт.\n'
read -rsp 'Ссылка VLESS/подписки: ' SUBSCRIPTION_INPUT
printf '\n'
[[ "$SUBSCRIPTION_INPUT" == vless://* || "$SUBSCRIPTION_INPUT" == https://* ]] \
  || die "Поддерживаются только ссылки vless:// и https://"

TMP_DIR="$(mktemp -d)"
chmod 700 "$TMP_DIR"
RAW_FILE="${TMP_DIR}/subscription.txt"
LINKS_FILE="${TMP_DIR}/vless-links.txt"
LINK_FILE="${TMP_DIR}/vless-link.txt"
PORTS_FILE="${TMP_DIR}/vless-ports.txt"
GENERATED_CONFIG="${TMP_DIR}/config.json"
INSTALLER_FILE="${TMP_DIR}/install-release.sh"

if [[ "$SUBSCRIPTION_INPUT" == vless://* ]]; then
  printf '%s' "$SUBSCRIPTION_INPUT" > "$RAW_FILE"
else
  {
    printf 'url = "%s"\n' "$SUBSCRIPTION_INPUT"
    printf 'fail\nsilent\nshow-error\nlocation\n'
    printf 'proto = "=https"\ntlsv1.2\nmax-time = 30\n'
  } | curl --config - > "$RAW_FILE" \
    || die "Не удалось загрузить подписку"
fi
unset SUBSCRIPTION_INPUT
chmod 600 "$RAW_FILE"

python3 - "$RAW_FILE" "$LINKS_FILE" "$PORTS_FILE" <<'PY'
import base64
import pathlib
import sys
import urllib.parse

raw = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").strip()

def find_vless(text: str):
    result = []
    for line in text.replace("\r", "").split("\n"):
        line = line.strip()
        if line.startswith("vless://"):
            result.append(line)
    return result

links = find_vless(raw)
if not links:
    try:
        padded = raw.replace("-", "+").replace("_", "/")
        padded += "=" * (-len(padded) % 4)
        decoded = base64.b64decode(padded, validate=False).decode("utf-8")
    except Exception as exc:
        raise SystemExit(f"Подписка не является Base64/VLESS: {exc}")
    links = find_vless(decoded)

links = list(dict.fromkeys(links))
if not links:
    raise SystemExit("В подписке не найдена ссылка vless://")

ports = []
for link in links:
    try:
        port = urllib.parse.urlsplit(link).port
    except ValueError as exc:
        raise SystemExit(f"Некорректный порт в VLESS-ссылке: {exc}")
    if port is None:
        raise SystemExit("В одной из VLESS-ссылок отсутствует порт")
    if port not in ports:
        ports.append(port)

pathlib.Path(sys.argv[2]).write_text("\n".join(links) + "\n", encoding="utf-8")
pathlib.Path(sys.argv[3]).write_text(
    "\n".join(str(port) for port in ports) + "\n", encoding="utf-8"
)
PY
chmod 600 "$LINKS_FILE" "$PORTS_FILE"

mapfile -t SUBSCRIPTION_PORTS < "$PORTS_FILE"
(( ${#SUBSCRIPTION_PORTS[@]} > 0 )) || die "В подписке не найдены доступные порты"
printf 'Доступные порты в подписке: %s\n' "${SUBSCRIPTION_PORTS[*]}"

while :; do
  read -rp "Выберите порт подписки [${SUBSCRIPTION_PORTS[0]}]: " SUBSCRIPTION_PORT
  SUBSCRIPTION_PORT="${SUBSCRIPTION_PORT:-${SUBSCRIPTION_PORTS[0]}}"
  [[ "$SUBSCRIPTION_PORT" =~ ^[0-9]{1,5}$ ]] \
    && (( 10#$SUBSCRIPTION_PORT >= 1 && 10#$SUBSCRIPTION_PORT <= 65535 )) \
    || { warn "Порт должен быть числом от 1 до 65535"; continue; }
  SUBSCRIPTION_PORT="$((10#$SUBSCRIPTION_PORT))"

  port_found="no"
  for available_port in "${SUBSCRIPTION_PORTS[@]}"; do
    if [[ "$SUBSCRIPTION_PORT" == "$available_port" ]]; then
      port_found="yes"
      break
    fi
  done
  [[ "$port_found" == yes ]] && break
  warn "Порт ${SUBSCRIPTION_PORT} отсутствует в подписке"
done

python3 - "$LINKS_FILE" "$LINK_FILE" "$SUBSCRIPTION_PORT" <<'PY'
import pathlib
import sys
import urllib.parse

links = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
selected_port = int(sys.argv[3])
for link in links:
    if urllib.parse.urlsplit(link).port == selected_port:
        pathlib.Path(sys.argv[2]).write_text(link, encoding="utf-8")
        break
else:
    raise SystemExit(f"VLESS-ссылка для порта {selected_port} не найдена")
PY
chmod 600 "$LINK_FILE"
log "Выбран порт подписки ${SUBSCRIPTION_PORT}"

VPN_IP="$(python3 - "$LINK_FILE" "$GENERATED_CONFIG" "$TPROXY_PORT" "$SOCKS_PORT" <<'PY'
import json
import pathlib
import socket
import sys
import urllib.parse

link = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").strip()
output = pathlib.Path(sys.argv[2])
tproxy_port = int(sys.argv[3])
socks_port = int(sys.argv[4])

uri = urllib.parse.urlsplit(link)
if uri.scheme.lower() != "vless":
    raise SystemExit("Ожидалась ссылка vless://")

client_id = urllib.parse.unquote(uri.username or "")
host = uri.hostname or ""
port = uri.port
query = {key: values[-1] for key, values in urllib.parse.parse_qs(
    uri.query, keep_blank_values=True
).items()}

if not client_id or not host or not port:
    raise SystemExit("В ссылке отсутствует UUID, адрес или порт")

transport = query.get("type", "tcp").lower()
if transport not in {"tcp", "raw"}:
    raise SystemExit(f"Поддерживается только TCP/RAW, получено: {transport}")

security = query.get("security", "").lower()
if security != "reality":
    raise SystemExit(f"Поддерживается только REALITY, получено: {security or 'пусто'}")

server_name = query.get("sni", "")
password = query.get("pbk", "")
fingerprint = query.get("fp", "chrome") or "chrome"
short_id = query.get("sid", "")
spider_x = query.get("spx", "/") or "/"
flow = query.get("flow", "")
encryption = query.get("encryption", "none") or "none"

if not server_name or not password:
    raise SystemExit("В REALITY-ссылке отсутствуют параметры sni или pbk")

try:
    addresses = socket.getaddrinfo(host, port, socket.AF_INET, socket.SOCK_STREAM)
except socket.gaierror as exc:
    raise SystemExit(f"Не удалось определить IPv4 VPN-сервера: {exc}")

vpn_ip = addresses[0][4][0]
settings = {
    "address": vpn_ip,
    "port": port,
    "id": client_id,
    "encryption": encryption,
}
if flow:
    settings["flow"] = flow

config = {
    "log": {
        "loglevel": "warning",
        "access": "/var/log/xray/access.log",
        "error": "/var/log/xray/error.log",
    },
    "inbounds": [
        {
            "tag": "transparent-in",
            "port": tproxy_port,
            "protocol": "tunnel",
            "settings": {
                "allowedNetwork": "tcp,udp",
                "followRedirect": True,
            },
            "sniffing": {
                "enabled": True,
                "destOverride": ["http", "tls", "quic"],
            },
            "streamSettings": {
                "sockopt": {"tproxy": "tproxy"},
            },
        },
        {
            "tag": "socks-in",
            "listen": "127.0.0.1",
            "port": socks_port,
            "protocol": "socks",
            "settings": {"udp": True},
        },
    ],
    "outbounds": [
        {
            "tag": "vpn-out",
            "protocol": "vless",
            "settings": settings,
            "streamSettings": {
                "network": "raw",
                "security": "reality",
                "realitySettings": {
                    "serverName": server_name,
                    "fingerprint": fingerprint,
                    "password": password,
                    "shortId": short_id,
                    "spiderX": spider_x,
                },
                "sockopt": {"mark": 2},
            },
        }
    ],
}

output.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(vpn_ip)
PY
)" || die "Не удалось разобрать VLESS-ссылку"
valid_ipv4 "$VPN_IP" || die "Получен некорректный IPv4 VPN-сервера"
chmod 600 "$GENERATED_CONFIG"
log "Подписка разобрана: VLESS + TCP/RAW + REALITY"

log "Установка или обновление Xray из официального репозитория XTLS"
curl --fail --silent --show-error --location \
  --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh \
  -o "$INSTALLER_FILE"
chmod 700 "$INSTALLER_FILE"
bash "$INSTALLER_FILE" install

command -v xray >/dev/null 2>&1 || die "Xray не установлен"
install -d -m 755 "$XRAY_DIR" /var/log/xray
touch /var/log/xray/access.log /var/log/xray/error.log

log "Проверка конфигурации Xray"
xray run -test -config "$GENERATED_CONFIG" \
  || die "Xray отклонил сгенерированную конфигурацию"

XRAY_BACKUP=""
if [[ -f "$XRAY_CONFIG" ]]; then
  XRAY_BACKUP="${XRAY_CONFIG}.bak.$(date +%F-%H%M%S-%N)"
  cp -a -- "$XRAY_CONFIG" "$XRAY_BACKUP"
fi

XRAY_GROUP="$(id -gn nobody 2>/dev/null || printf 'nogroup')"
install -o root -g "$XRAY_GROUP" -m 640 "$GENERATED_CONFIG" "$XRAY_CONFIG"
chown nobody:"$XRAY_GROUP" /var/log/xray/access.log /var/log/xray/error.log
chmod 600 /var/log/xray/access.log /var/log/xray/error.log
systemctl daemon-reload
systemctl enable --now xray.service
systemctl restart xray.service
sleep 2

if ! systemctl is-active --quiet xray.service; then
  [[ -z "$XRAY_BACKUP" ]] || cp -a -- "$XRAY_BACKUP" "$XRAY_CONFIG"
  systemctl restart xray.service >/dev/null 2>&1 || true
  die "Служба Xray не запустилась; предыдущая конфигурация восстановлена"
fi

log "Проверка VLESS через локальный SOCKS-порт ${SOCKS_PORT}"
PROXY_IP="$(curl -fsS -4 --max-time 20 \
  --socks5-hostname "127.0.0.1:${SOCKS_PORT}" \
  https://api.ipify.org 2>/dev/null || true)"
PROXY_IP="$(printf '%s' "$PROXY_IP" | tr -d '\r\n')"
if ! valid_ipv4 "$PROXY_IP"; then
  [[ -z "$XRAY_BACKUP" ]] || cp -a -- "$XRAY_BACKUP" "$XRAY_CONFIG"
  systemctl restart xray.service >/dev/null 2>&1 || true
  die "VLESS не прошёл предварительную проверку через SOCKS"
fi
printf 'IP через локальный прокси Xray: %s\n' "$PROXY_IP"
[[ "$PROXY_IP" != "$BEFORE_IP" ]] \
  || die "IP через Xray совпадает с исходным; системная маршрутизация не включена"

SSH_PORT="$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }' || true)"
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || SSH_PORT="20202"

install -d -m 700 -o root -g root "$STATE_DIR"
cat > "$NFT_FILE" <<EOF
table ip ochenstarik_xray {
  set bypass_ipv4 {
    type ipv4_addr
    flags interval
    elements = {
      0.0.0.0/8,
      10.0.0.0/8,
      100.64.0.0/10,
      127.0.0.0/8,
      169.254.0.0/16,
      172.16.0.0/12,
      192.0.0.0/24,
      192.0.2.0/24,
      192.168.0.0/16,
      198.18.0.0/15,
      198.51.100.0/24,
      203.0.113.0/24,
      224.0.0.0/4,
      240.0.0.0/4,
      ${BEFORE_IP},
      ${VPN_IP}
    }
  }

  chain prerouting {
    type filter hook prerouting priority mangle; policy accept;
    meta mark 1 meta l4proto tcp tproxy to 127.0.0.1:${TPROXY_PORT} accept
    meta mark 1 meta l4proto udp tproxy to 127.0.0.1:${TPROXY_PORT} accept
  }

  chain output {
    type route hook output priority mangle; policy accept;
    meta mark 2 return
    ip daddr @bypass_ipv4 return
    tcp sport { ${SSH_PORT}, 443, 63636 } return
    ip protocol tcp meta mark set 1
    ip protocol udp meta mark set 1
  }
}

table ip6 ochenstarik_xray6 {
  set bypass_ipv6 {
    type ipv6_addr
    flags interval
    elements = {
      ::/128,
      ::1/128,
      fc00::/7,
      fe80::/10,
      ff00::/8
    }
  }

  chain output {
    type filter hook output priority filter; policy accept;
    meta mark 2 return
    ip6 daddr @bypass_ipv6 return
    tcp sport { ${SSH_PORT}, 443, 63636 } return
    reject with icmpv6 type admin-prohibited
  }
}
EOF
chmod 600 "$NFT_FILE"

cat > "$ROUTE_HELPER" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
NFT_FILE="${NFT_FILE}"

stop_routes() {
  nft list table ip ochenstarik_xray >/dev/null 2>&1 \
    && nft delete table ip ochenstarik_xray || true
  nft list table ip6 ochenstarik_xray6 >/dev/null 2>&1 \
    && nft delete table ip6 ochenstarik_xray6 || true
  while ip rule del priority 100 fwmark 0x1/0x1 table 100 2>/dev/null; do :; done
  ip route flush table 100 2>/dev/null || true
}

case "\${1:-}" in
  start)
    stop_routes
    ip route add local 0.0.0.0/0 dev lo table 100
    ip rule add priority 100 fwmark 0x1/0x1 table 100
    nft -f "\$NFT_FILE"
    ;;
  stop)
    stop_routes
    ;;
  restart)
    stop_routes
    "\$0" start
    ;;
  status)
    ip rule show
    ip route show table 100
    nft list table ip ochenstarik_xray
    ;;
  *)
    echo "Использование: \$0 {start|stop|restart|status}" >&2
    exit 2
    ;;
esac
EOF
chmod 700 "$ROUTE_HELPER"

cat > "$ROUTE_SERVICE" <<EOF
[Unit]
Description=Ochenstarik Xray system traffic routing
After=network-online.target xray.service
Wants=network-online.target
Requires=xray.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${ROUTE_HELPER} start
ExecStop=${ROUTE_HELPER} stop

[Install]
WantedBy=multi-user.target
EOF
chmod 644 "$ROUTE_SERVICE"
systemctl daemon-reload

log "Запуск маршрутизации с автоматическим откатом через 2 минуты"
systemd-run --quiet --unit=ochenstarik-xray-rollback --on-active=2m \
  "$ROUTE_HELPER" stop

if ! systemctl start ochenstarik-xray-routing.service; then
  stop_rollback_timer
  "$ROUTE_HELPER" stop
  die "Не удалось применить правила маршрутизации"
fi

sleep 2
AFTER_IP="$(public_ipv4)"
if ! valid_ipv4 "$AFTER_IP" || [[ "$AFTER_IP" != "$PROXY_IP" ]]; then
  "$ROUTE_HELPER" stop
  systemctl stop ochenstarik-xray-routing.service >/dev/null 2>&1 || true
  stop_rollback_timer
  die "Итоговая проверка IP не пройдена; маршрутизация автоматически отключена"
fi

systemctl enable ochenstarik-xray-routing.service >/dev/null
stop_rollback_timer

printf '\nНастройка завершена успешно.\n'
printf 'IP до VPN:      %s\n' "$BEFORE_IP"
printf 'IP через Xray:  %s\n' "$PROXY_IP"
printf 'IP после VPN:   %s\n' "$AFTER_IP"
printf 'SSH-порт %s и ответы сервисов 443/63636 оставлены напрямую.\n' "$SSH_PORT"
printf 'Публичный IPv6 заблокирован, чтобы исключить обход VPN.\n'
printf '\nОтключить системный VPN:\n  %s --disable\n' "$0"
printf 'Проверить маршрутизацию:\n  %s status\n' "$ROUTE_HELPER"
