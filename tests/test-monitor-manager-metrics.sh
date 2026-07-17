#!/usr/bin/env bash
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
script="ochenstarik-server-monitor-manager.sh"

for key in \
  SWAP_TOTAL_KB SWAP_FREE_KB \
  DISK_INODES_TOTAL DISK_INODES_FREE \
  NETWORK_RX_BYTES NETWORK_TX_BYTES \
  SYSTEMD_SSH SYSTEMD_WIREGUARD; do
  grep -Fq "$key" "$script"
done

printf 'Server Monitor Manager extended metrics checks passed.\n'
