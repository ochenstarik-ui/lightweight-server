#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPO_RAW_BASE="https://raw.githubusercontent.com/ochenstarik-ui/lightweight-server/main"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

declare -a STEP_FILES=(
  "ochenstarik-server-1.sh"
  "ochenstarik-server-2.sh"
  "ochenstarik-server-user-3.sh"
  "ochenstarik-server-tg-4.sh"
  "ochenstarik-server-vpn-5.sh"
  "ochenstarik-server-panel-warp-6.sh"
  "ochenstarik-server-backup-7.sh"
)

declare -a STEP_TITLES=(
  "Часовой пояс, русификация терминала и swap"
  "Базовые пакеты, будущий SSH-порт, IPv4/IPv6 и UFW"
  "Администратор, перенос SSH и fail2ban"
  "Telegram-уведомления о входах по SSH"
  "Системный VPN через Xray"
  "Панель 3x-ui и Cloudflare WARP"
  "Первичный снимок и расписания резервного копирования"
)

TEMP_FILE=""

log() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [[ -n "$TEMP_FILE" && "$TEMP_FILE" == "$SCRIPT_DIR"/.ochenstarik-server-* \
    && -f "$TEMP_FILE" && ! -L "$TEMP_FILE" ]]; then
    rm -f -- "$TEMP_FILE"
  fi
}
trap cleanup EXIT

ensure_step_script() {
  local filename="$1" result_variable="$2" target
  target="${SCRIPT_DIR}/${filename}"

  if [[ -e "$target" ]]; then
    [[ -f "$target" && ! -L "$target" ]] \
      || die "Отказ от запуска: $target должен быть обычным файлом"
  else
    command -v curl >/dev/null 2>&1 \
      || die "Не найден curl: установите его командой apt-get install -y curl ca-certificates"
    [[ -d "$SCRIPT_DIR" && ! -L "$SCRIPT_DIR" && -w "$SCRIPT_DIR" ]] \
      || die "Каталог $SCRIPT_DIR недоступен для безопасной загрузки"

    log "Файл ${filename} отсутствует; загружаю его из основного репозитория"
    TEMP_FILE="$(mktemp "${SCRIPT_DIR}/.ochenstarik-server-download.XXXXXX")"
    chmod 600 "$TEMP_FILE"
    curl -fL --retry 5 --retry-delay 5 --connect-timeout 30 \
      --proto '=https' --tlsv1.2 "${REPO_RAW_BASE}/${filename}" -o "$TEMP_FILE"
    bash -n "$TEMP_FILE" || die "Загруженный файл ${filename} не прошёл проверку Bash"
    chmod 700 "$TEMP_FILE"
    mv -- "$TEMP_FILE" "$target"
    TEMP_FILE=""
  fi

  chmod 700 "$target"
  bash -n "$target" || die "Синтаксическая ошибка в $target"
  printf -v "$result_variable" '%s' "$target"
}

choose_step_action() {
  local step_number="$1" title="$2" result_variable="$3" answer
  while :; do
    printf '\n============================================================\n'
    printf 'Этап %s из %s: %s\n' "$step_number" "${#STEP_FILES[@]}" "$title"
    printf '  1) Установить / запустить этот этап\n'
    printf '  2) Пропустить и перейти к следующему\n'
    printf '  3) Завершить мастер\n'
    read -rp 'Выберите действие: ' answer || die "Ввод прерван"
    case "$answer" in
      1|2|3) printf -v "$result_variable" '%s' "$answer"; return 0 ;;
      *) warn "Введите 1, 2 или 3" ;;
    esac
  done
}

choose_after_failure() {
  local result_variable="$1" answer
  while :; do
    printf '\nЭтап завершился с ошибкой.\n'
    printf '  1) Запустить этот этап повторно\n'
    printf '  2) Пропустить и перейти к следующему\n'
    printf '  3) Завершить мастер\n'
    read -rp 'Выберите действие: ' answer || die "Ввод прерван"
    case "$answer" in
      1|2|3) printf -v "$result_variable" '%s' "$answer"; return 0 ;;
      *) warn "Введите 1, 2 или 3" ;;
    esac
  done
}

print_summary() {
  local completed="$1" skipped="$2"
  printf '\n============================================================\n'
  printf 'Мастер установки завершён.\n'
  printf 'Успешно выполнено этапов: %s\n' "$completed"
  printf 'Пропущено этапов: %s\n' "$skipped"
  printf '\nМастер можно запустить повторно: каждый этап поддерживает повторную настройку.\n'
  printf 'Для полного сброса используйте ochenstarik-server-uninstall.sh.\n'
}

[[ "$EUID" -eq 0 ]] || die "Запустите мастер от имени root: sudo ./ochenstarik-server-install.sh"
((${#STEP_FILES[@]} == ${#STEP_TITLES[@]})) || die "Некорректное описание этапов"

cat <<'INTRO'

Единый мастер установки lightweight-server

Этапы будут показаны по порядку. Каждый из них можно выполнить, пропустить
или завершить весь мастер. Не закрывайте текущую SSH-сессию во время изменения
порта SSH и проверяйте новый вход во втором терминале.
INTRO

completed=0
skipped=0

for index in "${!STEP_FILES[@]}"; do
  step_number="$((index + 1))"
  action=""
  choose_step_action "$step_number" "${STEP_TITLES[index]}" action
  case "$action" in
    2)
      skipped="$((skipped + 1))"
      continue
      ;;
    3)
      print_summary "$completed" "$skipped"
      exit 0
      ;;
  esac

  script_path=""
  ensure_step_script "${STEP_FILES[index]}" script_path
  while :; do
    log "Запуск этапа ${step_number}: ${STEP_TITLES[index]}"
    if bash -- "$script_path"; then
      completed="$((completed + 1))"
      log "Этап ${step_number} успешно завершён"
      break
    fi

    warn "Этап ${step_number} вернул ошибку"
    failure_action=""
    choose_after_failure failure_action
    case "$failure_action" in
      1) continue ;;
      2) skipped="$((skipped + 1))"; break ;;
      3) print_summary "$completed" "$skipped"; exit 1 ;;
    esac
  done
done

print_summary "$completed" "$skipped"
