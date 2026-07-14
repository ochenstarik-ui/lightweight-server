#!/usr/bin/env bash
set -Eeuo pipefail

readonly CONFIG_FILE="/etc/ochenstarik-server/telegram.conf"
readonly NOTIFY_SCRIPT="/usr/local/libexec/ochenstarik-ssh-login-telegram.sh"
readonly LOG_FILE="/var/log/ochenstarik-ssh-login-telegram.log"
readonly LOGROTATE_FILE="/etc/logrotate.d/ochenstarik-ssh-login-telegram"
readonly PAM_SSHD="/etc/pam.d/sshd"
readonly LEGACY_NOTIFY_SCRIPT="/usr/local/libexec/ssh-login-telegram.sh"

log() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

backup_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  cp -a -- "$file" "${file}.bak.$(date +%F-%H%M%S-%N)"
}

is_ipv4() {
  local ip="$1" octet
  local -a octets
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r -a octets <<< "$ip"
  for octet in "${octets[@]}"; do
    (( 10#$octet <= 255 )) || return 1
  done
}

send_message() {
  local token="$1" chat_id="$2" text_file="$3"
  local response_file http_code
  response_file="$(mktemp)"
  chmod 600 "$response_file"

  if ! http_code="$({
    printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$token"
    printf 'request = "POST"\n'
    printf 'silent\nshow-error\nmax-time = 10\n'
  } | curl --config - --output "$response_file" --write-out '%{http_code}' \
    --data-urlencode "chat_id=${chat_id}" --data-urlencode "text@${text_file}")"; then
    rm -f -- "$response_file"
    return 1
  fi

  if [[ "$http_code" == 200 ]] && grep -q '"ok":true' "$response_file"; then
    rm -f -- "$response_file"
    return 0
  fi

  warn "API Telegram вернул код HTTP ${http_code}"
  sed -n '1p' "$response_file" >&2 || true
  rm -f -- "$response_file"
  return 1
}

[[ "$EUID" -eq 0 ]] || die "Запустите этот скрипт от имени root"
for command_name in curl sshd; do
  command -v "$command_name" >/dev/null 2>&1 || die "Не найдена команда: $command_name; сначала запустите второй скрипт"
done
[[ -f "$PAM_SSHD" && ! -L "$PAM_SSHD" ]] || die "Не найден файл конфигурации PAM для SSH: $PAM_SSHD"

printf 'Создайте бота через @BotFather, отправьте ему хотя бы одно сообщение, затем укажите данные бота.\n'
while :; do
  read -rsp 'Токен Telegram-бота: ' TG_BOT_TOKEN
  printf '\n'
  [[ "$TG_BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] && break
  warn "Неверный формат токена"
done

while :; do
  read -rp 'ID чата Telegram: ' TG_CHAT_ID
  [[ "$TG_CHAT_ID" =~ ^-?[0-9]+$ ]] && break
  warn "ID чата должен быть числом"
done

SERVER_IP="$(curl -fsS -4 --max-time 10 https://ipv4.icanhazip.com 2>/dev/null || true)"
SERVER_IP="$(printf '%s' "$SERVER_IP" | tr -d '\r\n')"
if ! is_ipv4 "$SERVER_IP"; then
  SERVER_IP="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -n1 || true)"
fi

umask 077
test_message="$(mktemp)"
trap 'rm -f -- "${test_message:-}"' EXIT
cat > "$test_message" <<EOF
✅ Telegram-уведомления о входах по SSH настроены
Сервер: $(hostname -f 2>/dev/null || hostname)
IP сервера: ${SERVER_IP:-неизвестно}
Дата и время: $(date '+%d.%m.%Y %H:%M:%S %Z')
EOF
send_message "$TG_BOT_TOKEN" "$TG_CHAT_ID" "$test_message" || die "Не удалось отправить тестовое сообщение; проверьте токен, ID чата и отправьте боту команду /start"
log "Тестовое сообщение отправлено в Telegram"

install -d -m 700 -o root -g root /etc/ochenstarik-server /usr/local/libexec
backup_file "$CONFIG_FILE"
cat > "$CONFIG_FILE" <<EOF
TG_BOT_TOKEN=${TG_BOT_TOKEN}
TG_CHAT_ID=${TG_CHAT_ID}
SERVER_IP=${SERVER_IP}
EOF
chmod 600 "$CONFIG_FILE"

cat > "$NOTIFY_SCRIPT" <<'HOOK'
#!/usr/bin/env bash
set -Euo pipefail

readonly CONFIG_FILE="/etc/ochenstarik-server/telegram.conf"
readonly LOG_FILE="/var/log/ochenstarik-ssh-login-telegram.log"
[[ -r "$CONFIG_FILE" ]] || exit 0
umask 077

log_msg() {
  local level="$1" message="$2"
  printf '%s [%s] %s\n' "$(date '+%F %T %Z')" "$level" "$message" >> "$LOG_FILE"
  command -v logger >/dev/null 2>&1 && logger -t ochenstarik-ssh-login-telegram -- "[$level] $message" || true
}

read_config_value() {
  local key="$1"
  sed -n "s/^${key}=//p" "$CONFIG_FILE" | head -n1 | tr -d '\r'
}

TG_BOT_TOKEN="$(read_config_value TG_BOT_TOKEN)"
TG_CHAT_ID="$(read_config_value TG_CHAT_ID)"
SERVER_IP="$(read_config_value SERVER_IP)"
[[ "$TG_BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || { log_msg ERROR "Неверный токен Telegram в конфигурации"; exit 0; }
[[ "$TG_CHAT_ID" =~ ^-?[0-9]+$ ]] || { log_msg ERROR "Неверный ID чата Telegram в конфигурации"; exit 0; }

text_file="$(mktemp)"
response_file="$(mktemp)"
trap 'rm -f -- "$text_file" "$response_file"' EXIT

cat > "$text_file" <<MESSAGE
🔐 Успешный вход на сервер по SSH
Сервер: $(hostname -f 2>/dev/null || hostname)
IP сервера: ${SERVER_IP:-неизвестно}
Пользователь: ${PAM_USER:-неизвестно}
IP подключения: ${PAM_RHOST:-неизвестно}
Служба: ${PAM_SERVICE:-неизвестно}
Терминал: ${PAM_TTY:-неизвестно}
Дата: $(date '+%d.%m.%Y')
Время: $(date '+%H:%M:%S %Z')
MESSAGE

if ! http_code="$({
  printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TG_BOT_TOKEN"
  printf 'request = "POST"\n'
  printf 'silent\nshow-error\nmax-time = 10\n'
} | curl --config - --output "$response_file" --write-out '%{http_code}' \
  --data-urlencode "chat_id=${TG_CHAT_ID}" --data-urlencode "text@${text_file}" 2>> "$LOG_FILE")"; then
  log_msg ERROR "Ошибка отправки в Telegram: пользователь=${PAM_USER:-неизвестно}, IP=${PAM_RHOST:-неизвестно}"
  exit 0
fi

if [[ "$http_code" == 200 ]] && grep -q '"ok":true' "$response_file"; then
  log_msg INFO "Уведомление отправлено: пользователь=${PAM_USER:-неизвестно}, IP=${PAM_RHOST:-неизвестно}"
else
  log_msg ERROR "API Telegram вернул код HTTP ${http_code}: пользователь=${PAM_USER:-неизвестно}"
fi
exit 0
HOOK
chmod 700 "$NOTIFY_SCRIPT"

touch "$LOG_FILE"
chown root:root "$LOG_FILE"
chmod 600 "$LOG_FILE"
cat > "$LOGROTATE_FILE" <<EOF
${LOG_FILE} {
  daily
  rotate 14
  missingok
  notifempty
  compress
  delaycompress
  create 0600 root root
}
EOF
chmod 644 "$LOGROTATE_FILE"

backup_file "$PAM_SSHD"
if grep -Fq -- "$LEGACY_NOTIFY_SCRIPT" "$PAM_SSHD"; then
  sed -i "\|${LEGACY_NOTIFY_SCRIPT}|d" "$PAM_SSHD"
fi
if ! grep -Fq -- "$NOTIFY_SCRIPT" "$PAM_SSHD"; then
  printf 'session optional pam_exec.so seteuid %s\n' "$NOTIFY_SCRIPT" >> "$PAM_SSHD"
fi

sshd -t || die "Проверка sshd после настройки PAM завершилась ошибкой"
log "Telegram-уведомления включены для каждого успешного входа по SSH"
printf 'Файл журнала: %s\n' "$LOG_FILE"
printf 'Для проверки откройте новое SSH-подключение к серверу.\n'