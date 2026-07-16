#!/usr/bin/env bash
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
script="ochenstarik-server-monitor-manager.sh"

[[ -s "$script" ]]
grep -Fq 'readonly SMM_RELEASE_VERSION=' "$script"
grep -Fq 'server-monitor-manager-${runtime}.tar.gz' "$script"
grep -Fq 'sha256sum "$archive"' "$script"
grep -Fq 'SMMCTL1-' "$script"
grep -Fq 'control-code)' "$script"
grep -Fq 'install-control-hub)' "$script"
grep -Fq 'install-control-agent)' "$script"
grep -Fq 'NoNewPrivileges=true' "$script"
grep -Fq 'ProtectSystem=strict' "$script"
grep -Fq 'SMM_EnrollToken=${token}' "$script"
grep -Fq 'systemctl enable --now ochenstarik-smm-control.service' "$script"
grep -Fq 'systemctl enable --now ochenstarik-smm-agent.service' "$script"

if grep -Eq 'CONTROL_JOIN_CODE=.*(ca\.key|control-ca\.pfx)' "$script"; then
  echo 'Control join code must never contain the CA private key.' >&2
  exit 1
fi

printf 'Server Monitor Manager control-layer installer checks passed.\n'
