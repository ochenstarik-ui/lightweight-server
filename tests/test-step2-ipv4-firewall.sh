#!/usr/bin/env bash
set -Eeuo pipefail

script_path="${1:-ochenstarik-server-2.sh}"

[[ -f "$script_path" ]] || {
  printf '[x] Missing script: %s\n' "$script_path" >&2
  exit 1
}

if grep -q 'disable_ipv6 = 1' "$script_path"; then
  printf '[x] Step 2 must not disable the IPv6 kernel stack for IPv4 mode\n' >&2
  exit 1
fi

if grep -q 'disable_ipv6_systemwide' "$script_path"; then
  printf '[x] Step 2 still references the old system-wide IPv6 disable helper\n' >&2
  exit 1
fi

if ! grep -q 'restore_ipv6_stack_if_managed' "$script_path"; then
  printf '[x] Step 2 should restore IPv6 when a legacy managed sysctl file exists\n' >&2
  exit 1
fi

ipv4_block="$(
  awk '
    /if \[\[ "\$IP_MODE" == ipv4 \]\]; then/ { capture=1 }
    capture { print }
    capture && /^  else$/ { exit }
  ' "$script_path"
)"

if [[ "$ipv4_block" != *'set_ufw_ipv6_setting yes'* ]]; then
  printf '[x] IPv4 mode must keep UFW IPv6 support enabled so deny incoming applies to IPv6\n' >&2
  exit 1
fi

if [[ "$ipv4_block" != *'delete_managed_ufw_rules'* ]]; then
  printf '[x] IPv4 mode must delete old managed IPv6 allow rules before applying IPv4-only rules\n' >&2
  exit 1
fi

printf '[+] Step 2 IPv4 firewall behavior looks correct\n'
