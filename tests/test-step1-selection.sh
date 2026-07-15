#!/usr/bin/env bash
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source <(awk '/^\[\[ "\$EUID"/{exit} {print}' ochenstarik-server-1.sh)

declare -a MOCK_APT_PACKAGES=()
MOCK_LOCALE=""
MOCK_UPDATE_LOCALE=""

ensure_apt_updated() { :; }
apt-cache() { return 0; }
package_is_installed() { return 1; }
record_new_packages() { :; }
save_original_locale() { :; }

apt-get() {
  [[ "${1:-}" == install ]] || return 0
  shift
  [[ "${1:-}" != -y ]] || shift
  MOCK_APT_PACKAGES=("$@")
}

locale-gen() { MOCK_LOCALE="$1"; }
update-locale() { MOCK_UPDATE_LOCALE="$*"; }

contains_package() {
  local expected="$1" package_name
  for package_name in "${MOCK_APT_PACKAGES[@]}"; do
    [[ "$package_name" != "$expected" ]] || return 0
  done
  return 1
}

declare -a EXPECTED_UI_LANGUAGES=(en ru es de fr pt zh ja ar hi)
for index in "${!EXPECTED_UI_LANGUAGES[@]}"; do
  choose_ui_language <<< "$((index + 1))" >/dev/null
  [[ "$UI_LANG" == "${EXPECTED_UI_LANGUAGES[index]}" ]]
done
choose_ui_language <<< '' >/dev/null
[[ "$UI_LANG" == en ]]

choose_and_install_programs <<< '1 3' >/dev/null
contains_package git
contains_package iotop
! contains_package nmap
! contains_package ffmpeg

MOCK_APT_PACKAGES=()
choose_and_install_programs <<< '' >/dev/null
contains_package nmap
contains_package ffmpeg
contains_package restic
contains_package postgresql-client

MOCK_APT_PACKAGES=()
choose_and_install_programs <<< '0' >/dev/null
((${#MOCK_APT_PACKAGES[@]} == 0))

choose_terminal_language <<< '2' >/dev/null
[[ "$MOCK_LOCALE" == ru_RU.UTF-8 ]]
[[ "$MOCK_UPDATE_LOCALE" == *'LANG=ru_RU.UTF-8'* ]]
[[ "$MOCK_UPDATE_LOCALE" == *'LANGUAGE=ru_RU:ru'* ]]

printf 'Step 1 selection tests passed.\n'
