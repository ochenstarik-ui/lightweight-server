# Ubuntu Server 快速配置

[English](../../README.md) | [Русский](README.ru.md) | [Español](README.es.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Português](README.pt.md) | **中文** | [日本語](README.ja.md) | [العربية](README.ar.md) | [हिन्दी](README.hi.md)

一组模块化 Bash 脚本，用于 Ubuntu Server 的初始配置、安全加固、SSH、VPN、3x-ui、WARP 和备份。

> 如需在一个应用中监控并统一管理多台服务器，请使用 [Server Monitor Manager](https://github.com/ochenstarik-ui/server-monitor-manager)。该项目目前仍处于早期开发阶段。

## 快速安装

```bash
sudo apt-get update
sudo apt-get install -y curl ca-certificates
curl -4 -fLO --retry 5 --retry-delay 10 --connect-timeout 30 \
  https://raw.githubusercontent.com/ochenstarik-ui/lightweight-server/main/ochenstarik-server-install.sh
chmod 700 ochenstarik-server-install.sh
sudo ./ochenstarik-server-install.sh
```

安装程序的第一个问题用于选择界面语言，默认是 English。随后八个步骤都可以运行、跳过或用于退出安装程序。

## 安装步骤

1. 时区、终端语言、推荐程序和交换文件。
2. 基础软件包、SSH 端口、IPv4/IPv6 和 UFW。
3. 管理员、SSH 密钥、权限、sudo 和 fail2ban。
4. SSH 登录的 Telegram 通知。
5. 通过 Xray 配置系统 VPN。
6. 3x-ui 面板和本地 Cloudflare WARP 代理。
7. 初始快照以及每日、每周或每月备份。
8. 可选 AI 代理：Hermes、OpenClaw、OpenHands、OpenCode、Aider、AutoGPT 或 Pi Coding Agent。

更改 SSH 端口时不要关闭当前会话。请先在另一个终端中测试新连接。更多说明请参阅[英文主文档](../../README.md)。
