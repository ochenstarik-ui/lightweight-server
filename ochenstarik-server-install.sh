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
  "Timezone, terminal language, programs, and swap"
  "Base packages, SSH port, IPv4/IPv6, and UFW"
  "Administrator, SSH migration, and fail2ban"
  "Telegram notifications for SSH logins"
  "System VPN through Xray"
  "3x-ui panel and Cloudflare WARP"
  "Initial snapshot and backup schedules"
)

TEMP_FILE=""
UI_LANG=en
declare -A MASTER_TEXT=()

load_master_text() {
  MASTER_TEXT=(
    [intro_title]="Unified lightweight-server installer"
    [intro_body]="Steps are shown in order. Each step can be installed, skipped, or used to exit the installer. Keep the current SSH session open while changing the SSH port and test the new login in another terminal."
    [step]="Step %s of %s: %s"
    [install]="Install / run this step"
    [skip]="Skip and continue to the next step"
    [finish]="Exit the installer"
    [action]="Select an action: "
    [invalid]="Enter 1, 2, or 3"
    [interrupted]="Input was interrupted"
    [failed]="The step failed."
    [retry]="Run this step again"
    [summary]="Installer completed."
    [completed]="Steps completed successfully: %s"
    [skipped]="Steps skipped: %s"
    [rerun]="You can run the installer again; every step supports reconfiguration."
    [reset]="For a complete reset, use ochenstarik-server-uninstall.sh."
    [launch]="Running step %s: %s"
    [success]="Step %s completed successfully"
    [error]="Step %s returned an error"
  )

  case "$UI_LANG" in
    ru) MASTER_TEXT+=(
      [intro_title]="Единый мастер установки lightweight-server"
      [intro_body]="Этапы будут показаны по порядку. Каждый можно установить, пропустить или завершить мастер. Не закрывайте текущую SSH-сессию при изменении порта и проверьте новый вход во втором терминале."
      [step]="Этап %s из %s: %s" [install]="Установить / запустить этот этап"
      [skip]="Пропустить и перейти к следующему" [finish]="Завершить мастер"
      [action]="Выберите действие: " [invalid]="Введите 1, 2 или 3" [interrupted]="Ввод прерван"
      [failed]="Этап завершился с ошибкой." [retry]="Запустить этот этап повторно"
      [summary]="Мастер установки завершён." [completed]="Успешно выполнено этапов: %s"
      [skipped]="Пропущено этапов: %s"
      [rerun]="Мастер можно запустить повторно: каждый этап поддерживает повторную настройку."
      [reset]="Для полного сброса используйте ochenstarik-server-uninstall.sh."
      [launch]="Запуск этапа %s: %s" [success]="Этап %s успешно завершён" [error]="Этап %s вернул ошибку"
    ) ;;
    es) MASTER_TEXT+=(
      [intro_title]="Instalador unificado de lightweight-server"
      [intro_body]="Los pasos se muestran en orden. Puede instalar, omitir o salir en cada paso. Mantenga abierta la sesión SSH actual al cambiar el puerto y pruebe el nuevo acceso en otro terminal."
      [step]="Paso %s de %s: %s" [install]="Instalar / ejecutar este paso" [skip]="Omitir y continuar"
      [finish]="Salir del instalador" [action]="Seleccione una acción: " [invalid]="Introduzca 1, 2 o 3"
      [interrupted]="Entrada interrumpida" [failed]="El paso terminó con un error." [retry]="Ejecutar este paso de nuevo"
      [summary]="Instalación finalizada." [completed]="Pasos completados: %s" [skipped]="Pasos omitidos: %s"
      [rerun]="Puede ejecutar de nuevo el instalador; cada paso admite reconfiguración."
      [reset]="Para un reinicio completo, use ochenstarik-server-uninstall.sh."
      [launch]="Ejecutando el paso %s: %s" [success]="Paso %s completado" [error]="El paso %s devolvió un error"
    ) ;;
    de) MASTER_TEXT+=(
      [intro_title]="Einheitlicher lightweight-server-Installer"
      [intro_body]="Die Schritte werden nacheinander angezeigt. Jeder Schritt kann installiert, übersprungen oder zum Beenden verwendet werden. Lassen Sie beim Ändern des SSH-Ports die aktuelle Sitzung geöffnet und testen Sie die neue Anmeldung in einem zweiten Terminal."
      [step]="Schritt %s von %s: %s" [install]="Diesen Schritt installieren / ausführen" [skip]="Überspringen und fortfahren"
      [finish]="Installer beenden" [action]="Aktion auswählen: " [invalid]="Geben Sie 1, 2 oder 3 ein"
      [interrupted]="Eingabe unterbrochen" [failed]="Der Schritt ist fehlgeschlagen." [retry]="Diesen Schritt erneut ausführen"
      [summary]="Installation abgeschlossen." [completed]="Erfolgreiche Schritte: %s" [skipped]="Übersprungene Schritte: %s"
      [rerun]="Der Installer kann erneut ausgeführt werden; jeder Schritt unterstützt eine Neukonfiguration."
      [reset]="Für ein vollständiges Zurücksetzen verwenden Sie ochenstarik-server-uninstall.sh."
      [launch]="Schritt %s wird ausgeführt: %s" [success]="Schritt %s erfolgreich abgeschlossen" [error]="Schritt %s meldete einen Fehler"
    ) ;;
    fr) MASTER_TEXT+=(
      [intro_title]="Programme d’installation unifié lightweight-server"
      [intro_body]="Les étapes sont présentées dans l’ordre. Chacune peut être installée, ignorée ou utilisée pour quitter. Gardez la session SSH actuelle ouverte pendant le changement de port et testez la nouvelle connexion dans un autre terminal."
      [step]="Étape %s sur %s : %s" [install]="Installer / exécuter cette étape" [skip]="Ignorer et continuer"
      [finish]="Quitter l’installation" [action]="Sélectionnez une action : " [invalid]="Saisissez 1, 2 ou 3"
      [interrupted]="Saisie interrompue" [failed]="L’étape a échoué." [retry]="Relancer cette étape"
      [summary]="Installation terminée." [completed]="Étapes réussies : %s" [skipped]="Étapes ignorées : %s"
      [rerun]="Vous pouvez relancer l’installation ; chaque étape accepte une reconfiguration."
      [reset]="Pour une réinitialisation complète, utilisez ochenstarik-server-uninstall.sh."
      [launch]="Exécution de l’étape %s : %s" [success]="Étape %s réussie" [error]="L’étape %s a renvoyé une erreur"
    ) ;;
    pt) MASTER_TEXT+=(
      [intro_title]="Instalador unificado do lightweight-server"
      [intro_body]="As etapas são mostradas em ordem. Cada etapa pode ser instalada, ignorada ou usada para sair. Mantenha a sessão SSH atual aberta ao alterar a porta e teste o novo acesso em outro terminal."
      [step]="Etapa %s de %s: %s" [install]="Instalar / executar esta etapa" [skip]="Ignorar e continuar"
      [finish]="Sair do instalador" [action]="Selecione uma ação: " [invalid]="Digite 1, 2 ou 3"
      [interrupted]="Entrada interrompida" [failed]="A etapa falhou." [retry]="Executar esta etapa novamente"
      [summary]="Instalação concluída." [completed]="Etapas concluídas: %s" [skipped]="Etapas ignoradas: %s"
      [rerun]="O instalador pode ser executado novamente; todas as etapas aceitam reconfiguração."
      [reset]="Para redefinir tudo, use ochenstarik-server-uninstall.sh."
      [launch]="Executando a etapa %s: %s" [success]="Etapa %s concluída" [error]="A etapa %s retornou um erro"
    ) ;;
    zh) MASTER_TEXT+=(
      [intro_title]="lightweight-server 统一安装程序" [intro_body]="各步骤按顺序显示。每一步都可以安装、跳过或退出。更改 SSH 端口时请保持当前会话，并在另一个终端测试新连接。"
      [step]="第 %s/%s 步：%s" [install]="安装 / 运行此步骤" [skip]="跳过并继续" [finish]="退出安装程序"
      [action]="请选择操作：" [invalid]="请输入 1、2 或 3" [interrupted]="输入已中断"
      [failed]="此步骤执行失败。" [retry]="重新运行此步骤" [summary]="安装程序已完成。"
      [completed]="成功完成的步骤：%s" [skipped]="跳过的步骤：%s" [rerun]="可以再次运行安装程序；每个步骤都支持重新配置。"
      [reset]="如需完全重置，请使用 ochenstarik-server-uninstall.sh。" [launch]="正在运行步骤 %s：%s"
      [success]="步骤 %s 已成功完成" [error]="步骤 %s 返回错误"
    ) ;;
    ja) MASTER_TEXT+=(
      [intro_title]="lightweight-server 統合インストーラー" [intro_body]="手順は順番に表示されます。各手順は実行、スキップ、または終了できます。SSH ポートの変更中は現在のセッションを維持し、別のターミナルで新しい接続を確認してください。"
      [step]="ステップ %s/%s: %s" [install]="このステップをインストール / 実行" [skip]="スキップして次へ"
      [finish]="インストーラーを終了" [action]="操作を選択してください: " [invalid]="1、2、3 のいずれかを入力してください"
      [interrupted]="入力が中断されました" [failed]="ステップが失敗しました。" [retry]="このステップを再実行"
      [summary]="インストールが完了しました。" [completed]="成功したステップ: %s" [skipped]="スキップしたステップ: %s"
      [rerun]="インストーラーは再実行でき、各ステップを再設定できます。" [reset]="完全にリセットするには ochenstarik-server-uninstall.sh を使用してください。"
      [launch]="ステップ %s を実行中: %s" [success]="ステップ %s が完了しました" [error]="ステップ %s でエラーが発生しました"
    ) ;;
    ar) MASTER_TEXT+=(
      [intro_title]="مثبت lightweight-server الموحد" [intro_body]="تظهر المراحل بالترتيب. يمكن تثبيت كل مرحلة أو تخطيها أو الخروج. أبقِ جلسة SSH الحالية مفتوحة عند تغيير المنفذ واختبر الاتصال الجديد في طرفية أخرى."
      [step]="المرحلة %s من %s: %s" [install]="تثبيت / تشغيل هذه المرحلة" [skip]="تخطي والمتابعة"
      [finish]="إنهاء المثبت" [action]="اختر إجراءً: " [invalid]="أدخل 1 أو 2 أو 3" [interrupted]="تم إيقاف الإدخال"
      [failed]="فشلت المرحلة." [retry]="تشغيل هذه المرحلة مرة أخرى" [summary]="اكتمل المثبت."
      [completed]="المراحل المكتملة: %s" [skipped]="المراحل المتخطاة: %s" [rerun]="يمكن تشغيل المثبت مرة أخرى؛ كل مرحلة تدعم إعادة الإعداد."
      [reset]="لإعادة الضبط الكامل استخدم ochenstarik-server-uninstall.sh." [launch]="تشغيل المرحلة %s: %s"
      [success]="اكتملت المرحلة %s" [error]="أعادت المرحلة %s خطأ"
    ) ;;
    hi) MASTER_TEXT+=(
      [intro_title]="एकीकृत lightweight-server इंस्टॉलर" [intro_body]="चरण क्रम से दिखाए जाते हैं। प्रत्येक चरण को चलाया, छोड़ा या इंस्टॉलर बंद किया जा सकता है। SSH पोर्ट बदलते समय वर्तमान सत्र खुला रखें और दूसरे टर्मिनल में नया लॉगिन जाँचें।"
      [step]="चरण %s/%s: %s" [install]="यह चरण इंस्टॉल / चलाएँ" [skip]="छोड़ें और आगे बढ़ें"
      [finish]="इंस्टॉलर बंद करें" [action]="कार्रवाई चुनें: " [invalid]="1, 2 या 3 दर्ज करें" [interrupted]="इनपुट बाधित हुआ"
      [failed]="चरण विफल हुआ।" [retry]="यह चरण फिर चलाएँ" [summary]="इंस्टॉलर पूरा हुआ।"
      [completed]="सफल चरण: %s" [skipped]="छोड़े गए चरण: %s" [rerun]="इंस्टॉलर फिर चलाया जा सकता है; हर चरण पुनः कॉन्फ़िगर हो सकता है।"
      [reset]="पूर्ण रीसेट के लिए ochenstarik-server-uninstall.sh का उपयोग करें।" [launch]="चरण %s चल रहा है: %s"
      [success]="चरण %s सफल रहा" [error]="चरण %s में त्रुटि हुई"
    ) ;;
  esac
}

master_msg() {
  local key="$1"
  shift
  printf "${MASTER_TEXT[$key]}" "$@"
}

localize_step_titles() {
  case "$UI_LANG" in
    ru) STEP_TITLES=("Часовой пояс, язык терминала, программы и swap" "Базовые пакеты, SSH-порт, IPv4/IPv6 и UFW" "Администратор, перенос SSH и fail2ban" "Telegram-уведомления о входах по SSH" "Системный VPN через Xray" "Панель 3x-ui и Cloudflare WARP" "Первичный снимок и расписания бэкапов") ;;
    es) STEP_TITLES=("Zona horaria, idioma del terminal, programas y swap" "Paquetes base, puerto SSH, IPv4/IPv6 y UFW" "Administrador, migración SSH y fail2ban" "Notificaciones de Telegram para accesos SSH" "VPN del sistema mediante Xray" "Panel 3x-ui y Cloudflare WARP" "Instantánea inicial y copias programadas") ;;
    de) STEP_TITLES=("Zeitzone, Terminalsprache, Programme und Swap" "Basispakete, SSH-Port, IPv4/IPv6 und UFW" "Administrator, SSH-Umstellung und fail2ban" "Telegram-Benachrichtigungen für SSH-Anmeldungen" "System-VPN über Xray" "3x-ui und Cloudflare WARP" "Erstsicherung und Sicherungspläne") ;;
    fr) STEP_TITLES=("Fuseau horaire, langue du terminal, programmes et swap" "Paquets de base, port SSH, IPv4/IPv6 et UFW" "Administrateur, migration SSH et fail2ban" "Notifications Telegram des connexions SSH" "VPN système via Xray" "Panneau 3x-ui et Cloudflare WARP" "Instantané initial et sauvegardes planifiées") ;;
    pt) STEP_TITLES=("Fuso horário, idioma do terminal, programas e swap" "Pacotes básicos, porta SSH, IPv4/IPv6 e UFW" "Administrador, migração SSH e fail2ban" "Notificações Telegram de logins SSH" "VPN do sistema via Xray" "Painel 3x-ui e Cloudflare WARP" "Snapshot inicial e backups agendados") ;;
    zh) STEP_TITLES=("时区、终端语言、程序和交换文件" "基础软件包、SSH 端口、IPv4/IPv6 和 UFW" "管理员、SSH 迁移和 fail2ban" "SSH 登录的 Telegram 通知" "通过 Xray 的系统 VPN" "3x-ui 面板和 Cloudflare WARP" "初始快照和备份计划") ;;
    ja) STEP_TITLES=("タイムゾーン、端末言語、プログラム、スワップ" "基本パッケージ、SSH ポート、IPv4/IPv6、UFW" "管理者、SSH 移行、fail2ban" "SSH ログインの Telegram 通知" "Xray によるシステム VPN" "3x-ui パネルと Cloudflare WARP" "初回スナップショットとバックアップ予定") ;;
    ar) STEP_TITLES=("المنطقة الزمنية ولغة الطرفية والبرامج وswap" "الحزم الأساسية ومنفذ SSH وIPv4/IPv6 وUFW" "المسؤول ونقل SSH وfail2ban" "إشعارات Telegram لدخول SSH" "VPN للنظام عبر Xray" "لوحة 3x-ui وCloudflare WARP" "النسخة الأولية وجداول النسخ الاحتياطي") ;;
    hi) STEP_TITLES=("समय क्षेत्र, टर्मिनल भाषा, प्रोग्राम और swap" "मूल पैकेज, SSH पोर्ट, IPv4/IPv6 और UFW" "प्रशासक, SSH स्थानांतरण और fail2ban" "SSH लॉगिन की Telegram सूचनाएँ" "Xray द्वारा सिस्टम VPN" "3x-ui पैनल और Cloudflare WARP" "प्रारंभिक स्नैपशॉट और बैकअप अनुसूचियाँ") ;;
  esac
}

choose_dialog_language() {
  local answer
  printf '\nSelect the installer language / Выберите язык установщика:\n'
  printf '%s\n' '  1) English' '  2) Русский' '  3) Español' '  4) Deutsch' \
    '  5) Français' '  6) Português' '  7) 中文' '  8) 日本語' '  9) العربية' '  10) हिन्दी'
  while :; do
    read -rp 'Language [1 — English]: ' answer || die "Input was interrupted"
    answer="${answer:-1}"
    case "$answer" in
      1) UI_LANG=en ;; 2) UI_LANG=ru ;; 3) UI_LANG=es ;; 4) UI_LANG=de ;; 5) UI_LANG=fr ;;
      6) UI_LANG=pt ;; 7) UI_LANG=zh ;; 8) UI_LANG=ja ;; 9) UI_LANG=ar ;; 10) UI_LANG=hi ;;
      *) warn "Enter a number from 1 to 10"; continue ;;
    esac
    break
  done
  export OCHENSTARIK_UI_LANG="$UI_LANG"
  load_master_text
  localize_step_titles
}

load_master_text

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
    printf '%s\n' "$(master_msg step "$step_number" "${#STEP_FILES[@]}" "$title")"
    printf '  1) %s\n' "$(master_msg install)"
    printf '  2) %s\n' "$(master_msg skip)"
    printf '  3) %s\n' "$(master_msg finish)"
    read -rp "$(master_msg action)" answer || die "$(master_msg interrupted)"
    case "$answer" in
      1|2|3) printf -v "$result_variable" '%s' "$answer"; return 0 ;;
      *) warn "$(master_msg invalid)" ;;
    esac
  done
}

choose_after_failure() {
  local result_variable="$1" answer
  while :; do
    printf '\n%s\n' "$(master_msg failed)"
    printf '  1) %s\n' "$(master_msg retry)"
    printf '  2) %s\n' "$(master_msg skip)"
    printf '  3) %s\n' "$(master_msg finish)"
    read -rp "$(master_msg action)" answer || die "$(master_msg interrupted)"
    case "$answer" in
      1|2|3) printf -v "$result_variable" '%s' "$answer"; return 0 ;;
      *) warn "$(master_msg invalid)" ;;
    esac
  done
}

print_summary() {
  local completed="$1" skipped="$2"
  printf '\n============================================================\n'
  printf '%s\n' "$(master_msg summary)"
  printf '%s\n' "$(master_msg completed "$completed")"
  printf '%s\n' "$(master_msg skipped "$skipped")"
  printf '\n%s\n' "$(master_msg rerun)"
  printf '%s\n' "$(master_msg reset)"
}

[[ "$EUID" -eq 0 ]] || die "Запустите мастер от имени root: sudo ./ochenstarik-server-install.sh"
((${#STEP_FILES[@]} == ${#STEP_TITLES[@]})) || die "Некорректное описание этапов"

choose_dialog_language

printf '\n%s\n\n%s\n' "$(master_msg intro_title)" "$(master_msg intro_body)"

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
    log "$(master_msg launch "$step_number" "${STEP_TITLES[index]}")"
    if bash -- "$script_path"; then
      completed="$((completed + 1))"
      log "$(master_msg success "$step_number")"
      break
    fi

    warn "$(master_msg error "$step_number")"
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
