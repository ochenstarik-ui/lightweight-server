# Configuration rapide d’Ubuntu Server

[English](../../README.md) | [Русский](README.ru.md) | [Español](README.es.md) | [Deutsch](README.de.md) | **Français** | [Português](README.pt.md) | [中文](README.zh-CN.md) | [日本語](README.ja.md) | [العربية](README.ar.md) | [हिन्दी](README.hi.md)

Scripts Bash modulaires pour la configuration initiale, la sécurisation, SSH, le VPN, 3x-ui, WARP et les sauvegardes d’Ubuntu Server.

> Pour surveiller et administrer plusieurs serveurs depuis une seule application, consultez [Server Monitor Manager](https://github.com/ochenstarik-ui/server-monitor-manager). Ce projet est encore au début de son développement.

## Installation rapide

```bash
sudo apt-get update
sudo apt-get install -y curl ca-certificates
curl -4 -fLO --retry 5 --retry-delay 10 --connect-timeout 30 \
  https://raw.githubusercontent.com/ochenstarik-ui/lightweight-server/main/ochenstarik-server-install.sh
chmod 700 ochenstarik-server-install.sh
sudo ./ochenstarik-server-install.sh
```

La première question sélectionne la langue de l’installateur ; English est la valeur par défaut. Chacune des sept étapes peut ensuite être installée, ignorée ou utilisée pour quitter.

## Étapes

1. Fuseau horaire, langue du terminal, programmes recommandés et swap.
2. Paquets de base, port SSH, IPv4/IPv6 et UFW.
3. Administrateur, clé SSH, permissions, sudo et fail2ban.
4. Notifications Telegram des connexions SSH.
5. VPN système via Xray.
6. Panneau 3x-ui et proxy local Cloudflare WARP.
7. Instantané initial et sauvegardes quotidiennes, hebdomadaires ou mensuelles.

Ne fermez pas la session SSH actuelle pendant le changement de port. Testez d’abord la nouvelle connexion dans un autre terminal. Consultez la [documentation principale en anglais](../../README.md) pour plus de détails.
