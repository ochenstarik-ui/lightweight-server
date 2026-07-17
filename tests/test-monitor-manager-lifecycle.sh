#!/usr/bin/env bash
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
script="ochenstarik-server-monitor-manager.sh"

[[ -s "$script" ]]
grep -Fq 'sudo' "$script"
grep -Fq 'iputils-ping' "$script"
grep -Fq 'backup_state()' "$script"
grep -Fq 'rollback_state()' "$script"
grep -Fq 'update_installed()' "$script"
grep -Fq 'uninstall_monitor()' "$script"
grep -Fq 'uninstall_node()' "$script"
grep -Fq 'uninstall_hub()' "$script"
grep -Fq '/var/backups/${APP_NAME}' "$script"
grep -Fq 'systemctl disable --now ochenstarik-smm-firewall.timer' "$script"
grep -Fq 'nft delete table inet ochenstarik_smm' "$script"
grep -Fq 'sysctl --system' "$script"
grep -Fq 'uninstall) die "Укажите роль:' "$script"

printf 'Server Monitor Manager lifecycle checks passed.\n'
