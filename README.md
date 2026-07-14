# Быстрая настройка Ubuntu Server

Набор независимых Bash-скриптов для первоначальной настройки Ubuntu Server. Можно запустить только нужные модули или выполнить их по порядку для полной настройки.

## Что входит в проект

| Файл | Назначение | Можно запускать отдельно |
| --- | --- | --- |
| `ochenstarik-server-1.sh` | Предлагает выбрать часовой пояс, создаёт swap-файл 2 ГБ и задаёт `vm.swappiness=20` | Да |
| `ochenstarik-server-2.sh` | Предлагает выбрать будущий SSH-порт, обновляет систему, ставит пакеты и настраивает UFW | Да |
| `ochenstarik-server-user-3.sh` | Создаёт администратора, переносит SSH на порт из этапа 2, проверяет права и включает fail2ban | После установки необходимых пакетов; проще всего сначала запустить скрипт 2 |
| `ochenstarik-server-tg-4.sh` | Отправляет уведомления в Telegram при успешном входе по SSH | После установки OpenSSH и `curl`; обычно после скрипта 2 или 3 |
| `ochenstarik-server-vpn-5.sh` | Устанавливает Xray и направляет системный трафик через VLESS + REALITY | Да; зависимости устанавливаются автоматически |
| `ochenstarik-server-panel-warp-6.sh` | Устанавливает 3x-ui и Cloudflare WARP, настраивает и проверяет их порты | Ubuntu 22.04/24.04/26.04 или Debian 12/13 |

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

## 1. Часовой пояс и настройка swap

Файл: `ochenstarik-server-1.sh`.

Сначала показывает нумерованное меню популярных часовых поясов, включая `Asia/Novosibirsk`, `Europe/Moscow` и `UTC`. Нужную зону достаточно выбрать по номеру. Для остальных зон предусмотрен полный список с последовательным выбором региона и часового пояса — вводить имя вручную не требуется. Затем скрипт создаёт `/swapfile` размером 2 ГБ, добавляет его в `/etc/fstab` и устанавливает `vm.swappiness=20`. Повторный запуск предусмотрен.

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

Скрипт запрашивает SSH-порт, который будет применён на этапе 3, сохраняет его в `/etc/ochenstarik-server/ssh-port.conf`, обновляет систему и устанавливает OpenSSH, UFW, fail2ban, инструменты обработки документов, изображений, аудио и видео.

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

Поддерживаются официально доступные пакеты WARP для Ubuntu `jammy`, `noble`, `resolute` и Debian `bookworm`, `trixie` на `amd64` и `arm64`.

Официальные источники: [установка 3x-ui](https://github.com/MHSanaei/3x-ui/wiki/Installation), [пакеты Cloudflare WARP](https://pkg.cloudflareclient.com/) и [режимы WARP](https://developers.cloudflare.com/warp-client/warp-modes/).

## Полная установка

Если нужны все модули, запускайте их по очереди:

```bash
sudo ./ochenstarik-server-1.sh
sudo ./ochenstarik-server-2.sh
sudo ./ochenstarik-server-user-3.sh
sudo ./ochenstarik-server-tg-4.sh
sudo ./ochenstarik-server-vpn-5.sh
sudo ./ochenstarik-server-panel-warp-6.sh
```

VPN, 3x-ui, WARP и Telegram-уведомления являются необязательными этапами.

## Безопасность

- Всегда проверяйте скачанные скрипты перед запуском от `root`.
- Не публикуйте токены Telegram, пароли, приватные SSH-ключи и ссылки VLESS.
- Не закрывайте действующую SSH-сессию во время переноса SSH на новый порт.
- Перед настройкой на рабочем сервере сделайте резервную копию важных данных.
