#!/usr/bin/env bash
set -Eeuo pipefail

readonly CONFIG_DIR="/etc/ochenstarik-server"
readonly AGENT_CONFIG="${CONFIG_DIR}/ai-agents.conf"
readonly STEP3_ENV="/root/setup-data/env.txt"

readonly -a AGENT_IDS=(hermes openclaw openhands opencode aider)
readonly -a AGENT_NAMES=(
  "Hermes Agent"
  "OpenClaw"
  "OpenHands"
  "OpenCode"
  "Aider"
)
readonly -a AGENT_DESCRIPTIONS=(
  "Personal self-improving agent with memory, skills, schedules, and messaging gateways"
  "Personal assistant with persistent memory and Telegram, WhatsApp, Discord, Slack, and other channels"
  "Software-development agent with terminal, headless, web, and IDE modes"
  "Terminal coding agent with multiple model providers and parallel sessions"
  "Git-oriented coding agent for editing and reviewing an existing repository"
)
readonly -a AGENT_INSTALL_URLS=(
  "https://hermes-agent.nousresearch.com/install.sh"
  "https://openclaw.ai/install.sh"
  "https://install.openhands.dev/install.sh"
  "https://opencode.ai/install"
  "https://aider.chat/install.sh"
)
readonly -a AGENT_COMMANDS=(hermes openclaw openhands opencode aider)
readonly -a AGENT_SETUP_HINTS=(
  "hermes setup"
  "openclaw onboard --install-daemon"
  "openhands"
  "opencode"
  "aider"
)

TEMP_INSTALLER=""

log() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [[ -n "$TEMP_INSTALLER" && "$TEMP_INSTALLER" == /tmp/ochenstarik-ai-installer.* \
    && -f "$TEMP_INSTALLER" && ! -L "$TEMP_INSTALLER" ]]; then
    rm -f -- "$TEMP_INSTALLER"
  fi
}
trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

default_target_user() {
  local username=""
  if [[ -f "$STEP3_ENV" && ! -L "$STEP3_ENV" ]]; then
    username="$(awk -F= '$1 == "NEW_USERNAME" && !found { sub(/\r$/, "", $2); print $2; found=1 }' "$STEP3_ENV")"
    if [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && id "$username" >/dev/null 2>&1; then
      printf '%s' "$username"
      return 0
    fi
  fi
  getent passwd | awk -F: '$3 >= 1000 && $3 != 65534 && $1 != "nobody" && !found { print $1; found=1 }'
}

select_target_user() {
  local default_user username uid home owner
  default_user="$(default_target_user)"

  printf '\nAI agents must be installed for a regular user, never for root.\n'
  while :; do
    if [[ -n "$default_user" ]]; then
      read -rp "Installation user [${default_user}]: " username || die "Input was interrupted"
      username="${username:-$default_user}"
    else
      read -rp 'Installation user: ' username || die "Input was interrupted"
    fi

    [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { warn "Invalid username"; continue; }
    [[ "$username" != root ]] || { warn "Root cannot be used for AI agents"; continue; }
    id "$username" >/dev/null 2>&1 || { warn "User does not exist: $username"; continue; }
    uid="$(id -u "$username")"
    ((uid >= 1000 && uid != 65534)) || { warn "System accounts are not allowed"; continue; }
    home="$(getent passwd "$username" | cut -d: -f6)"
    [[ -n "$home" && "$home" == /* && -d "$home" && ! -L "$home" ]] \
      || { warn "A safe home directory was not found for $username"; continue; }
    owner="$(stat -c %U "$home")"
    [[ "$owner" == "$username" ]] || { warn "$home must be owned by $username"; continue; }

    TARGET_USER="$username"
    TARGET_HOME="$home"
    TARGET_GROUP="$(id -gn "$username")"
    return 0
  done
}

select_agents() {
  local input token index
  local -A seen=()
  SELECTED_INDEXES=()

  printf '\nSelect one or more AI agents to install:\n'
  for index in "${!AGENT_IDS[@]}"; do
    printf '  %d) %s\n     %s\n     Official installer: %s\n' \
      "$((index + 1))" "${AGENT_NAMES[index]}" "${AGENT_DESCRIPTIONS[index]}" \
      "${AGENT_INSTALL_URLS[index]}"
  done
  printf '  0) Do not install AI agents\n'
  printf '\nEnter numbers separated by spaces, for example: 1 2 4.\n'

  while :; do
    read -rp 'Selection [0]: ' input || die "Input was interrupted"
    input="${input//,/ }"
    input="${input:-0}"
    if [[ "$input" =~ ^[[:space:]]*0[[:space:]]*$ ]]; then
      return 0
    fi

    SELECTED_INDEXES=()
    seen=()
    for token in $input; do
      if [[ ! "$token" =~ ^[1-5]$ ]]; then
        warn "Enter agent numbers from 1 to 5, or 0 to skip"
        SELECTED_INDEXES=()
        break
      fi
      index="$((token - 1))"
      if [[ -z "${seen[$index]:-}" ]]; then
        SELECTED_INDEXES+=("$index")
        seen["$index"]=1
      fi
    done
    ((${#SELECTED_INDEXES[@]} > 0)) && return 0
  done
}

install_agent() {
  local index="$1" name url command_name path_value
  name="${AGENT_NAMES[index]}"
  url="${AGENT_INSTALL_URLS[index]}"
  command_name="${AGENT_COMMANDS[index]}"
  path_value="${TARGET_HOME}/.local/bin:${TARGET_HOME}/.opencode/bin:${TARGET_HOME}/.hermes/bin:${TARGET_HOME}/.local/share/pnpm:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

  log "Downloading the official ${name} installer"
  TEMP_INSTALLER="$(mktemp /tmp/ochenstarik-ai-installer.XXXXXX)"
  chmod 600 "$TEMP_INSTALLER"
  curl -fL --retry 5 --retry-delay 5 --connect-timeout 30 \
    --proto '=https' --tlsv1.2 "$url" -o "$TEMP_INSTALLER"
  [[ -s "$TEMP_INSTALLER" && ! -L "$TEMP_INSTALLER" ]] \
    || die "The downloaded ${name} installer is empty or unsafe"
  bash -n "$TEMP_INSTALLER" || die "The official ${name} installer failed Bash syntax validation"

  chown "$TARGET_USER:$TARGET_GROUP" "$TEMP_INSTALLER"
  chmod 500 "$TEMP_INSTALLER"
  log "Installing ${name} for ${TARGET_USER}"
  runuser -u "$TARGET_USER" -- env \
    HOME="$TARGET_HOME" USER="$TARGET_USER" LOGNAME="$TARGET_USER" SHELL=/bin/bash PATH="$path_value" \
    bash "$TEMP_INSTALLER"

  rm -f -- "$TEMP_INSTALLER"
  TEMP_INSTALLER=""

  if runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" PATH="$path_value" \
    bash -lc "command -v '$command_name' >/dev/null 2>&1"; then
    log "${name} command is available: ${command_name}"
  else
    warn "${name} installer completed, but ${command_name} is not visible in a new login shell yet"
    warn "Log in again or reload the user's shell configuration before running it"
  fi
}

write_state() {
  local ids="" index
  install -d -m 700 -o root -g root "$CONFIG_DIR"
  [[ ! -L "$AGENT_CONFIG" ]] || die "$AGENT_CONFIG must not be a symbolic link"
  for index in "${SELECTED_INDEXES[@]}"; do
    ids+="${ids:+ }${AGENT_IDS[index]}"
  done
  umask 077
  printf 'TARGET_USER=%s\nAGENTS=%s\n' "$TARGET_USER" "$ids" > "$AGENT_CONFIG"
  chown root:root "$AGENT_CONFIG"
  chmod 600 "$AGENT_CONFIG"
}

[[ "$EUID" -eq 0 ]] || die "Run this script as root"
require_command awk
require_command apt-get
require_command bash
require_command getent
require_command runuser
require_command stat

((${#AGENT_IDS[@]} == 5 && ${#AGENT_NAMES[@]} == 5 \
  && ${#AGENT_DESCRIPTIONS[@]} == 5 && ${#AGENT_INSTALL_URLS[@]} == 5 \
  && ${#AGENT_COMMANDS[@]} == 5 && ${#AGENT_SETUP_HINTS[@]} == 5)) \
  || die "Invalid AI agent catalog"

select_target_user
select_agents
if ((${#SELECTED_INDEXES[@]} == 0)); then
  log "AI agent installation was skipped"
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl ca-certificates git
require_command curl

printf '\nThe selected agents can execute commands, access files, and use network services.\n'
printf 'Review permissions, tools, plugins, mounted directories, and API-key access during onboarding.\n'
read -rp "Type INSTALL to continue for user ${TARGET_USER}: " confirmation || die "Input was interrupted"
[[ "$confirmation" == INSTALL ]] || die "AI agent installation was cancelled"

for selected_index in "${SELECTED_INDEXES[@]}"; do
  install_agent "$selected_index"
done
write_state

printf '\nInstalled AI agents for %s:\n' "$TARGET_USER"
for selected_index in "${SELECTED_INDEXES[@]}"; do
  printf '  - %s\n    Next step: %s\n' \
    "${AGENT_NAMES[selected_index]}" "${AGENT_SETUP_HINTS[selected_index]}"
done
printf '\nRun the setup commands while logged in as %s, not as root.\n' "$TARGET_USER"
printf 'API keys are managed by each agent and were not requested or stored by this script.\n'
