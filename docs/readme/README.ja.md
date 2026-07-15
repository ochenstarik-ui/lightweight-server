# Ubuntu Server クイックセットアップ

[English](../../README.md) | [Русский](README.ru.md) | [Español](README.es.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Português](README.pt.md) | [中文](README.zh-CN.md) | **日本語** | [العربية](README.ar.md) | [हिन्दी](README.hi.md)

Ubuntu Server の初期設定、セキュリティ、SSH、VPN、3x-ui、WARP、バックアップを行うモジュール式 Bash スクリプトです。

> 複数のサーバーを一つのアプリで監視・管理するには、[Server Monitor Manager](https://github.com/ochenstarik-ui/server-monitor-manager) を使用してください。このプロジェクトは現在、開発の初期段階です。

## クイックインストール

```bash
sudo apt-get update
sudo apt-get install -y curl ca-certificates
curl -4 -fLO --retry 5 --retry-delay 10 --connect-timeout 30 \
  https://raw.githubusercontent.com/ochenstarik-ui/lightweight-server/main/ochenstarik-server-install.sh
chmod 700 ochenstarik-server-install.sh
sudo ./ochenstarik-server-install.sh
```

最初の質問でインストーラーの言語を選択します。既定値は English です。その後、7 つの各ステップを実行、スキップ、または終了できます。

## ステップ

1. タイムゾーン、端末言語、推奨プログラム、スワップ。
2. 基本パッケージ、SSH ポート、IPv4/IPv6、UFW。
3. 管理者、SSH 鍵、アクセス権、sudo、fail2ban。
4. SSH ログインの Telegram 通知。
5. Xray によるシステム VPN。
6. 3x-ui パネルとローカル Cloudflare WARP プロキシ。
7. 初回スナップショットと日次、週次、月次バックアップ。

SSH ポートの変更中は現在のセッションを閉じないでください。別のターミナルで新しい接続を先に確認してください。詳細は[英語のメイン文書](../../README.md)を参照してください。
