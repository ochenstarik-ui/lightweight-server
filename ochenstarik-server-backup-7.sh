#!/usr/bin/env bash
set -Eeuo pipefail

readonly DEFAULT_BACKUP_ROOT="/var/backups/ochenstarik-server"
readonly CONFIG_DIR="/etc/ochenstarik-server"
readonly CONFIG_FILE="${CONFIG_DIR}/backup.conf"
readonly BACKUP_RUNNER="/usr/local/sbin/ochenstarik-server-backup"
readonly SERVICE_FILE="/etc/systemd/system/ochenstarik-backup@.service"
readonly TIMER_PREFIX="/etc/systemd/system/ochenstarik-backup"

log() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Не найдена команда: $1"
}

choose_schedules() {
  local answer token
  declare -gA SELECTED_SCHEDULES=()

  while :; do
    printf '\nВыберите автоматические резервные копии (можно несколько):\n'
    printf '  1) Ежедневные — хранить последние 7\n'
    printf '  2) Еженедельные — хранить последние 4\n'
    printf '  3) Ежемесячные — хранить последние 12\n'
    printf '  4) Все расписания\n'
    printf '  0) Только первичный снимок, без расписания\n'
    read -rp "Введите номера через пробел или запятую [4]: " answer \
      || die "Ввод был прерван"
    answer="${answer:-4}"
    answer="${answer//,/ }"
    SELECTED_SCHEDULES=()

    if [[ "$answer" =~ ^[[:space:]]*4[[:space:]]*$ ]]; then
      SELECTED_SCHEDULES[daily]=1
      SELECTED_SCHEDULES[weekly]=1
      SELECTED_SCHEDULES[monthly]=1
      return 0
    fi
    if [[ "$answer" =~ ^[[:space:]]*0[[:space:]]*$ ]]; then
      return 0
    fi

    for token in $answer; do
      case "$token" in
        1) SELECTED_SCHEDULES[daily]=1 ;;
        2) SELECTED_SCHEDULES[weekly]=1 ;;
        3) SELECTED_SCHEDULES[monthly]=1 ;;
        *)
          warn "Неизвестный пункт: $token"
          SELECTED_SCHEDULES=()
          break
          ;;
      esac
    done
    ((${#SELECTED_SCHEDULES[@]} > 0)) && return 0
    warn "Выберите 1, 2, 3, их комбинацию, 4 или 0"
  done
}

choose_backup_root() {
  local entered_path

  read -rp "Каталог резервных копий [${DEFAULT_BACKUP_ROOT}]: " entered_path \
    || die "Ввод был прерван"
  entered_path="${entered_path:-$DEFAULT_BACKUP_ROOT}"
  [[ "$entered_path" == /* ]] || die "Укажите абсолютный путь, начинающийся с /"
  BACKUP_ROOT="$(readlink -m -- "$entered_path")"
  [[ "$BACKUP_ROOT" =~ ^/[A-Za-z0-9._/-]+$ ]] \
    || die "Путь для бэкапов может содержать только латинские буквы, цифры, /, точку, дефис и подчёркивание"
  case "$BACKUP_ROOT" in
    /|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/run|/run/*|/tmp|/tmp/*)
      die "Нельзя хранить резервные копии в $BACKUP_ROOT"
      ;;
  esac
}

write_backup_runner() {
  cat > "$BACKUP_RUNNER" <<'BACKUP_RUNNER_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly CONFIG_FILE="/etc/ochenstarik-server/backup.conf"
readonly LOCK_FILE="/run/lock/ochenstarik-server-backup.lock"
readonly MIN_FREE_RESERVE=$((512 * 1024 * 1024))

log() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

human_size() {
  numfmt --to=iec-i --suffix=B "$1"
}

protect_initial_files() {
  local file
  command -v chattr >/dev/null 2>&1 || return 0
  for file in "$BACKUP_ROOT"/initial/initial-*.tar.zst \
              "$BACKUP_ROOT"/initial/initial-*.tar.zst.sha256; do
    [[ -e "$file" ]] || continue
    chattr +i -- "$file" 2>/dev/null \
      || warn "Файловая система не поддерживает immutable для $file"
  done
}

check_free_space() {
  local root_device backup_device root_used backup_used source_used
  local available reserve estimated_required backup_total

  root_device="$(df --output=source / | awk 'NR == 2 { print $1 }')"
  backup_device="$(df --output=source "$BACKUP_ROOT" | awk 'NR == 2 { print $1 }')"
  root_used="$(df --output=used -B1 / | awk 'NR == 2 { print $1 }')"
  backup_total="$(df --output=size -B1 "$BACKUP_ROOT" | awk 'NR == 2 { print $1 }')"
  available="$(df --output=avail -B1 "$BACKUP_ROOT" | awk 'NR == 2 { print $1 }')"
  source_used="$root_used"

  if [[ "$root_device" == "$backup_device" ]]; then
    backup_used="$(du -s -B1 -- "$BACKUP_ROOT" | awk '{ print $1 }')"
    ((backup_used < source_used)) && source_used=$((source_used - backup_used))
  fi

  reserve=$((backup_total / 20))
  ((reserve >= MIN_FREE_RESERVE)) || reserve="$MIN_FREE_RESERVE"
  estimated_required=$((source_used / 2 + reserve))
  if ((available < estimated_required)); then
    die "Недостаточно свободного места: доступно $(human_size "$available"), приблизительно требуется $(human_size "$estimated_required"). Укажите другой диск в $CONFIG_FILE"
  fi
}

rotate_backups() {
  local backup_kind="$1" keep_count="$2" index filename
  local target_dir="${BACKUP_ROOT}/${backup_kind}"
  local -a archives

  mapfile -t archives < <(
    find "$target_dir" -maxdepth 1 -type f -name "${backup_kind}-*.tar.zst" \
      -printf '%f\n' | sort -r
  )
  for ((index = keep_count; index < ${#archives[@]}; index++)); do
    filename="${archives[index]}"
    rm -f -- "$target_dir/$filename" "$target_dir/${filename}.sha256"
    log "Удалён старый ${backup_kind}-архив: $filename"
  done
}

read_backup_config() {
  local line key value
  BACKUP_ROOT=""
  [[ -f "$CONFIG_FILE" && ! -L "$CONFIG_FILE" ]] \
    || die "Не найден безопасный файл настроек: $CONFIG_FILE"
  [[ "$(stat -c %u "$CONFIG_FILE")" == 0 ]] \
    || die "Файл настроек должен принадлежать root: $CONFIG_FILE"
  [[ "$(stat -c %a "$CONFIG_FILE")" =~ ^[0-7]*[0-5][0-5]$ ]] \
    || die "Файл настроек не должен быть доступен для записи группе или всем: $CONFIG_FILE"

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line//$'\r'/}"
    [[ -n "$line" && "$line" != \#* ]] || continue
    [[ "$line" == *=* ]] || die "Некорректная строка в $CONFIG_FILE: $line"
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      BACKUP_ROOT)
        [[ "$value" =~ ^/[A-Za-z0-9._/-]+$ ]] \
          || die "Некорректный BACKUP_ROOT в $CONFIG_FILE"
        BACKUP_ROOT="$value"
        ;;
      *)
        die "Неизвестный ключ в $CONFIG_FILE: $key"
        ;;
    esac
  done < "$CONFIG_FILE"
}

create_backup() {
  local backup_kind="$1" keep_count="$2" timestamp target_dir
  local archive temporary checksum checksum_temporary exclude_backup_root

  target_dir="${BACKUP_ROOT}/${backup_kind}"
  mkdir -p -m 700 -- "$target_dir"

  if [[ "$backup_kind" == initial ]] &&
     find "$target_dir" -maxdepth 1 -type f -name 'initial-*.tar.zst' -print -quit | grep -q .; then
    log "Первичный снимок уже существует и не будет перезаписан"
    protect_initial_files
    return 0
  fi

  check_free_space
  timestamp="$(date +%Y%m%d-%H%M%S)"
  archive="${target_dir}/${backup_kind}-${timestamp}.tar.zst"
  temporary="${archive}.partial"
  checksum="${archive}.sha256"
  checksum_temporary="${checksum}.partial"
  exclude_backup_root=".${BACKUP_ROOT}"
  trap 'rm -f -- "${temporary:-}" "${checksum_temporary:-}"' EXIT

  [[ ! -e "$archive" && ! -e "$temporary" ]] \
    || die "Архив с таким именем уже существует: $archive"
  log "Создаю ${backup_kind}-архив: $archive"
  tar \
    --create \
    --file=- \
    --directory=/ \
    --one-file-system \
    --acls \
    --xattrs \
    --xattrs-include='*' \
    --numeric-owner \
    --sparse \
    --ignore-failed-read \
    --warning=no-file-changed \
    --exclude='./proc' \
    --exclude='./proc/*' \
    --exclude='./sys' \
    --exclude='./sys/*' \
    --exclude='./dev' \
    --exclude='./dev/*' \
    --exclude='./run' \
    --exclude='./run/*' \
    --exclude='./tmp' \
    --exclude='./tmp/*' \
    --exclude='./var/tmp' \
    --exclude='./var/tmp/*' \
    --exclude='./mnt' \
    --exclude='./mnt/*' \
    --exclude='./media' \
    --exclude='./media/*' \
    --exclude='./lost+found' \
    --exclude='./swapfile' \
    --exclude="$exclude_backup_root" \
    --exclude="${exclude_backup_root}/*" \
    . | zstd -T0 -3 --quiet -o "$temporary"

  [[ -s "$temporary" ]] || die "Получился пустой архив"
  chmod 600 "$temporary"
  mv -- "$temporary" "$archive"
  (
    cd "$target_dir"
    sha256sum "$(basename "$archive")" > "$(basename "$checksum_temporary")"
  )
  chmod 600 "$checksum_temporary"
  mv -- "$checksum_temporary" "$checksum"
  trap - EXIT

  if [[ "$backup_kind" == initial ]]; then
    protect_initial_files
  else
    rotate_backups "$backup_kind" "$keep_count"
  fi
  log "Готово: $archive ($(human_size "$(stat -c %s "$archive")"))"
}

[[ "$EUID" -eq 0 ]] || die "Запустите команду от имени root"
read_backup_config
[[ "${BACKUP_ROOT:-}" == /* && "$BACKUP_ROOT" != / ]] \
  || die "Некорректный BACKUP_ROOT в $CONFIG_FILE"
mkdir -p -m 700 -- "$BACKUP_ROOT"/{initial,daily,weekly,monthly}

exec 9>"$LOCK_FILE"
flock -n 9 || die "Другое резервное копирование уже выполняется"

case "${1:-}" in
  initial) create_backup initial 0 ;;
  daily) create_backup daily 7 ;;
  weekly) create_backup weekly 4 ;;
  monthly) create_backup monthly 12 ;;
  *) die "Использование: $0 {initial|daily|weekly|monthly}" ;;
esac
BACKUP_RUNNER_EOF
  chmod 700 "$BACKUP_RUNNER"
}

write_systemd_units() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Ochenstarik server backup (%i)
After=local-fs.target

[Service]
Type=oneshot
ExecStart=${BACKUP_RUNNER} %i
Nice=10
IOSchedulingClass=idle
UMask=0077
TimeoutStartSec=infinity
EOF

  cat > "${TIMER_PREFIX}-daily.timer" <<'EOF'
[Unit]
Description=Daily Ochenstarik server backup

[Timer]
OnCalendar=*-*-* 03:15:00
Persistent=true
RandomizedDelaySec=10m
Unit=ochenstarik-backup@daily.service

[Install]
WantedBy=timers.target
EOF

  cat > "${TIMER_PREFIX}-weekly.timer" <<'EOF'
[Unit]
Description=Weekly Ochenstarik server backup

[Timer]
OnCalendar=Sun *-*-* 04:15:00
Persistent=true
RandomizedDelaySec=10m
Unit=ochenstarik-backup@weekly.service

[Install]
WantedBy=timers.target
EOF

  cat > "${TIMER_PREFIX}-monthly.timer" <<'EOF'
[Unit]
Description=Monthly Ochenstarik server backup

[Timer]
OnCalendar=*-*-01 05:15:00
Persistent=true
RandomizedDelaySec=10m
Unit=ochenstarik-backup@monthly.service

[Install]
WantedBy=timers.target
EOF
  chmod 644 "$SERVICE_FILE" "${TIMER_PREFIX}-daily.timer" \
    "${TIMER_PREFIX}-weekly.timer" "${TIMER_PREFIX}-monthly.timer"
}

apply_schedule_selection() {
  local schedule timer

  systemctl daemon-reload
  for schedule in daily weekly monthly; do
    timer="ochenstarik-backup-${schedule}.timer"
    if [[ -n "${SELECTED_SCHEDULES[$schedule]:-}" ]]; then
      systemctl enable --now "$timer"
    else
      systemctl disable --now "$timer" >/dev/null 2>&1 || true
    fi
  done
}

print_summary() {
  local schedule

  printf '\nНастройка резервного копирования завершена.\n'
  printf 'Каталог: %s\n' "$BACKUP_ROOT"
  printf 'Первичный снимок: создан один раз, автоматическая ротация отключена.\n'
  printf 'Активные расписания:'
  if ((${#SELECTED_SCHEDULES[@]} == 0)); then
    printf ' нет\n'
  else
    for schedule in daily weekly monthly; do
      [[ -n "${SELECTED_SCHEDULES[$schedule]:-}" ]] && printf ' %s' "$schedule"
    done
    printf '\n'
  fi
  printf '\nПроверка таймеров:\n  systemctl list-timers "ochenstarik-backup-*"\n'
  printf 'Ручной запуск:\n  sudo %s daily\n' "$BACKUP_RUNNER"
  printf 'Проверка архива:\n  cd %s/initial && sha256sum -c ./*.sha256\n' "$BACKUP_ROOT"
  printf '\nХраните дополнительную копию на другом сервере или диске.\n'
}

[[ "$EUID" -eq 0 ]] || die "Запустите этот скрипт от имени root"
for command_name in apt-get cat chmod install readlink systemctl; do
  require_command "$command_name"
done

choose_schedules
choose_backup_root

export DEBIAN_FRONTEND=noninteractive
log "Устанавливаю зависимости"
apt-get update
apt-get install -y coreutils e2fsprogs findutils tar util-linux zstd
for command_name in awk basename chattr df du find flock grep numfmt sha256sum sort stat tar zstd; do
  require_command "$command_name"
done

install -d -o root -g root -m 700 "$CONFIG_DIR" "$BACKUP_ROOT"
[[ ! -L "$CONFIG_FILE" ]] || die "Отказ от записи через символическую ссылку: $CONFIG_FILE"
printf 'BACKUP_ROOT=%s\n' "$BACKUP_ROOT" > "$CONFIG_FILE"
chown root:root "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

write_backup_runner
write_systemd_units

log "Создаю первичный снимок (при повторном запуске существующий не изменяется)"
"$BACKUP_RUNNER" initial
apply_schedule_selection
print_summary
