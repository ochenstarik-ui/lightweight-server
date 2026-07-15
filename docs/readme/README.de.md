# Schnelle Einrichtung von Ubuntu Server

[English](../../README.md) | [Русский](README.ru.md) | [Español](README.es.md) | **Deutsch** | [Français](README.fr.md) | [Português](README.pt.md) | [中文](README.zh-CN.md) | [日本語](README.ja.md) | [العربية](README.ar.md) | [हिन्दी](README.hi.md)

Modulare Bash-Skripte für Ersteinrichtung, Absicherung, SSH, VPN, 3x-ui, WARP und Sicherungen auf Ubuntu Server.

> Zur Überwachung und gemeinsamen Verwaltung mehrerer Server verwenden Sie [Server Monitor Manager](https://github.com/ochenstarik-ui/server-monitor-manager). Das Projekt befindet sich noch in einer frühen Entwicklungsphase.

## Schnellinstallation

```bash
sudo apt-get update
sudo apt-get install -y curl ca-certificates
curl -4 -fLO --retry 5 --retry-delay 10 --connect-timeout 30 \
  https://raw.githubusercontent.com/ochenstarik-ui/lightweight-server/main/ochenstarik-server-install.sh
chmod 700 ochenstarik-server-install.sh
sudo ./ochenstarik-server-install.sh
```

Die erste Frage wählt die Sprache des Installers; English ist voreingestellt. Danach kann jeder der acht Schritte ausgeführt, übersprungen oder zum Beenden verwendet werden.

## Schritte

1. Zeitzone, Terminalsprache, empfohlene Programme und Swap.
2. Basispakete, SSH-Port, IPv4/IPv6 und UFW.
3. Administrator, SSH-Schlüssel, Rechte, sudo und fail2ban.
4. Telegram-Benachrichtigungen für SSH-Anmeldungen.
5. System-VPN über Xray.
6. 3x-ui und lokaler Cloudflare-WARP-Proxy.
7. Erstsicherung sowie tägliche, wöchentliche oder monatliche Sicherungen.
8. Optionale KI-Agenten: Hermes, OpenClaw, OpenHands, OpenCode oder Aider.

Schließen Sie die aktuelle SSH-Sitzung während der Portänderung nicht. Testen Sie zuerst die neue Anmeldung in einem zweiten Terminal. Weitere Hinweise enthält die [englische Hauptdokumentation](../../README.md).
