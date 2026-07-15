# Быстрая настройка Ubuntu Server

Набор независимых Bash-скриптов для первоначальной настройки Ubuntu Server. Можно запустить только нужные модули или выполнить их по порядку для полной настройки.

## Быстрая установка

Скопируйте весь блок в терминал сервера. Он загружает архив через `codeload.github.com`, проверяет ошибки на каждом шаге и запускает единый пошаговый мастер:

```bash
set -e
cd "$HOME"
sudo apt-get update
sudo apt-get install -y curl ca-certificates tar
archive="$(mktemp)"
trap 'rm -f "$archive"' EXIT
curl -4 -fL \
  --retry 5 \
  --retry-delay 10 \
  --connect-timeout 30 \
  https://codeload.github.com/ochenstarik-ui/lightweight-server/tar.gz/refs/heads/main \
  -o "$archive"
install -d -m 700 lightweight-server
tar -xzf "$archive" -C lightweight-server --strip-components=1
rm -f "$archive"
trap - EXIT
cd lightweight-server
chmod 700 ./*.sh
sudo ./ochenstarik-server-install.sh
```

Мастер показывает этапы 1–7 по порядку. На каждом этапе можно выбрать установку, пропуск или завершение. В первом этапе пустой ввод устанавливает все рекомендуемые наборы программ. Во время изменения SSH-порта не закрывайте текущую сессию — сначала проверьте новый вход во втором терминале.

Если нужен только мастер без скачивания полного архива:

```bash
sudo apt-get update
sudo apt-get install -y curl ca-certificates
curl -4 -fLO \
  --retry 5 \
  --retry-delay 10 \
  --connect-timeout 30 \
  https://raw.githubusercontent.com/ochenstarik-ui/lightweight-server/main/ochenstarik-server-install.sh
chmod 700 ochenstarik-server-install.sh
sudo ./ochenstarik-server-install.sh
```

При запуске одного мастера недостающие этапы будут загружены автоматически из основной ветки и проверены командой `bash -n`.

## Что входит в проект

| Файл | Назначение | Можно запускать отдельно |
| --- | --- | --- |
| `ochenstarik-server-install.sh` | Единый пошаговый мастер: установить, пропустить или завершить на каждом этапе | Да; рекомендуемый способ полной настройки |
| `ochenstarik-server-1.sh` | Предлагает выбрать язык диалога, часовой пояс, язык терминала и наборы программ, создаёт swap-файл 2 ГБ | Да |
| `ochenstarik-server-2.sh` | Предлагает будущий SSH-порт и IPv4/IPv6, обновляет систему, ставит обязательные пакеты и настраивает UFW | Да |
| `ochenstarik-server-user-3.sh` | Создаёт администратора, переносит SSH на порт из этапа 2, проверяет права и включает fail2ban | После установки необходимых пакетов; проще всего сначала запустить скрипт 2 |
| `ochenstarik-server-tg-4.sh` | Отправляет уведомления в Telegram при успешном входе по SSH | После установки OpenSSH и `curl`; обычно после скрипта 2 или 3 |
| `ochenstarik-server-vpn-5.sh` | Устанавливает Xray и направляет системный трафик через VLESS + REALITY | Да; зависимости устанавливаются автоматически |
| `ochenstarik-server-panel-warp-6.sh` | Устанавливает 3x-ui и Cloudflare WARP, настраивает и проверяет их порты | Ubuntu 22.04/24.04/26.04 или Debian 12/13 |
| `ochenstarik-server-backup-7.sh` | Создаёт неизменяемый первичный снимок и настраивает выбранные расписания резервного копирования | Да; зависимости устанавливаются автоматически |
| `ochenstarik-server-uninstall.sh` | Удаляет настройки, службы и данные проекта для повторной установки с начала | Да; запускать только из сохранённой SSH-сессии |

Файлы `*.env.example` являются только примерами. Не записывайте настоящие пароли, токены и приватные SSH-ключи в Git.

## Требования

- Ubuntu Server или совместимая Debian-система с `systemd`;
- доступ `root` или пользователь с `sudo`;
- подключение к интернету;
- рекомендуется сохранить текущую SSH-сессию открытой до проверки нового входа.

## Получение проекта

Рекомендуемый способ — загрузка архива через `codeload.github.com`. Он подходит в том числе для серверов, на которых соединение с основным доменом `github.com` завершается ошибкой `SSL connection timeout`:

```bash
set -e
cd "$HOME"
sudo apt-get update
sudo apt-get install -y curl ca-certificates tar
curl -4 -fL \
  --retry 5 \
  --retry-delay 10 \
  --connect-timeout 30 \
  https://codeload.github.com/ochenstarik-ui/lightweight-server/tar.gz/refs/heads/main \
  -o lightweight-server.tar.gz
mkdir lightweight-server
tar -xzf lightweight-server.tar.gz -C lightweight-server --strip-components=1
rm lightweight-server.tar.gz
cd lightweight-server
chmod 700 ./*.sh
```

Если `github.com` доступен с сервера, проект также можно получить через Git:

```bash
set -e
cd "$HOME"
sudo apt-get update
sudo apt-get install -y git ca-certificates
git -c http.version=HTTP/1.1 clone --depth 1 https://github.com/ochenstarik-ui/lightweight-server.git
cd lightweight-server
chmod 700 ./*.sh
```

Команда `set -e` останавливает последовательность при ошибке загрузки, поэтому команды `cd` и `chmod` не будут выполняться для отсутствующей папки.

Перед запуском любого выбранного файла можно проверить его синтаксис:

```bash
bash -n ./ИМЯ-СКРИПТА.sh
```

## 1. Часовой пояс, язык, программы и swap

Файл: `ochenstarik-server-1.sh`.

Самый первый запрос выбирает язык диалога установщика: English, Русский, Español, Deutsch, Français, Português, 中文, 日本語, العربية или हिन्दी. Начальное меню выводится на английском, а пустой ввод оставляет English. Этот выбор меняет вопросы и сообщения скрипта, но не системную локаль сервера.

Затем показывается нумерованное меню популярных часовых поясов, включая `Asia/Novosibirsk`, `Europe/Moscow` и `UTC`. Нужную зону достаточно выбрать по номеру. Для остальных зон предусмотрен полный список с последовательным выбором региона и часового пояса — вводить имя вручную не требуется.

После выбора времени скрипт показывает меню языков терминала: оставить текущий, русский, английский, немецкий, французский, испанский, итальянский, португальский, польский, украинский, турецкий, китайский, японский, корейский либо выбрать другую локаль из полного системного списка. Выбранный язык применяется к новым терминальным сессиям. Исходный `/etc/default/locale` сохраняется для последующего восстановления.

Затем можно отметить несколько наборов программ номерами через пробел, например `1 2 4 9`. Пустой ввод устанавливает все наборы, а `0` пропускает дополнительные программы:

1. Терминал и повседневная работа — Git, wget/curl, jq/yq, ripgrep, fd, fzf, lnav, редакторы, MC, tmux/screen, htop/btop, ncdu, rsync и strace.
2. Диагностика сети — DNS, ping, MTR, traceroute, tcpdump, nmap, netcat, HTTPie, whois, ethtool и socat.
3. Мониторинг системы и дисков — iotop, sysstat, SMART, lm-sensors, atop, nethogs, vnStat и psmisc.
4. Безопасность и обслуживание — auditd, AppArmor tools, Lynis, needrestart, unattended-upgrades, debsums, ACL и extended attributes.
5. Разработка и автоматизация — компилятор, ShellCheck, Python pip/venv и pipx.
6. Архивы и данные — 7-Zip, ZIP/RAR, SQLite, csvkit, клиенты PostgreSQL и Redis.
7. Документы, PDF и OCR — Poppler, qpdf, Ghostscript, OCRmyPDF/Tesseract, LibreOffice, Pandoc, antiword и catdoc.
8. Изображения, аудио и видео — ImageMagick, ExifTool, WebP, FFmpeg и MediaInfo.
9. Резервное копирование — restic, BorgBackup и rclone.

Скрипт проверяет доступность каждого пакета в подключённых репозиториях. Недоступные для конкретной версии или набора репозиториев пакеты пропускаются с предупреждением. Список программ, которых не было до запуска, сохраняется в `/etc/ochenstarik-server/step1-installed-packages.list` для безопасной очистки.

Затем скрипт создаёт `/swapfile` размером 2 ГБ, добавляет его в `/etc/fstab` и устанавливает `vm.swappiness=20`. Повторный запуск предусмотрен.

```bash
curl -fLO https://raw.githubusercontent.com/ochenstarik-ui/lightweight-server/main/ochenstarik-server-1.sh
chmod 700 ochenstarik-server-1.sh
bash -n ochenstarik-server-1.sh
sudo ./ochenstarik-server-1.sh
```

Проверка:

```bash
swapon --show
sysctl vm.swappiness
```

## 2. Базовые пакеты, SSH-порт и брандмауэр

Файл: `ochenstarik-server-2.sh`.

При каждом запуске скрипт предлагает три действия: полную установку или обновление, изменение режима IP без переустановки пакетов либо добавление открытых портов. При полной установке он запрашивает SSH-порт для этапа 3, обновляет систему и устанавливает только обязательные компоненты: OpenSSH, UFW, fail2ban, `sudo`, TLS-сертификаты и сетевые инструменты. Дополнительные программы выбираются на этапе 1.

Для входящих подключений можно выбрать:

- только IPv4 — IPv6 отключается в UFW и системно через `sysctl`; этот режим рекомендуется, если 3x-ui используется только по IPv4;
- только IPv6 — управляемые скриптом порты открываются лишь для IPv6;
- IPv4 + IPv6 — порты открываются для обоих семейств.

Выбор сохраняется в `/etc/ochenstarik-server/ip-family.conf`, а список управляемых портов — в `/etc/ochenstarik-server/ufw-managed-ports.conf`. При переходе на режим с одним семейством старые правила этих портов пересоздаются. Скрипт не разрешит отключить семейство адресов, через которое работает текущая SSH-сессия. Для режима IPv6 также проверяются глобальный IPv6-адрес и маршрут по умолчанию.

В режиме «только IPv6» системный IPv4 остаётся доступен для исходящих соединений и работы менеджера пакетов, но входящие управляемые порты по IPv4 закрываются UFW. Полное переносимое отключение IPv4 в Linux без привязки к конкретной сетевой конфигурации не выполняется.

Открываются TCP-порты:

- `22` — временный SSH-порт;
- выбранный SSH-порт — будущий порт SSH;
- `80`, `443` — HTTP и HTTPS;
- `2096`, `40000`, `63636` — порты приложений.

```bash
curl -fLO https://raw.githubusercontent.com/ochenstarik-ui/lightweight-server/main/ochenstarik-server-2.sh
chmod 700 ochenstarik-server-2.sh
bash -n ochenstarik-server-2.sh
sudo ./ochenstarik-server-2.sh
```

Проверка:

```bash
sudo ufw status verbose
cat /etc/ochenstarik-server/ip-family.conf
cat /proc/sys/net/ipv6/conf/all/disable_ipv6
timedatectl
```

## 3. Администратор и защита SSH

Файл: `ochenstarik-server-user-3.sh`.

При каждом запуске скрипт предлагает два режима:

1. новая установка или повторная настройка администратора и SSH;
2. только добавление открытых портов в UFW без изменения пользователя и SSH.

В режиме новой установки скрипт интерактивно запрашивает имя администратора, SSH-ключ и пароль. SSH-порт автоматически читается из защищённого файла, созданного этапом 2. Если этап 2 не выполнялся, скрипт предложит выбрать порт вручную. Затем он:

- создаёт или обновляет пользователя;
- добавляет пользователя в группу `sudo`;
- назначает пользователю его домашнюю папку и всё содержимое `.ssh`;
- устанавливает права `700` для `.ssh` и `600` для `authorized_keys` и остальных файлов ключей;
- запрещает вход `root` по SSH;
- переносит SSH на выбранный порт и добавляет для него правило UFW;
- настраивает fail2ban;
- по выбору управляет правилами UFW.

Правила UFW добавляются с учётом режима IPv4/IPv6, сохранённого скриптом 2. Новые порты также записываются в общий список управляемых правил, поэтому последующее переключение IP-режима пересоздаст их корректно.

Для отдельного запуска сначала установите зависимости:

```bash
sudo apt-get update
sudo apt-get install -y sudo ufw fail2ban openssl openssh-server
curl -fLO https://raw.githubusercontent.com/ochenstarik-ui/lightweight-server/main/ochenstarik-server-user-3.sh
chmod 700 ochenstarik-server-user-3.sh
bash -n ochenstarik-server-user-3.sh
sudo ./ochenstarik-server-user-3.sh
```

Не закрывая текущую сессию, откройте второй терминал и проверьте вход:

```bash
ssh -p ВЫБРАННЫЙ_ПОРТ ИМЯ_ПОЛЬЗОВАТЕЛЯ@IP_СЕРВЕРА
```

Только после успешной проверки можно удалить временное правило порта 22:

```bash
sudo ufw delete allow 22/tcp
```

Чтобы позднее открыть дополнительные порты, повторно запустите скрипт, выберите пункт `2` и введите правила через пробел или запятую:

```text
80 443/tcp 53/udp 40000
```

Для записей без протокола используется TCP. Допустимы только порты от `1` до `65535`. Если UFW неактивен, правила будут сохранены, но скрипт не включит брандмауэр автоматически во избежание потери SSH-доступа.

## 4. Telegram-уведомления о входах по SSH

Файл: `ochenstarik-server-tg-4.sh`.

Создайте бота через `@BotFather`, отправьте ему сообщение и узнайте ID чата. Скрипт запросит токен и ID интерактивно, отправит тестовое сообщение и подключит уведомления через PAM.

Для отдельного запуска:

```bash
sudo apt-get update
sudo apt-get install -y curl openssh-server logrotate
curl -fLO https://raw.githubusercontent.com/ochenstarik-ui/lightweight-server/main/ochenstarik-server-tg-4.sh
chmod 700 ochenstarik-server-tg-4.sh
bash -n ochenstarik-server-tg-4.sh
sudo ./ochenstarik-server-tg-4.sh
```

Журнал уведомлений:

```bash
sudo tail -f /var/log/ochenstarik-ssh-login-telegram.log
```

Токен сохраняется на сервере в `/etc/ochenstarik-server/telegram.conf` с ограниченными правами. Не добавляйте этот файл в репозиторий.

## 5. Системный VPN через Xray

Файл: `ochenstarik-server-vpn-5.sh`.

Скрипт устанавливает Xray и необходимые пакеты, принимает прямую ссылку `vless://` либо HTTPS-ссылку подписки 3x-ui и настраивает маршрутизацию через `nftables`. Если подписка содержит VLESS-ссылки на нескольких портах, скрипт выводит доступные порты и просит выбрать нужный. Поддерживается VLESS с транспортом TCP/RAW и REALITY.

```bash
curl -fLO https://raw.githubusercontent.com/ochenstarik-ui/lightweight-server/main/ochenstarik-server-vpn-5.sh
chmod 700 ochenstarik-server-vpn-5.sh
bash -n ochenstarik-server-vpn-5.sh
sudo ./ochenstarik-server-vpn-5.sh
```

Во время запуска ссылка вводится скрыто. Скрипт сравнивает внешний IP до и после настройки и использует автоматический откат при ошибке. SSH и ответы сервисов на портах `443` и `63636` остаются на прямом маршруте.

Проверка маршрутизации:

```bash
sudo /usr/local/sbin/ochenstarik-xray-routing status
curl -4 https://api.ipify.org
```

Отключение системного VPN:

```bash
sudo ./ochenstarik-server-vpn-5.sh --disable
```

## 6. Панель 3x-ui и локальный proxy Cloudflare WARP

Файл: `ochenstarik-server-panel-warp-6.sh`.

Скрипт предлагает выбрать три разных порта:

- порт веб-панели 3x-ui, по умолчанию `2053`;
- порт подписок 3x-ui, по умолчанию `2096`;
- локальный SOCKS5/HTTP proxy-порт WARP, по умолчанию `40000`.

3x-ui устанавливается официальным интерактивным установщиком. После установки выбранные порты записываются в стандартную SQLite-базу с предварительной резервной копией. Скрипт включает сервис подписок, запускает `x-ui` и проверяет оба TCP-слушателя.

Cloudflare WARP устанавливается из официального APT-репозитория, переводится в Local proxy mode через MASQUE и проверяется запросом к Cloudflare: ответ должен содержать `warp=on`.

```bash
curl -fLO https://raw.githubusercontent.com/ochenstarik-ui/lightweight-server/main/ochenstarik-server-panel-warp-6.sh
chmod 700 ochenstarik-server-panel-warp-6.sh
bash -n ochenstarik-server-panel-warp-6.sh
sudo ./ochenstarik-server-panel-warp-6.sh
```

В UFW открываются и проверяются `80/tcp`, `443/tcp`, выбранный порт панели и выбранный порт подписок. WARP слушает только локально на `127.0.0.1:40000` либо другом выбранном порту. Этот порт намеренно не публикуется через UFW, поскольку локальный proxy не требует аутентификации.

Публичные порты 3x-ui открываются только для семейств адресов, выбранных на этапе 2. В режиме `ipv4` скрипт не создаёт правил IPv6.

Поддерживаются официально доступные пакеты WARP для Ubuntu `jammy`, `noble`, `resolute` и Debian `bookworm`, `trixie` на `amd64` и `arm64`.

Официальные источники: [установка 3x-ui](https://github.com/MHSanaei/3x-ui/wiki/Installation), [пакеты Cloudflare WARP](https://pkg.cloudflareclient.com/) и [режимы WARP](https://developers.cloudflare.com/warp-client/warp-modes/).

## 7. Резервные копии сервера

Файл: `ochenstarik-server-backup-7.sh`.

Скрипт создаёт полный сжатый снимок корневой файловой системы с сохранением владельцев, ACL и расширенных атрибутов. Виртуальные файловые системы, временные каталоги, swap, подключённые диски и сам каталог бэкапов исключаются. Первичный снимок создаётся сразу, повторно не перезаписывается и не участвует в ротации. Если файловая система поддерживает атрибут `immutable`, первичный архив и его контрольная сумма дополнительно защищаются от случайного удаления.

При установке можно выбрать несколько расписаний одним вводом, например `1 3`:

- ежедневное — хранится 7 последних архивов;
- еженедельное — хранится 4 последних архива;
- ежемесячное — хранится 12 последних архивов;
- только первичный снимок без автоматического расписания.

```bash
curl -fLO https://raw.githubusercontent.com/ochenstarik-ui/lightweight-server/main/ochenstarik-server-backup-7.sh
chmod 700 ochenstarik-server-backup-7.sh
bash -n ochenstarik-server-backup-7.sh
sudo ./ochenstarik-server-backup-7.sh
```

По умолчанию архивы сохраняются в `/var/backups/ochenstarik-server`, но во время установки можно указать абсолютный путь на другом диске. Незавершённые архивы имеют суффикс `.partial` и не попадают в ротацию. Для каждого готового архива создаётся файл `.sha256`.

Проверка расписаний и ручной запуск:

```bash
systemctl list-timers "ochenstarik-backup-*"
sudo /usr/local/sbin/ochenstarik-server-backup daily
sudo journalctl -u ochenstarik-backup@daily.service
```

Проверка целостности первичного снимка:

```bash
cd /var/backups/ochenstarik-server/initial
sha256sum -c ./*.sha256
```

Восстанавливайте архив только из rescue-системы или в отдельный пустой каталог, предварительно проверив контрольную сумму. Пример распаковки в подготовленный каталог `/restore`:

```bash
mkdir -p /restore
zstd -dc /ПУТЬ/К/АРХИВУ.tar.zst | tar --acls --xattrs --numeric-owner -xpf - -C /restore
```

Это локальная резервная копия, а не защита от отказа диска или потери сервера. Регулярно переносите готовые архивы и `.sha256` на отдельный сервер или накопитель. Снимок создаётся с работающей системы; для активно изменяющихся баз данных дополнительно используйте штатный экспорт или согласованный снимок самой базы.

## Полная установка

Рекомендуемый способ — единый мастер. Он показывает этапы по порядку и перед каждым предлагает установить его, пропустить либо завершить работу. Если остальные файлы находятся рядом, мастер использует их. Если какой-либо этап отсутствует, мастер безопасно загрузит его из основной ветки, проверит `bash -n` и только потом запустит.

```bash
curl -fLO https://raw.githubusercontent.com/ochenstarik-ui/lightweight-server/main/ochenstarik-server-install.sh
chmod 700 ochenstarik-server-install.sh
bash -n ochenstarik-server-install.sh
sudo ./ochenstarik-server-install.sh
```

После ошибки этап можно повторить, пропустить или завершить весь мастер. Повторный запуск мастера разрешён: каждый модуль поддерживает повторную настройку.

Отдельные скрипты сохранены. При необходимости их по-прежнему можно запускать вручную по очереди:

```bash
sudo ./ochenstarik-server-1.sh
sudo ./ochenstarik-server-2.sh
sudo ./ochenstarik-server-user-3.sh
sudo ./ochenstarik-server-tg-4.sh
sudo ./ochenstarik-server-vpn-5.sh
sudo ./ochenstarik-server-panel-warp-6.sh
sudo ./ochenstarik-server-backup-7.sh
```

VPN, 3x-ui, WARP, Telegram-уведомления и автоматические расписания резервного копирования являются необязательными этапами.

## Удаление и повторная установка с начала

Файл: `ochenstarik-server-uninstall.sh`.

Скрипт удаляет управляемые правила UFW, настройки IPv4/IPv6, SSH drop-in, fail2ban-конфигурацию, Telegram-hook, Xray, 3x-ui, WARP, расписания резервного копирования, swap и служебные файлы проекта. Перед изменением SSH открывается порт `22/tcp`. Правило порта, через который работает текущая SSH-сессия, сохраняется, чтобы не потерять доступ.

Удаление администратора и самих архивов резервных копий требует отдельных подтверждений. Обязательные системные пакеты второго этапа и обновления Ubuntu сохраняются, чтобы не потерять доступ к серверу. Языковые пакеты и дополнительные программы удаляются только если первый скрипт зафиксировал, что до его запуска их не было.

```bash
curl -fLO https://raw.githubusercontent.com/ochenstarik-ui/lightweight-server/main/ochenstarik-server-uninstall.sh
chmod 700 ochenstarik-server-uninstall.sh
bash -n ochenstarik-server-uninstall.sh
sudo ./ochenstarik-server-uninstall.sh
```

Не закрывайте текущую SSH-сессию. После очистки сначала проверьте отдельное подключение через порт 22, затем снова запускайте нужные установочные скрипты. Старое правило текущего SSH-порта можно удалить только после успешной проверки нового входа.

## Безопасность

- Всегда проверяйте скачанные скрипты перед запуском от `root`.
- Не публикуйте токены Telegram, пароли, приватные SSH-ключи и ссылки VLESS.
- Не закрывайте действующую SSH-сессию во время переноса SSH на новый порт.
- Перед настройкой на рабочем сервере сделайте резервную копию важных данных.
