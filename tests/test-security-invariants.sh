#!/usr/bin/env bash
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

if grep -q 'REPO_RAW_BASE' ochenstarik-server-install.sh ||
   grep -q 'raw.githubusercontent.com/ochenstarik-ui/lightweight-server/main' ochenstarik-server-install.sh; then
  printf '[x] Master installer must not fetch missing modules from mutable main\n' >&2
  exit 1
fi

if grep -q 'source "$CONFIG_FILE"' ochenstarik-server-backup-7.sh; then
  printf '[x] Backup runner must parse config keys instead of sourcing root config\n' >&2
  exit 1
fi

if grep -Eq 'bash -c .*source|source "\$1"' ochenstarik-server-uninstall.sh; then
  printf '[x] Uninstaller must parse backup config keys instead of sourcing root config\n' >&2
  exit 1
fi

if ! grep -q 'XUI_PUBLIC_ACCESS=no' ochenstarik-server-panel-warp-6.sh; then
  printf '[x] 3x-ui panel must be private by default\n' >&2
  exit 1
fi

if ! grep -q 'Приватный режим' ochenstarik-server-panel-warp-6.sh; then
  printf '[x] Step 6 must offer a private access mode for 3x-ui\n' >&2
  exit 1
fi

printf '[+] Security invariants look correct\n'
