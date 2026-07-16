#!/usr/bin/env bash
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source <(awk '/^\[\[ "\$EUID"/{exit} {print}' ochenstarik-server-vpn-5.sh)

ACTION=""
select_existing_action <<< '' >/dev/null
[[ "$ACTION" == enable ]]

for pair in '1 enable' '2 disable' '3 reconfigure' '4 status'; do
  read -r input expected <<< "$pair"
  ACTION=""
  select_existing_action <<< "$input" >/dev/null
  [[ "$ACTION" == "$expected" ]]
done

for option in --enable --disable --reconfigure --status; do
  grep -Fq -- "$option" ochenstarik-server-vpn-5.sh
done

printf 'Step 5 repeated-run action tests passed.\n'
