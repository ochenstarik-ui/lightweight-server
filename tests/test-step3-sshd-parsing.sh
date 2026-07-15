#!/usr/bin/env bash
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source <(awk '/^\[\[ "\$EUID"/{exit} {print}' ochenstarik-server-user-3.sh)

effective_config=$'port 20202\npermitrootlogin no\npasswordauthentication no\npubkeyauthentication yes'

[[ "$(read_sshd_setting port "$effective_config")" == 20202 ]]
[[ "$(read_sshd_setting permitrootlogin "$effective_config")" == no ]]
[[ "$(read_sshd_setting passwordauthentication "$effective_config")" == no ]]

if grep -E 'sshd[[:space:]]+-T[[:space:]]*\|' ochenstarik-server-user-3.sh; then
  printf 'Unsafe sshd -T pipeline found.\n' >&2
  exit 1
fi

printf 'Step 3 SSH configuration parsing tests passed.\n'
