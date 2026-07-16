# Lightweight Ubuntu Server Setup

**English** | [Русский](docs/readme/README.ru.md) | [Español](docs/readme/README.es.md) | [Deutsch](docs/readme/README.de.md) | [Français](docs/readme/README.fr.md) | [Português](docs/readme/README.pt.md) | [中文](docs/readme/README.zh-CN.md) | [日本語](docs/readme/README.ja.md) | [العربية](docs/readme/README.ar.md) | [हिन्दी](docs/readme/README.hi.md)

A modular set of Bash installers for the initial setup, security hardening, administration, VPN, web panel, WARP, and backups on Ubuntu Server. Run the unified wizard for a guided installation or execute only the modules you need.

> **Manage multiple servers:** use the companion [Server Monitor Manager](https://github.com/ochenstarik-ui/server-monitor-manager) project to add servers, collect reports, and manage several hosts from one application. It is currently in early development and should not yet be treated as production-ready.

## Quick installation

Copy the complete block into the server terminal. It downloads the repository archive through `codeload.github.com`, stops on errors, and starts the unified installer:

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

The first wizard prompt selects the dialog language. English is the default; Russian, Spanish, German, French, Portuguese, Simplified Chinese, Japanese, Arabic, and Hindi are also available. The wizard then presents steps 1–8 in order. Each step can be installed, skipped, or used to exit the wizard.

Keep the current SSH session open while changing the SSH port. Test the new login in a second terminal before disconnecting.

## Short wizard-only installation

If `raw.githubusercontent.com` is reachable from the server:

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

The wizard downloads any missing module from the `main` branch and validates it with `bash -n` before execution.

## Modules

| Script | Purpose | Standalone use |
| --- | --- | --- |
| `ochenstarik-server-install.sh` | Unified wizard with language selection and sequential module installation | Recommended |
| `ochenstarik-server-1.sh` | Timezone, terminal locale, program groups, and a 2 GiB swap file | Yes |
| `ochenstarik-server-2.sh` | Base packages, SSH port, IPv4/IPv6 mode, UFW, and port management | Yes |
| `ochenstarik-server-user-3.sh` | Administrative user, SSH key permissions, SSH migration, sudo, and fail2ban | Run after step 2 |
| `ochenstarik-server-tg-4.sh` | Telegram notifications for successful SSH logins | Optional |
| `ochenstarik-server-vpn-5.sh` | System VPN through Xray; repeated runs can connect, disconnect, reconfigure, or show status | Optional |
| `ochenstarik-server-panel-warp-6.sh` | 3x-ui panel and local Cloudflare WARP proxy | Optional |
| `ochenstarik-server-backup-7.sh` | Protected initial snapshot and selected daily, weekly, or monthly schedules | Optional |
| `ochenstarik-server-ai-agents-8.sh` | Installs selected AI agents: Hermes, OpenClaw, OpenHands, OpenCode, Aider, AutoGPT, or Pi Coding Agent | Optional |
| `ochenstarik-server-monitor-manager.sh` | Installs the Server Monitor Manager SSH endpoint, public WireGuard Hub, or outbound-only Node | Optional; Hub needs a public UDP endpoint |
| `ochenstarik-server-uninstall.sh` | Removes project-managed settings so installation can start again | Use carefully |

Every module can be downloaded and run independently:

```bash
curl -fLO https://raw.githubusercontent.com/ochenstarik-ui/lightweight-server/main/SCRIPT_NAME.sh
chmod 700 SCRIPT_NAME.sh
bash -n SCRIPT_NAME.sh
sudo ./SCRIPT_NAME.sh
```

Replace `SCRIPT_NAME.sh` with the required filename from the table.

## Server Monitor Manager Hub and Nodes

The Hub needs a public IPv4 address or domain and an open UDP port (default `51820`). Secondary Nodes establish outbound WireGuard connections and do not need a public IP.

```bash
curl -fLO https://raw.githubusercontent.com/ochenstarik-ui/lightweight-server/main/ochenstarik-server-monitor-manager.sh
chmod 700 ochenstarik-server-monitor-manager.sh
bash -n ochenstarik-server-monitor-manager.sh
sudo ./ochenstarik-server-monitor-manager.sh hub
```

Create a separate 10-minute enrollment code for each Node on the Hub, then run the same installer with `node` on the matching server:

```bash
sudo ochenstarik-smm node-code ai-agent
sudo ochenstarik-smm node-code home
sudo ./ochenstarik-server-monitor-manager.sh node
```

Links are directional. The reverse direction requires its own rule:

```bash
sudo ochenstarik-smm link-connect ai-agent home tcp 22 120
sudo ochenstarik-smm link-disconnect ai-agent home tcp 22
sudo ochenstarik-smm nodes
sudo ochenstarik-smm links
```

The Node installer creates its private WireGuard key locally and prints an `SMMREQ1` request. In a second terminal run `sudo ochenstarik-smm node-enroll` on the Hub, paste the request at the hidden prompt, and return the resulting `SMMACK1` code to the Node installer. The enrollment code expires after 10 minutes and is consumed by the first successful registration.

Role-aware maintenance commands create a root-only backup before destructive changes:

```bash
sudo ./ochenstarik-server-monitor-manager.sh update
sudo ./ochenstarik-server-monitor-manager.sh rollback
sudo ./ochenstarik-server-monitor-manager.sh uninstall-node
sudo ./ochenstarik-server-monitor-manager.sh uninstall-hub
sudo ./ochenstarik-server-monitor-manager.sh uninstall-monitor
```

## Installation flow

1. Select the wizard dialog language.
2. Configure the timezone, terminal locale, recommended tools, and swap.
3. Select IPv4, IPv6, or dual-stack operation; install base services and select the future SSH port.
4. Create or update the administrative user, install the public SSH key, repair ownership and permissions, and move SSH to the port selected in step 2.
5. Optionally configure Telegram SSH-login notifications.
6. Optionally configure the system VPN and subscription port.
7. Optionally deploy 3x-ui and Cloudflare WARP with selected panel and subscription ports.
8. Optionally create the permanent initial backup and configure rotating schedules.
9. Optionally install one or more AI agents for the administrative user.

## VPN connection control

After the first successful setup, running `ochenstarik-server-vpn-5.sh` again opens an action menu: connect using saved settings, disconnect while keeping the configuration, replace the subscription, or show status. The same actions are available directly:

```bash
sudo ./ochenstarik-server-vpn-5.sh --enable
sudo ./ochenstarik-server-vpn-5.sh --disable
sudo ./ochenstarik-server-vpn-5.sh --reconfigure
sudo ./ochenstarik-server-vpn-5.sh --status
```

Disconnecting removes the system routing rules but keeps Xray and its configuration so the VPN can be reconnected without entering the subscription again.

## Optional AI agents

Step 8 offers a multiple selection of seven popular agents: Hermes Agent, OpenClaw, OpenHands, OpenCode, Aider, AutoGPT, and Pi Coding Agent. Installers are downloaded only from each project's official HTTPS endpoint, checked with `bash -n`, and launched as the selected regular user rather than directly as `root`.

AutoGPT is a larger Docker-based platform. Its official installer can request `sudo`, install Docker-related dependencies, and start local services. Pi is a lightweight terminal coding agent; after installation, start it with `pi` and use `/login` to connect a supported provider.

The script does not request or store model-provider API keys. After installation, log in as the selected user and run the displayed onboarding command. AI agents can execute commands, access files, install plugins, and use network services; review their permissions and sandbox settings before connecting production data or secrets.

## Firewall and SSH notes

- Step 2 supports IPv4-only, IPv6-only, and dual-stack UFW rules. IPv4-only mode blocks public inbound IPv6 through UFW without disabling the kernel IPv6 stack.
- A repeated step 2 run can change the IP-family mode or add ports without reinstalling everything.
- Step 3 reads the SSH port chosen in step 2 and creates an administrator with sudo access.
- The home directory, `.ssh`, and `authorized_keys` ownership and permissions are checked on every run.
- Do not remove temporary port 22 access until a new SSH session succeeds on the selected port.

## Backups

Step 7 can create:

- one initial snapshot that is never rotated automatically;
- daily backups retained for 7 days;
- weekly backups retained for 4 weeks;
- monthly backups retained for 12 months.

Schedules are selected independently, so any combination can be enabled. Keep an additional copy on another server or storage device; a local backup does not protect against loss of the entire host.

## Multi-server monitoring and management

[Server Monitor Manager](https://github.com/ochenstarik-ui/server-monitor-manager) is the companion project for centralized server operations. Its planned architecture includes:

- a Flutter client for Android and iOS;
- an ASP.NET Core API with accounts, TOTP two-factor authentication, and SignalR;
- an outbound Linux agent for metrics and managed operations;
- support for adding and monitoring multiple servers from one application.

The manager is under active early development. Review its security and development documentation before connecting real production servers.

## Requirements

- Ubuntu Server with systemd and APT;
- root access through `sudo`;
- an active SSH session;
- outbound HTTPS access to GitHub or GitHub codeload;
- a valid public SSH key for the administrator setup.

## Update

For a Git clone:

```bash
cd ~/lightweight-server
git pull
sudo ./ochenstarik-server-install.sh
```

## Reset project-managed configuration

```bash
cd ~/lightweight-server
sudo ./ochenstarik-server-uninstall.sh
```

Read every confirmation carefully. The reset script preserves critical Ubuntu packages and avoids removing access until explicitly confirmed.
