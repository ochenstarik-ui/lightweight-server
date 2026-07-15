# Configuração rápida do Ubuntu Server

[English](../../README.md) | [Русский](README.ru.md) | [Español](README.es.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | **Português** | [中文](README.zh-CN.md) | [日本語](README.ja.md) | [العربية](README.ar.md) | [हिन्दी](README.hi.md)

Scripts Bash modulares para configuração inicial, segurança, SSH, VPN, 3x-ui, WARP e backups no Ubuntu Server.

> Para monitorar e administrar vários servidores em um único aplicativo, use o [Server Monitor Manager](https://github.com/ochenstarik-ui/server-monitor-manager). O projeto ainda está em uma fase inicial de desenvolvimento.

## Instalação rápida

```bash
sudo apt-get update
sudo apt-get install -y curl ca-certificates
curl -4 -fLO --retry 5 --retry-delay 10 --connect-timeout 30 \
  https://raw.githubusercontent.com/ochenstarik-ui/lightweight-server/main/ochenstarik-server-install.sh
chmod 700 ochenstarik-server-install.sh
sudo ./ochenstarik-server-install.sh
```

A primeira pergunta seleciona o idioma do instalador; English é o padrão. Depois, cada uma das oito etapas pode ser instalada, ignorada ou usada para sair.

## Etapas

1. Fuso horário, idioma do terminal, programas recomendados e swap.
2. Pacotes básicos, porta SSH, IPv4/IPv6 e UFW.
3. Administrador, chave SSH, permissões, sudo e fail2ban.
4. Notificações Telegram para logins SSH.
5. VPN do sistema por Xray.
6. Painel 3x-ui e proxy local Cloudflare WARP.
7. Snapshot inicial e backups diários, semanais ou mensais.
8. Agentes de IA opcionais: Hermes, OpenClaw, OpenHands, OpenCode ou Aider.

Não feche a sessão SSH atual durante a alteração da porta. Teste primeiro o novo login em outro terminal. Consulte a [documentação principal em inglês](../../README.md) para obter detalhes adicionais.
