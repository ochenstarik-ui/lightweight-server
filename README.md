# Быстрая настройка Ubuntu Server

Набор независимых Bash-скриптов для первоначальной настройки Ubuntu Server. Можно запустить только нужные модули или выполнить их по порядку для полной настройки.

## Что входит в проект

| Файл | Назначение | Можно запускать отдельно |
| --- | --- | --- |
| `ochenstarik-server-1.sh` | Создаёт swap-файл 2 ГБ и задаёт `vm.swappiness=20` | Да |
| `ochenstarik-server-2.sh` | Обновляет систему, ставит серверные и офисные пакеты, настраивает часовой пояс и UFW | Да |
| `ochenstarik-server-user-3.sh` | Создаёт администратора, устанавливает SSH-ключ, переносит SSH на порт 20202, включает fail2ban | После установки необходимых пакетов; проще всего сначала запустить скрипт 2 |
| `ochenstarik-server-tg-4.sh` | Отправляет уведомления в Telegram при успешном входе по SSH | После установки OpenSSH и `curl`; обычно после скрипта 2 или 3 |
| `ochenstarik-server-vpn-5.sh` | Устанавливает Xray и направляет системный трафик через VLESS + REALITY | Да; зависимости устанавливаются автоматически |

Файлы `*.env.example` являются только примерами. Не записывайте настоящие пароли, токены и приватные SSH-ключи в Git.

## Требования

- Ubuntu Server или совместимая Debian-система с `systemd`;
- доступ `root` или пользователь с `sudo`;
- подключение к интернету;
- рекомендуется сохранить текущую SSH-сессию открытой до проверки нового входа.

## Получение проекта

```bash
sudo apt-get update
sudo apt-get install -y git
git clone https://github.com/ochenstarik-ui/lightweight-server.git
cd lightweight-server
chmod 700 ./*.sh
```

Перед запуском любого выбранного файла можно проверить его синтаксис:

```bash
bash -n ./ИМЯ-СКРИПТА.sh
```

## 1. Настройка swap

Файл: `ochenstarik-server-1.sh`.

Создаёт `/swapfile` размером 2 ГБ, добавляет его в `/etc/fstab` и устанавливает `vm.swappiness=20`. Повторный запуск предусмотрен.

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

## 2. Базовые пакеты, часовой пояс и брандмауэр

Файл: `ochenstarik-server-2.sh`.

Скрипт обновляет систему, устанавливает OpenSSH, UFW, fail2ban, инструменты обработки документов, изображений, аудио и видео, а также задаёт часовой пояс `Asia/Novosibirsk`.

Открываются TCP-порты:

- `22` — временный SSH-порт;
- `20202` — новый SSH-порт;
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

Скрипт интерактивно запрашивает имя нового администратора, SSH-ключ и пароль. Затем он:

- создаёт или обновляет пользователя;
- добавляет пользователя в группу `sudo`;
- запрещает вход `root` по SSH;
- переносит SSH на порт `20202`;
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
ssh -p 20202 ИМЯ_ПОЛЬЗОВАТЕЛЯ@IP_СЕРВЕРА
```

Только после успешной проверки можно удалить временное правило порта 22:

```bash
sudo ufw delete allow 22/tcp
```

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

Скрипт устанавливает Xray и необходимые пакеты, принимает прямую ссылку `vless://` либо HTTPS-ссылку подписки 3x-ui и настраивает маршрутизацию через `nftables`. Поддерживается VLESS с транспортом TCP/RAW и REALITY.

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

## Полная установка

Если нужны все модули, запускайте их по очереди:

```bash
sudo ./ochenstarik-server-1.sh
sudo ./ochenstarik-server-2.sh
sudo ./ochenstarik-server-user-3.sh
sudo ./ochenstarik-server-tg-4.sh
sudo ./ochenstarik-server-vpn-5.sh
```

VPN и Telegram-уведомления являются необязательными этапами.

## Безопасность

- Всегда проверяйте скачанные скрипты перед запуском от `root`.
- Не публикуйте токены Telegram, пароли, приватные SSH-ключи и ссылки VLESS.
- Не закрывайте действующую SSH-сессию во время переноса SSH на новый порт.
- Перед настройкой на рабочем сервере сделайте резервную копию важных данных.
