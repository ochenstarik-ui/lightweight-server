#!/usr/bin/env bash
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source <(awk '/^\[\[ "\$EUID"/{exit} {print}' ochenstarik-server-install.sh)

declare -a expected=(en ru es de fr pt zh ja ar hi)
for index in "${!expected[@]}"; do
  choose_dialog_language <<< "$((index + 1))" >/dev/null
  [[ "$UI_LANG" == "${expected[index]}" ]]
  [[ "$OCHENSTARIK_UI_LANG" == "${expected[index]}" ]]
done

choose_dialog_language <<< '' >/dev/null
[[ "$UI_LANG" == en ]]
[[ "$(master_msg install)" == 'Install / run this step' ]]

choose_dialog_language <<< '2' >/dev/null
[[ "$(master_msg install)" == 'Установить / запустить этот этап' ]]
[[ "${STEP_TITLES[0]}" == 'Часовой пояс, язык терминала, программы и swap' ]]
[[ "${#STEP_FILES[@]}" == 8 ]]
[[ "${#STEP_TITLES[@]}" == 8 ]]
[[ "${STEP_FILES[7]}" == 'ochenstarik-server-ai-agents-8.sh' ]]
[[ "${STEP_TITLES[7]}" == 'AI-агенты на выбор для обычного пользователя' ]]

printf 'Master language selection tests passed.\n'
