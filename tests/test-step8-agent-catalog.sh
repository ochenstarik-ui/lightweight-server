#!/usr/bin/env bash
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source <(awk '/^\[\[ "\$EUID"/{exit} {print}' ochenstarik-server-ai-agents-8.sh)

[[ "${#AGENT_IDS[@]}" == 7 ]]
[[ "${AGENT_IDS[*]}" == 'hermes openclaw openhands opencode aider autogpt pi' ]]

expected_urls=(
  'https://hermes-agent.nousresearch.com/install.sh'
  'https://openclaw.ai/install.sh'
  'https://install.openhands.dev/install.sh'
  'https://opencode.ai/install'
  'https://aider.chat/install.sh'
  'https://setup.agpt.co/install.sh'
  'https://pi.dev/install.sh'
)

for index in "${!expected_urls[@]}"; do
  [[ "${AGENT_INSTALL_URLS[index]}" == "${expected_urls[index]}" ]]
done

select_agents <<< '1 3 5 6 7' >/dev/null
[[ "${SELECTED_INDEXES[*]}" == '0 2 4 5 6' ]]
select_agents <<< '' >/dev/null
[[ "${#SELECTED_INDEXES[@]}" == 0 ]]

if grep -E 'curl[^|]*\|[[:space:]]*(ba)?sh' ochenstarik-server-ai-agents-8.sh; then
  printf 'Direct curl-to-shell execution found.\n' >&2
  exit 1
fi

printf 'Step 8 AI agent catalog tests passed.\n'
