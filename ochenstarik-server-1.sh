#!/usr/bin/env bash
set -Eeuo pipefail

readonly SWAPFILE="/swapfile"
readonly SWAPSIZE="2G"
readonly SWAPPINESS="20"
readonly SYSCTL_FILE="/etc/sysctl.d/60-hermes-swap.conf"
readonly CONFIG_DIR="/etc/ochenstarik-server"
readonly LOCALE_BACKUP="${CONFIG_DIR}/locale-before-selection.conf"
readonly LOCALE_ABSENT_MARKER="${CONFIG_DIR}/locale-before-selection.absent"
readonly LOCALE_PACKAGES="${CONFIG_DIR}/locale-installed-packages.list"
readonly LEGACY_LOCALE_BACKUP="${CONFIG_DIR}/locale-before-russian.conf"
readonly LEGACY_LOCALE_ABSENT_MARKER="${CONFIG_DIR}/locale-before-russian.absent"
readonly LEGACY_LOCALE_PACKAGES="${CONFIG_DIR}/russian-locale-installed-packages.list"
readonly PROGRAM_PACKAGES="${CONFIG_DIR}/step1-installed-packages.list"

declare -a PROGRAM_GROUP_TITLES=(
  "Terminal and everyday tools"
  "Network diagnostics"
  "System and disk monitoring"
  "Ubuntu security and maintenance"
  "Development and automation"
  "Archives, tables, and local data"
  "Documents, PDF, and OCR"
  "Images, audio, and video"
  "Backup and synchronization"
)

declare -a PROGRAM_GROUP_DESCRIPTIONS=(
  "git, wget, curl, jq/yq, ripgrep/fd/fzf, lnav, editors, mc, tmux, htop/btop, ncdu, rsync"
  "DNS/ping/MTR/traceroute, tcpdump, nmap, netcat, HTTPie, whois, ethtool, socat"
  "iotop, sysstat, SMART, sensors, atop, nethogs, vnStat, process tools"
  "auditd, AppArmor tools, Lynis, needrestart, automatic updates, debsums, ACL/xattr"
  "compiler, ShellCheck, Python pip/venv, pipx"
  "7-Zip/ZIP/RAR, SQLite, csvkit, PostgreSQL and Redis clients"
  "Poppler, qpdf, Ghostscript, OCRmyPDF/Tesseract, LibreOffice, Pandoc, antiword/catdoc"
  "ImageMagick, ExifTool, WebP, FFmpeg, MediaInfo"
  "restic, BorgBackup, rclone"
)

readonly -a PROGRAM_GROUP_PACKAGES=(
  "git wget curl ca-certificates jq yq ripgrep fd-find fzf lnav tree less nano vim mc tmux screen htop btop ncdu lsof strace rsync"
  "dnsutils iputils-ping mtr-tiny traceroute tcpdump nmap netcat-openbsd httpie whois ethtool socat"
  "iotop sysstat smartmontools lm-sensors atop nethogs vnstat psmisc"
  "auditd apparmor-utils lynis needrestart unattended-upgrades debsums acl attr"
  "build-essential shellcheck python3-pip python3-venv pipx"
  "p7zip-full unzip zip unrar sqlite3 csvkit postgresql-client redis-tools"
  "poppler-utils qpdf ghostscript ocrmypdf tesseract-ocr tesseract-ocr-eng tesseract-ocr-rus libreoffice pandoc antiword catdoc"
  "imagemagick libimage-exiftool-perl webp ffmpeg mediainfo"
  "restic borgbackup rclone"
)

APT_UPDATED=no
UI_LANG=en

declare -A UI_TEXT=()

load_ui_text() {
  UI_TEXT=(
    [input_interrupted]="Input was interrupted"
    [invalid_number]="Enter a number from %s to %s"
    [no_options]="No options are available for: %s"
    [select_option]="Enter the option number: "
    [select_region]="Select a region:"
    [select_timezone]="Select a timezone in %s:"
    [timezone_heading]="Select the server timezone (current: %s):"
    [other_timezone]="Other timezone (select by region)"
    [unknown_timezone]="Unknown timezone: %s"
    [timezone_set]="Timezone set to %s"
    [terminal_heading]="Select the language for new terminal sessions (current: %s):"
    [terminal_keep]="Keep the current terminal language"
    [terminal_other]="Other locale from the full list"
    [terminal_prompt]="Language number [1 — keep current]: "
    [terminal_unchanged]="Terminal language was not changed"
    [terminal_full_list]="Select a locale from the full list:"
    [locale_package_missing]="Language package is unavailable and will be skipped: %s"
    [locale_selected]="Locale %s selected. It will apply at the next login"
    [program_heading]="Select program groups to install:"
    [program_none]="Do not install additional programs"
    [program_example]="Enter numbers separated by spaces, for example: 1 2 4 9."
    [program_prompt]="Selection [Enter — install all groups]: "
    [program_skipped]="Installation of additional programs was skipped"
    [program_bad_number]="Invalid group number: %s"
    [program_out_of_range]="Group number is out of range: %s"
    [program_selected]="Selected group: %s"
    [package_missing]="Package is unavailable in the configured repositories and will be skipped: %s"
    [no_packages]="None of the selected packages were found"
    [programs_installed]="Selected programs have been installed"
    [apt_update]="Updating the package list"
    [root_required]="Run this script as root"
    [required_missing]="Required command not found: %s"
    [swap_configuring]="Configuring %s swap file"
    [setup_complete]="Server memory setup is complete"
    [next_script]="Now run ochenstarik-server-2.sh as root."
  )

  case "$UI_LANG" in
    ru) UI_TEXT+=(
      [input_interrupted]="Ввод прерван" [invalid_number]="Введите номер от %s до %s"
      [select_option]="Введите номер варианта: " [select_region]="Выберите регион:"
      [select_timezone]="Выберите часовой пояс в регионе %s:"
      [timezone_heading]="Выберите часовой пояс сервера (сейчас: %s):"
      [other_timezone]="Другой часовой пояс (выбор по региону)"
      [unknown_timezone]="Неизвестный часовой пояс: %s" [timezone_set]="Установлен часовой пояс %s"
      [terminal_heading]="Выберите язык новых терминальных сессий (сейчас: %s):"
      [terminal_keep]="Не менять язык терминала" [terminal_other]="Другая локаль из полного списка"
      [terminal_prompt]="Номер языка [1 — не менять]: " [terminal_unchanged]="Язык терминала не изменён"
      [terminal_full_list]="Выберите локаль из полного списка:"
      [locale_package_missing]="Языковой пакет недоступен и будет пропущен: %s"
      [locale_selected]="Выбрана локаль %s. Она применится при следующем входе"
      [program_heading]="Выберите наборы программ для установки:"
      [program_none]="Не устанавливать дополнительные программы"
      [program_example]="Введите номера через пробел, например: 1 2 4 9."
      [program_prompt]="Выбор [Enter — установить все наборы]: "
      [program_skipped]="Установка дополнительных программ пропущена"
      [program_bad_number]="Некорректный номер набора: %s"
      [program_out_of_range]="Номер набора вне диапазона: %s"
      [program_selected]="Выбран набор: %s"
      [package_missing]="Пакет отсутствует в подключённых репозиториях и будет пропущен: %s"
      [no_packages]="Ни один выбранный пакет не найден"
      [programs_installed]="Выбранные программы установлены" [apt_update]="Обновление списка пакетов"
      [root_required]="Запустите этот скрипт от root"
      [required_missing]="Не найдена обязательная команда: %s"
      [swap_configuring]="Настройка файла подкачки размером %s"
      [setup_complete]="Настройка памяти сервера завершена"
      [next_script]="Теперь запустите ochenstarik-server-2.sh от root."
    ) ;;
    es) UI_TEXT+=(
      [input_interrupted]="Entrada interrumpida" [invalid_number]="Introduzca un número del %s al %s"
      [select_option]="Introduzca el número de opción: " [select_region]="Seleccione una región:"
      [select_timezone]="Seleccione una zona horaria en %s:"
      [timezone_heading]="Seleccione la zona horaria del servidor (actual: %s):"
      [other_timezone]="Otra zona horaria (seleccionar por región)" [timezone_set]="Zona horaria configurada: %s"
      [terminal_heading]="Seleccione el idioma para nuevas sesiones de terminal (actual: %s):"
      [terminal_keep]="Mantener el idioma actual" [terminal_other]="Otra configuración regional de la lista completa"
      [terminal_prompt]="Número de idioma [1 — mantener]: " [terminal_unchanged]="El idioma del terminal no se cambió"
      [terminal_full_list]="Seleccione una configuración regional de la lista completa:"
      [program_heading]="Seleccione los grupos de programas que desea instalar:"
      [program_none]="No instalar programas adicionales"
      [program_example]="Introduzca números separados por espacios, por ejemplo: 1 2 4 9."
      [program_prompt]="Selección [Enter — instalar todos]: " [program_skipped]="Se omitió la instalación de programas adicionales"
      [program_bad_number]="Número de grupo no válido: %s" [program_out_of_range]="Número de grupo fuera de rango: %s"
      [program_selected]="Grupo seleccionado: %s" [programs_installed]="Los programas seleccionados se instalaron"
      [apt_update]="Actualizando la lista de paquetes" [root_required]="Ejecute este script como root"
      [swap_configuring]="Configurando un archivo swap de %s" [setup_complete]="Configuración de memoria completada"
      [next_script]="Ahora ejecute ochenstarik-server-2.sh como root."
    ) ;;
    de) UI_TEXT+=(
      [input_interrupted]="Eingabe wurde unterbrochen" [invalid_number]="Geben Sie eine Zahl von %s bis %s ein"
      [select_option]="Optionsnummer eingeben: " [select_region]="Region auswählen:"
      [select_timezone]="Zeitzone in %s auswählen:"
      [timezone_heading]="Server-Zeitzone auswählen (aktuell: %s):"
      [other_timezone]="Andere Zeitzone (nach Region auswählen)" [timezone_set]="Zeitzone auf %s gesetzt"
      [terminal_heading]="Sprache für neue Terminalsitzungen auswählen (aktuell: %s):"
      [terminal_keep]="Aktuelle Terminalsprache beibehalten" [terminal_other]="Andere Locale aus der vollständigen Liste"
      [terminal_prompt]="Sprachnummer [1 — beibehalten]: " [terminal_unchanged]="Terminalsprache wurde nicht geändert"
      [terminal_full_list]="Locale aus der vollständigen Liste auswählen:"
      [program_heading]="Zu installierende Programmgruppen auswählen:"
      [program_none]="Keine zusätzlichen Programme installieren"
      [program_example]="Nummern durch Leerzeichen getrennt eingeben, zum Beispiel: 1 2 4 9."
      [program_prompt]="Auswahl [Enter — alle installieren]: " [program_skipped]="Installation zusätzlicher Programme übersprungen"
      [program_bad_number]="Ungültige Gruppennummer: %s" [program_out_of_range]="Gruppennummer außerhalb des Bereichs: %s"
      [program_selected]="Ausgewählte Gruppe: %s" [programs_installed]="Ausgewählte Programme wurden installiert"
      [apt_update]="Paketliste wird aktualisiert" [root_required]="Führen Sie dieses Skript als root aus"
      [swap_configuring]="%s-Swap-Datei wird eingerichtet" [setup_complete]="Speichereinrichtung abgeschlossen"
      [next_script]="Führen Sie jetzt ochenstarik-server-2.sh als root aus."
    ) ;;
    fr) UI_TEXT+=(
      [input_interrupted]="Saisie interrompue" [invalid_number]="Saisissez un nombre de %s à %s"
      [select_option]="Saisissez le numéro de l’option : " [select_region]="Sélectionnez une région :"
      [select_timezone]="Sélectionnez un fuseau horaire dans %s :"
      [timezone_heading]="Sélectionnez le fuseau horaire du serveur (actuel : %s) :"
      [other_timezone]="Autre fuseau horaire (sélection par région)" [timezone_set]="Fuseau horaire défini sur %s"
      [terminal_heading]="Sélectionnez la langue des nouvelles sessions (actuelle : %s) :"
      [terminal_keep]="Conserver la langue actuelle" [terminal_other]="Autre locale de la liste complète"
      [terminal_prompt]="Numéro de langue [1 — conserver] : " [terminal_unchanged]="La langue du terminal n’a pas été modifiée"
      [terminal_full_list]="Sélectionnez une locale dans la liste complète :"
      [program_heading]="Sélectionnez les groupes de programmes à installer :"
      [program_none]="Ne pas installer de programmes supplémentaires"
      [program_example]="Saisissez les numéros séparés par des espaces, par exemple : 1 2 4 9."
      [program_prompt]="Sélection [Entrée — tout installer] : " [program_skipped]="Installation des programmes supplémentaires ignorée"
      [program_bad_number]="Numéro de groupe incorrect : %s" [program_out_of_range]="Numéro de groupe hors plage : %s"
      [program_selected]="Groupe sélectionné : %s" [programs_installed]="Les programmes sélectionnés ont été installés"
      [apt_update]="Mise à jour de la liste des paquets" [root_required]="Exécutez ce script en tant que root"
      [swap_configuring]="Configuration d’un fichier swap de %s" [setup_complete]="Configuration de la mémoire terminée"
      [next_script]="Exécutez maintenant ochenstarik-server-2.sh en tant que root."
    ) ;;
    pt) UI_TEXT+=(
      [input_interrupted]="Entrada interrompida" [invalid_number]="Digite um número de %s a %s"
      [select_option]="Digite o número da opção: " [select_region]="Selecione uma região:"
      [select_timezone]="Selecione um fuso horário em %s:"
      [timezone_heading]="Selecione o fuso horário do servidor (atual: %s):"
      [other_timezone]="Outro fuso horário (selecionar por região)" [timezone_set]="Fuso horário definido como %s"
      [terminal_heading]="Selecione o idioma das novas sessões de terminal (atual: %s):"
      [terminal_keep]="Manter o idioma atual" [terminal_other]="Outra localidade da lista completa"
      [terminal_prompt]="Número do idioma [1 — manter]: " [terminal_unchanged]="O idioma do terminal não foi alterado"
      [terminal_full_list]="Selecione uma localidade na lista completa:"
      [program_heading]="Selecione os grupos de programas para instalar:"
      [program_none]="Não instalar programas adicionais"
      [program_example]="Digite números separados por espaços, por exemplo: 1 2 4 9."
      [program_prompt]="Seleção [Enter — instalar todos]: " [program_skipped]="Instalação de programas adicionais ignorada"
      [program_bad_number]="Número de grupo inválido: %s" [program_out_of_range]="Número de grupo fora do intervalo: %s"
      [program_selected]="Grupo selecionado: %s" [programs_installed]="Os programas selecionados foram instalados"
      [apt_update]="Atualizando a lista de pacotes" [root_required]="Execute este script como root"
      [swap_configuring]="Configurando arquivo swap de %s" [setup_complete]="Configuração de memória concluída"
      [next_script]="Agora execute ochenstarik-server-2.sh como root."
    ) ;;
    zh) UI_TEXT+=(
      [input_interrupted]="输入已中断" [invalid_number]="请输入 %s 到 %s 之间的数字"
      [select_option]="请输入选项编号：" [select_region]="请选择地区：" [select_timezone]="请选择 %s 的时区："
      [timezone_heading]="请选择服务器时区（当前：%s）：" [other_timezone]="其他时区（按地区选择）" [timezone_set]="时区已设置为 %s"
      [terminal_heading]="请选择新终端会话的语言（当前：%s）：" [terminal_keep]="保留当前终端语言"
      [terminal_other]="从完整列表选择其他区域设置" [terminal_prompt]="语言编号 [1 — 保留当前设置]："
      [terminal_unchanged]="终端语言未更改" [terminal_full_list]="请从完整列表选择区域设置："
      [program_heading]="请选择要安装的程序组：" [program_none]="不安装其他程序"
      [program_example]="请输入用空格分隔的编号，例如：1 2 4 9。" [program_prompt]="选择 [Enter — 全部安装]："
      [program_skipped]="已跳过其他程序的安装" [program_bad_number]="无效的程序组编号：%s"
      [program_out_of_range]="程序组编号超出范围：%s" [program_selected]="已选择程序组：%s"
      [programs_installed]="已安装所选程序" [apt_update]="正在更新软件包列表" [root_required]="请以 root 身份运行此脚本"
      [swap_configuring]="正在配置 %s 交换文件" [setup_complete]="服务器内存设置完成"
      [next_script]="现在请以 root 身份运行 ochenstarik-server-2.sh。"
    ) ;;
    ja) UI_TEXT+=(
      [input_interrupted]="入力が中断されました" [invalid_number]="%s から %s の番号を入力してください"
      [select_option]="オプション番号を入力してください: " [select_region]="地域を選択してください:"
      [select_timezone]="%s のタイムゾーンを選択してください:"
      [timezone_heading]="サーバーのタイムゾーンを選択してください（現在: %s）:"
      [other_timezone]="その他のタイムゾーン（地域から選択）" [timezone_set]="タイムゾーンを %s に設定しました"
      [terminal_heading]="新しいターミナルセッションの言語を選択してください（現在: %s）:"
      [terminal_keep]="現在の言語を維持" [terminal_other]="完全なリストから別のロケールを選択"
      [terminal_prompt]="言語番号 [1 — 変更しない]: " [terminal_unchanged]="ターミナルの言語は変更されませんでした"
      [terminal_full_list]="完全なリストからロケールを選択してください:"
      [program_heading]="インストールするプログラムグループを選択してください:"
      [program_none]="追加プログラムをインストールしない"
      [program_example]="番号を空白で区切って入力してください。例: 1 2 4 9。"
      [program_prompt]="選択 [Enter — すべてインストール]: " [program_skipped]="追加プログラムのインストールをスキップしました"
      [program_bad_number]="無効なグループ番号: %s" [program_out_of_range]="グループ番号が範囲外です: %s"
      [program_selected]="選択したグループ: %s" [programs_installed]="選択したプログラムをインストールしました"
      [apt_update]="パッケージリストを更新しています" [root_required]="このスクリプトを root で実行してください"
      [swap_configuring]="%s のスワップファイルを設定しています" [setup_complete]="メモリ設定が完了しました"
      [next_script]="次に ochenstarik-server-2.sh を root で実行してください。"
    ) ;;
    ar) UI_TEXT+=(
      [input_interrupted]="تم إيقاف الإدخال" [invalid_number]="أدخل رقماً من %s إلى %s"
      [select_option]="أدخل رقم الخيار: " [select_region]="اختر المنطقة:" [select_timezone]="اختر منطقة زمنية في %s:"
      [timezone_heading]="اختر المنطقة الزمنية للخادم (الحالية: %s):" [other_timezone]="منطقة زمنية أخرى (حسب المنطقة)"
      [timezone_set]="تم ضبط المنطقة الزمنية على %s" [terminal_heading]="اختر لغة جلسات الطرفية الجديدة (الحالية: %s):"
      [terminal_keep]="الاحتفاظ باللغة الحالية" [terminal_other]="إعداد محلي آخر من القائمة الكاملة"
      [terminal_prompt]="رقم اللغة [1 — الاحتفاظ]: " [terminal_unchanged]="لم تتغير لغة الطرفية"
      [terminal_full_list]="اختر إعداداً محلياً من القائمة الكاملة:"
      [program_heading]="اختر مجموعات البرامج المراد تثبيتها:" [program_none]="عدم تثبيت برامج إضافية"
      [program_example]="أدخل الأرقام مفصولة بمسافات، مثال: 1 2 4 9." [program_prompt]="الاختيار [Enter — تثبيت الكل]: "
      [program_skipped]="تم تخطي تثبيت البرامج الإضافية" [program_bad_number]="رقم مجموعة غير صالح: %s"
      [program_out_of_range]="رقم المجموعة خارج النطاق: %s" [program_selected]="المجموعة المحددة: %s"
      [programs_installed]="تم تثبيت البرامج المحددة" [apt_update]="جارٍ تحديث قائمة الحزم"
      [root_required]="شغّل هذا البرنامج النصي بصلاحية root" [swap_configuring]="جارٍ إعداد ملف swap بحجم %s"
      [setup_complete]="اكتمل إعداد ذاكرة الخادم" [next_script]="شغّل الآن ochenstarik-server-2.sh بصلاحية root."
    ) ;;
    hi) UI_TEXT+=(
      [input_interrupted]="इनपुट बाधित हुआ" [invalid_number]="%s से %s तक की संख्या दर्ज करें"
      [select_option]="विकल्प संख्या दर्ज करें: " [select_region]="क्षेत्र चुनें:" [select_timezone]="%s में समय क्षेत्र चुनें:"
      [timezone_heading]="सर्वर का समय क्षेत्र चुनें (वर्तमान: %s):" [other_timezone]="अन्य समय क्षेत्र (क्षेत्र के अनुसार)"
      [timezone_set]="समय क्षेत्र %s पर सेट किया गया" [terminal_heading]="नई टर्मिनल सत्रों की भाषा चुनें (वर्तमान: %s):"
      [terminal_keep]="वर्तमान भाषा बनाए रखें" [terminal_other]="पूरी सूची से अन्य लोकेल"
      [terminal_prompt]="भाषा संख्या [1 — वर्तमान रखें]: " [terminal_unchanged]="टर्मिनल भाषा नहीं बदली गई"
      [terminal_full_list]="पूरी सूची से लोकेल चुनें:"
      [program_heading]="इंस्टॉल करने के लिए प्रोग्राम समूह चुनें:" [program_none]="अतिरिक्त प्रोग्राम इंस्टॉल न करें"
      [program_example]="खाली स्थान से अलग संख्याएँ दर्ज करें, उदाहरण: 1 2 4 9।" [program_prompt]="चयन [Enter — सभी इंस्टॉल करें]: "
      [program_skipped]="अतिरिक्त प्रोग्राम की स्थापना छोड़ दी गई" [program_bad_number]="अमान्य समूह संख्या: %s"
      [program_out_of_range]="समूह संख्या सीमा से बाहर है: %s" [program_selected]="चयनित समूह: %s"
      [programs_installed]="चयनित प्रोग्राम इंस्टॉल हो गए" [apt_update]="पैकेज सूची अपडेट की जा रही है"
      [root_required]="इस स्क्रिप्ट को root के रूप में चलाएँ" [swap_configuring]="%s swap फ़ाइल कॉन्फ़िगर की जा रही है"
      [setup_complete]="सर्वर मेमोरी सेटअप पूरा हुआ" [next_script]="अब ochenstarik-server-2.sh को root के रूप में चलाएँ।"
    ) ;;
  esac
}

msg() {
  local key="$1"
  shift
  printf "${UI_TEXT[$key]}" "$@"
}

localize_program_catalog() {
  case "$UI_LANG" in
    ru) PROGRAM_GROUP_TITLES=(
      "Терминал и повседневная работа" "Диагностика сети" "Мониторинг системы и дисков"
      "Безопасность и обслуживание Ubuntu" "Разработка и автоматизация"
      "Архивы, таблицы и локальные данные" "Документы, PDF и OCR"
      "Изображения, аудио и видео" "Резервное копирование и синхронизация"
    ) ;;
    es) PROGRAM_GROUP_TITLES=(
      "Terminal y herramientas cotidianas" "Diagnóstico de red" "Supervisión del sistema y discos"
      "Seguridad y mantenimiento de Ubuntu" "Desarrollo y automatización"
      "Archivos, tablas y datos locales" "Documentos, PDF y OCR"
      "Imágenes, audio y vídeo" "Copias de seguridad y sincronización"
    ) ;;
    de) PROGRAM_GROUP_TITLES=(
      "Terminal und Alltagswerkzeuge" "Netzwerkdiagnose" "System- und Datenträgerüberwachung"
      "Ubuntu-Sicherheit und Wartung" "Entwicklung und Automatisierung"
      "Archive, Tabellen und lokale Daten" "Dokumente, PDF und OCR"
      "Bilder, Audio und Video" "Sicherung und Synchronisierung"
    ) ;;
    fr) PROGRAM_GROUP_TITLES=(
      "Terminal et outils quotidiens" "Diagnostic réseau" "Surveillance du système et des disques"
      "Sécurité et maintenance d’Ubuntu" "Développement et automatisation"
      "Archives, tableaux et données locales" "Documents, PDF et OCR"
      "Images, audio et vidéo" "Sauvegarde et synchronisation"
    ) ;;
    pt) PROGRAM_GROUP_TITLES=(
      "Terminal e ferramentas diárias" "Diagnóstico de rede" "Monitoramento do sistema e discos"
      "Segurança e manutenção do Ubuntu" "Desenvolvimento e automação"
      "Arquivos, tabelas e dados locais" "Documentos, PDF e OCR"
      "Imagens, áudio e vídeo" "Backup e sincronização"
    ) ;;
    zh) PROGRAM_GROUP_TITLES=(
      "终端与日常工具" "网络诊断" "系统与磁盘监控" "Ubuntu 安全与维护" "开发与自动化"
      "压缩包、表格与本地数据" "文档、PDF 与 OCR" "图像、音频与视频" "备份与同步"
    ) ;;
    ja) PROGRAM_GROUP_TITLES=(
      "ターミナルと日常ツール" "ネットワーク診断" "システムとディスクの監視"
      "Ubuntu のセキュリティと保守" "開発と自動化" "アーカイブ、表、ローカルデータ"
      "文書、PDF、OCR" "画像、音声、動画" "バックアップと同期"
    ) ;;
    ar) PROGRAM_GROUP_TITLES=(
      "الطرفية والأدوات اليومية" "تشخيص الشبكة" "مراقبة النظام والأقراص"
      "أمان Ubuntu وصيانته" "التطوير والأتمتة" "الأرشيفات والجداول والبيانات المحلية"
      "المستندات وPDF وOCR" "الصور والصوت والفيديو" "النسخ الاحتياطي والمزامنة"
    ) ;;
    hi) PROGRAM_GROUP_TITLES=(
      "टर्मिनल और दैनिक उपकरण" "नेटवर्क निदान" "सिस्टम और डिस्क निगरानी"
      "Ubuntu सुरक्षा और रखरखाव" "विकास और स्वचालन" "अभिलेख, तालिकाएँ और स्थानीय डेटा"
      "दस्तावेज़, PDF और OCR" "चित्र, ऑडियो और वीडियो" "बैकअप और सिंक्रोनाइज़ेशन"
    ) ;;
  esac
}

choose_ui_language() {
  local answer
  printf '\nSelect the installer language / Выберите язык установщика:\n'
  printf '%s\n' \
    '  1) English' '  2) Русский' '  3) Español' '  4) Deutsch' \
    '  5) Français' '  6) Português' '  7) 中文' '  8) 日本語' \
    '  9) العربية' '  10) हिन्दी'
  while :; do
    read -rp 'Language [1 — English]: ' answer || { printf '[x] Input was interrupted\n' >&2; exit 1; }
    answer="${answer:-1}"
    case "$answer" in
      1) UI_LANG=en ;; 2) UI_LANG=ru ;; 3) UI_LANG=es ;; 4) UI_LANG=de ;;
      5) UI_LANG=fr ;; 6) UI_LANG=pt ;; 7) UI_LANG=zh ;; 8) UI_LANG=ja ;;
      9) UI_LANG=ar ;; 10) UI_LANG=hi ;;
      *) printf '[!] Enter a number from 1 to 10.\n' >&2; continue ;;
    esac
    break
  done
  load_ui_text
  localize_program_catalog
}

# English is active until the user answers the first prompt. This also keeps
# sourced helper functions usable by the automated tests.
load_ui_text

log() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

package_is_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -Fqx 'install ok installed'
}

ensure_package_tools() {
  local command_name
  for command_name in apt-get apt-cache dpkg-query; do
    command -v "$command_name" >/dev/null 2>&1 \
      || die "$(msg required_missing "$command_name")"
  done
}

ensure_apt_updated() {
  [[ "$APT_UPDATED" == no ]] || return 0
  ensure_package_tools
  log "$(msg apt_update)"
  apt-get update
  APT_UPDATED=yes
}

record_new_packages() {
  local destination="$1" package_name
  shift
  install -d -m 700 -o root -g root "$CONFIG_DIR"
  [[ ! -L "$destination" ]] || die "Отказ от записи через ссылку: $destination"
  touch "$destination"
  for package_name in "$@"; do
    grep -Fqx -- "$package_name" "$destination" \
      || printf '%s\n' "$package_name" >> "$destination"
  done
  chown root:root "$destination"
  chmod 600 "$destination"
}

migrate_legacy_locale_state() {
  local package_name
  install -d -m 700 -o root -g root "$CONFIG_DIR"
  [[ ! -L "$LOCALE_BACKUP" && ! -L "$LOCALE_ABSENT_MARKER" \
    && ! -L "$LOCALE_PACKAGES" ]] || die "Файл состояния локали не должен быть ссылкой"
  if [[ -f "$LEGACY_LOCALE_BACKUP" && ! -L "$LEGACY_LOCALE_BACKUP" \
    && ! -e "$LOCALE_BACKUP" ]]; then
    mv -- "$LEGACY_LOCALE_BACKUP" "$LOCALE_BACKUP"
  fi
  if [[ -f "$LEGACY_LOCALE_ABSENT_MARKER" \
    && ! -L "$LEGACY_LOCALE_ABSENT_MARKER" && ! -e "$LOCALE_ABSENT_MARKER" ]]; then
    mv -- "$LEGACY_LOCALE_ABSENT_MARKER" "$LOCALE_ABSENT_MARKER"
  fi
  if [[ -f "$LEGACY_LOCALE_PACKAGES" && ! -L "$LEGACY_LOCALE_PACKAGES" ]]; then
    touch "$LOCALE_PACKAGES"
    while IFS= read -r package_name || [[ -n "$package_name" ]]; do
      [[ -z "$package_name" ]] || grep -Fqx -- "$package_name" "$LOCALE_PACKAGES" \
        || printf '%s\n' "$package_name" >> "$LOCALE_PACKAGES"
    done < "$LEGACY_LOCALE_PACKAGES"
    rm -f -- "$LEGACY_LOCALE_PACKAGES"
  fi
}

save_original_locale() {
  migrate_legacy_locale_state

  if [[ ! -e "$LOCALE_BACKUP" && ! -e "$LOCALE_ABSENT_MARKER" ]]; then
    if [[ -f /etc/default/locale && ! -L /etc/default/locale ]]; then
      cp -a -- /etc/default/locale "$LOCALE_BACKUP"
      chmod 600 "$LOCALE_BACKUP"
    else
      : > "$LOCALE_ABSENT_MARKER"
      chmod 600 "$LOCALE_ABSENT_MARKER"
    fi
  fi
}

choose_terminal_language() {
  local answer selected_locale selected_language primary_language package_name index
  local current_locale="${LANG:-не задана}"
  local -a titles=(
    "$(msg terminal_keep)"
    "Русский — ru_RU.UTF-8"
    "English (US) — en_US.UTF-8"
    "Deutsch — de_DE.UTF-8"
    "Français — fr_FR.UTF-8"
    "Español — es_ES.UTF-8"
    "Italiano — it_IT.UTF-8"
    "Português (Brasil) — pt_BR.UTF-8"
    "Polski — pl_PL.UTF-8"
    "Українська — uk_UA.UTF-8"
    "Türkçe — tr_TR.UTF-8"
    "简体中文 — zh_CN.UTF-8"
    "日本語 — ja_JP.UTF-8"
    "한국어 — ko_KR.UTF-8"
    "$(msg terminal_other)"
  )
  local -a locales=(
    "" ru_RU.UTF-8 en_US.UTF-8 de_DE.UTF-8 fr_FR.UTF-8 es_ES.UTF-8
    it_IT.UTF-8 pt_BR.UTF-8 pl_PL.UTF-8 uk_UA.UTF-8 tr_TR.UTF-8
    zh_CN.UTF-8 ja_JP.UTF-8 ko_KR.UTF-8 ""
  )
  local -a language_values=(
    "" ru_RU:ru en_US:en de_DE:de fr_FR:fr es_ES:es it_IT:it
    pt_BR:pt pl_PL:pl uk_UA:uk tr_TR:tr zh_CN:zh ja_JP:ja ko_KR:ko ""
  )
  local -a language_packages=(
    "" "language-pack-ru manpages-ru" language-pack-en language-pack-de
    language-pack-fr language-pack-es language-pack-it language-pack-pt
    language-pack-pl language-pack-uk language-pack-tr language-pack-zh-hans
    language-pack-ja language-pack-ko ""
  )
  local -a supported_locales packages=(locales) available_packages=() \
    newly_installed=() extra_packages=()

  while :; do
    printf '\n%s\n' "$(msg terminal_heading "$current_locale")"
    for index in "${!titles[@]}"; do
      printf '  %d) %s\n' "$((index + 1))" "${titles[index]}"
    done
    read -rp "$(msg terminal_prompt)" answer || die "$(msg input_interrupted)"
    answer="${answer:-1}"
    [[ "$answer" =~ ^[0-9]+$ ]] && ((answer >= 1 && answer <= ${#titles[@]})) && break
    warn "$(msg invalid_number 1 "${#titles[@]}")"
  done

  ((answer == 1)) && { log "$(msg terminal_unchanged)"; return 0; }
  ensure_apt_updated
  save_original_locale

  if ((answer == ${#titles[@]})); then
    package_is_installed locales || newly_installed+=(locales)
    apt-get install -y locales
    mapfile -t supported_locales < <(awk '{print $1}' /usr/share/i18n/SUPPORTED | sort -u)
    choose_numbered_option "$(msg terminal_full_list)" selected_locale \
      "${supported_locales[@]}"
    primary_language="${selected_locale%%_*}"
    selected_language="${selected_locale%%.*}:${primary_language}"
    packages+=("language-pack-${primary_language}")
  else
    selected_locale="${locales[answer - 1]}"
    selected_language="${language_values[answer - 1]}"
    read -r -a extra_packages <<< "${language_packages[answer - 1]}"
    packages+=("${extra_packages[@]}")
  fi

  for package_name in "${packages[@]}"; do
    [[ -n "$package_name" ]] || continue
    if apt-cache show "$package_name" >/dev/null 2>&1; then
      available_packages+=("$package_name")
      package_is_installed "$package_name" || newly_installed+=("$package_name")
    else
      warn "$(msg locale_package_missing "$package_name")"
    fi
  done

  export DEBIAN_FRONTEND=noninteractive
  ((${#available_packages[@]} == 0)) || apt-get install -y "${available_packages[@]}"
  locale-gen "$selected_locale"
  update-locale LANG="$selected_locale" LANGUAGE="$selected_language" \
    LC_MESSAGES="$selected_locale"
  record_new_packages "$LOCALE_PACKAGES" "${newly_installed[@]}"

  log "$(msg locale_selected "$selected_locale")"
}

choose_and_install_programs() {
  local answer token group_index package_name
  local -a selected_groups=() group_packages=() requested=() available=() newly_installed=()
  local -A selected=() seen=()

  printf '\n%s\n' "$(msg program_heading)"
  for group_index in "${!PROGRAM_GROUP_TITLES[@]}"; do
    printf '  %d) %s\n     %s\n' "$((group_index + 1))" \
      "${PROGRAM_GROUP_TITLES[group_index]}" "${PROGRAM_GROUP_DESCRIPTIONS[group_index]}"
  done
  printf '  0) %s\n' "$(msg program_none)"
  printf '\n%s\n' "$(msg program_example)"
  read -rp "$(msg program_prompt)" answer || die "$(msg input_interrupted)"
  answer="${answer//,/ }"

  if [[ -z "${answer//[[:space:]]/}" ]]; then
    for group_index in "${!PROGRAM_GROUP_TITLES[@]}"; do
      selected_groups+=("$group_index")
    done
  elif [[ "$answer" =~ ^[[:space:]]*0[[:space:]]*$ ]]; then
    log "$(msg program_skipped)"
    return 0
  else
    for token in $answer; do
      [[ "$token" =~ ^[0-9]+$ ]] \
        || die "$(msg program_bad_number "$token")"
      ((token >= 1 && token <= ${#PROGRAM_GROUP_TITLES[@]})) \
        || die "$(msg program_out_of_range "$token")"
      group_index="$((token - 1))"
      [[ -n "${selected[$group_index]:-}" ]] || selected_groups+=("$group_index")
      selected[$group_index]=yes
    done
  fi

  ensure_apt_updated
  for group_index in "${selected_groups[@]}"; do
    log "$(msg program_selected "${PROGRAM_GROUP_TITLES[group_index]}")"
    read -r -a group_packages <<< "${PROGRAM_GROUP_PACKAGES[group_index]}"
    for package_name in "${group_packages[@]}"; do
      [[ -n "${seen[$package_name]:-}" ]] && continue
      seen[$package_name]=yes
      requested+=("$package_name")
    done
  done

  for package_name in "${requested[@]}"; do
    if apt-cache show "$package_name" >/dev/null 2>&1; then
      available+=("$package_name")
      package_is_installed "$package_name" || newly_installed+=("$package_name")
    else
      warn "$(msg package_missing "$package_name")"
    fi
  done

  ((${#available[@]} > 0)) || die "$(msg no_packages)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y "${available[@]}"
  record_new_packages "$PROGRAM_PACKAGES" "${newly_installed[@]}"
  log "$(msg programs_installed)"
}

choose_numbered_option() {
  local prompt="$1" result_variable="$2" answer index
  shift 2
  local -a options=("$@")

  ((${#options[@]} > 0)) || die "$(msg no_options "$prompt")"
  while :; do
    printf '\n%s\n' "$prompt"
    for index in "${!options[@]}"; do
      printf '  %d) %s\n' "$((index + 1))" "${options[index]}"
    done
    read -rp "$(msg select_option)" answer || die "$(msg input_interrupted)"
    if [[ "$answer" =~ ^[0-9]+$ ]] && ((answer >= 1 && answer <= ${#options[@]})); then
      printf -v "$result_variable" '%s' "${options[answer - 1]}"
      return 0
    fi
    warn "$(msg invalid_number 1 "${#options[@]}")"
  done
}

choose_timezone_from_full_list() {
  local result_variable="$1" region selected_timezone
  local -a regions region_timezones

  mapfile -t regions < <(timedatectl list-timezones | awk -F/ 'NF > 1 && !seen[$1]++ { print $1 }')
  choose_numbered_option "$(msg select_region)" region "${regions[@]}"
  mapfile -t region_timezones < <(timedatectl list-timezones | awk -F/ -v selected_region="$region" '$1 == selected_region')
  choose_numbered_option "$(msg select_timezone "$region")" selected_timezone "${region_timezones[@]}"
  printf -v "$result_variable" '%s' "$selected_timezone"
}

choose_timezone() {
  local current_timezone timezone candidate
  local full_list_option="$(msg other_timezone)"
  local -a timezone_options=()

  current_timezone="$(timedatectl show --property=Timezone --value 2>/dev/null || true)"
  current_timezone="${current_timezone:-Asia/Novosibirsk}"

  for candidate in \
    "$current_timezone" \
    UTC \
    Europe/Moscow \
    Europe/Kaliningrad \
    Asia/Yekaterinburg \
    Asia/Omsk \
    Asia/Novosibirsk \
    Asia/Krasnoyarsk \
    Asia/Irkutsk \
    Asia/Yakutsk \
    Asia/Vladivostok \
    Asia/Magadan \
    Asia/Kamchatka; do
    if timedatectl list-timezones | grep -Fqx -- "$candidate" &&
       [[ ! " ${timezone_options[*]} " =~ " ${candidate} " ]]; then
      timezone_options+=("$candidate")
    fi
  done
  timezone_options+=("$full_list_option")

  choose_numbered_option "$(msg timezone_heading "$current_timezone")" timezone "${timezone_options[@]}"
  if [[ "$timezone" == "$full_list_option" ]]; then
    choose_timezone_from_full_list timezone
  fi

  timedatectl list-timezones | grep -Fqx -- "$timezone" || die "$(msg unknown_timezone "$timezone")"
  timedatectl set-timezone "$timezone"
  log "$(msg timezone_set "$timezone")"
}

[[ "$EUID" -eq 0 ]] || die "Run this script as root"
choose_ui_language
for command_name in awk blkid fallocate grep mkswap swapon sysctl timedatectl; do
  command -v "$command_name" >/dev/null 2>&1 || die "$(msg required_missing "$command_name")"
done

choose_timezone
choose_terminal_language
choose_and_install_programs

log "$(msg swap_configuring "$SWAPSIZE")"
if [[ ! -e "$SWAPFILE" ]]; then
  fallocate -l "$SWAPSIZE" "$SWAPFILE"
  chmod 600 "$SWAPFILE"
  mkswap "$SWAPFILE"
elif [[ ! -f "$SWAPFILE" || -L "$SWAPFILE" ]]; then
  die "$SWAPFILE exists but is not a regular non-symlink file"
else
  chmod 600 "$SWAPFILE"
  swap_type="$(blkid -p -s TYPE -o value "$SWAPFILE" 2>/dev/null || true)"
  [[ "$swap_type" == swap ]] || die "$SWAPFILE exists but does not contain a swap signature"
fi

if ! swapon --show=NAME --noheadings | awk '{$1=$1}; $0 == "/swapfile" { found=1 } END { exit !found }'; then
  swapon "$SWAPFILE"
fi

if ! awk '$1 == "/swapfile" && $3 == "swap" { found=1 } END { exit !found }' /etc/fstab; then
  cp -a /etc/fstab "/etc/fstab.bak.$(date +%F-%H%M%S-%N)"
  printf '%s none swap sw 0 0\n' "$SWAPFILE" >> /etc/fstab
fi

cat > "$SYSCTL_FILE" <<EOF
# Managed by ochenstarik-server-1.sh
vm.swappiness=${SWAPPINESS}
EOF
chmod 644 "$SYSCTL_FILE"
sysctl -p "$SYSCTL_FILE" >/dev/null

log "$(msg setup_complete)"
printf 'Timezone: %s\n' "$(timedatectl show --property=Timezone --value)"
swapon --show
printf '\n%s\n' "$(msg next_script)"
