#!/usr/bin/env bash
set -Eeuo pipefail

readonly ENV_FILE="${ENV_FILE:-/root/setup-data/env.txt}"
readonly HASH_FILE="${HASH_FILE:-/root/setup-data/password.hash}"
readonly SSHD_DROPIN="/etc/ssh/sshd_config.d/00-hermes-hardening.conf"
readonly FAIL2BAN_JAIL="/etc/fail2ban/jail.d/hermes.local"
readonly SSH_PORT_CONFIG="/etc/ochenstarik-server/ssh-port.conf"
readonly IP_FAMILY_CONFIG="/etc/ochenstarik-server/ip-family.conf"
readonly MANAGED_PORTS_CONFIG="/etc/ochenstarik-server/ufw-managed-ports.conf"

log() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

backup_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  cp -a -- "$file" "${file}.bak.$(date +%F-%H%M%S-%N)"
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

read_env_value() {
  local key="$1" line value
  line="$(grep -m1 -E "^[[:space:]]*${key}[[:space:]]*=" "$ENV_FILE" || true)"
  [[ -n "$line" ]] || return 0
  line="${line//$'\r'/}"
  value="$(trim "${line#*=}")"

  if (( ${#value} >= 2 )); then
    if [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
      value="${value:1:${#value}-2}"
    fi
  fi

  printf '%s' "$value" | tr -d '\r'
}

require_regular_root_file() {
  local file="$1"
  [[ -f "$file" && ! -L "$file" ]] || die "Required regular file not found: $file"
  [[ "$(stat -c '%u' "$file")" == 0 ]] || die "$file must be owned by root"
  chmod 600 -- "$file"
}

validate_boolean() {
  local name="$1" value="$2"
  [[ "$value" == yes || "$value" == no ]] || die "$name must be 'yes' or 'no'"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

is_valid_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
  (( 10#$port >= 1 && 10#$port <= 65535 ))
}

read_ip_mode() {
  local mode=both
  if [[ -e "$IP_FAMILY_CONFIG" ]]; then
    [[ -f "$IP_FAMILY_CONFIG" && ! -L "$IP_FAMILY_CONFIG" ]] \
      || die "$IP_FAMILY_CONFIG must be a regular file"
    mode="$(sed -n 's/^IP_MODE=//p' "$IP_FAMILY_CONFIG" | head -n1 | tr -d '\r')"
  fi
  case "$mode" in ipv4|ipv6|both) printf '%s' "$mode" ;; *) die "Invalid IP_MODE: $mode" ;; esac
}

record_managed_ufw_rule() {
  local rule="$1"
  install -d -m 700 -o root -g root "$(dirname "$MANAGED_PORTS_CONFIG")"
  [[ ! -L "$MANAGED_PORTS_CONFIG" ]] || die "$MANAGED_PORTS_CONFIG must not be a symbolic link"
  touch "$MANAGED_PORTS_CONFIG"
  grep -Fqx -- "$rule" "$MANAGED_PORTS_CONFIG" || printf '%s\n' "$rule" >> "$MANAGED_PORTS_CONFIG"
  chown root:root "$MANAGED_PORTS_CONFIG"
  chmod 600 "$MANAGED_PORTS_CONFIG"
}

allow_ufw_rule() {
  local rule="$1" mode port protocol
  mode="$(read_ip_mode)"
  port="${rule%/*}"
  protocol="${rule#*/}"
  record_managed_ufw_rule "$rule"
  if [[ "$mode" == ipv4 || "$mode" == both ]]; then
    ufw allow from 0.0.0.0/0 to any port "$port" proto "$protocol"
  fi
  if [[ "$mode" == ipv6 || "$mode" == both ]]; then
    ufw allow from ::/0 to any port "$port" proto "$protocol"
  fi
}

select_action() {
  local choice

  printf '\nSelect an action:\n'
  printf '  1 - new installation or reconfigure the administrative user and SSH\n'
  printf '  2 - add open ports to UFW without changing SSH or users\n'
  while :; do
    read -rp 'Select [1]: ' choice
    choice="${choice:-1}"
    case "$choice" in
      1)
        ACTION="install"
        return 0
        ;;
      2)
        ACTION="add-ports"
        return 0
        ;;
      *)
        warn "Select 1 or 2"
        ;;
    esac
  done
}

add_ufw_ports_interactive() {
  local input normalized token port protocol rule
  local -a tokens rules
  local -A seen

  require_command ufw
  printf '\nEnter one or more ports separated by spaces or commas.\n'
  printf 'TCP is used by default; specify UDP explicitly when needed.\n'
  printf 'Example: 80 443/tcp 53/udp 40000\n'

  while :; do
    read -rp 'Ports to open: ' input
    normalized="${input//,/ }"
    read -r -a tokens <<< "$normalized"
    rules=()
    seen=()

    if (( ${#tokens[@]} == 0 )); then
      warn "Enter at least one port"
      continue
    fi

    for token in "${tokens[@]}"; do
      if [[ ! "$token" =~ ^([0-9]+)(/(tcp|udp))?$ ]]; then
        warn "Invalid rule: $token; use PORT, PORT/tcp or PORT/udp"
        rules=()
        break
      fi

      port="${BASH_REMATCH[1]}"
      protocol="${BASH_REMATCH[3]:-tcp}"
      if ! is_valid_port "$port"; then
        warn "Port must be between 1 and 65535: $port"
        rules=()
        break
      fi
      port="$((10#$port))"

      rule="${port}/${protocol}"
      if [[ -z "${seen[$rule]:-}" ]]; then
        rules+=("$rule")
        seen["$rule"]=1
      fi
    done

    (( ${#rules[@]} > 0 )) && break
  done

  for rule in "${rules[@]}"; do
    log "Allowing ${rule} in UFW"
    allow_ufw_rule "$rule"
  done

  if ! LANG=C ufw status | grep -q '^Status: active'; then
    warn "UFW is inactive. Rules were added but the firewall was not enabled automatically."
    warn "Review SSH access first, then enable it with: ufw enable"
  fi

  printf '\nCurrent UFW status:\n'
  ufw status verbose
}

collect_user_configuration() {
  local new_username ssh_port default_ssh_port saved_ssh_port selected_step2_port
  local ssh_public_key pass pass2 candidate_uid
  local key_method source_username source_home source_key_file candidate_key key_test

  log "Collecting configuration for a new administrative user"
  while :; do
    read -rp 'New username: ' new_username
    if [[ ! "$new_username" =~ ^[a-z_][a-z0-9_-]{0,31}$ || "$new_username" == root ]]; then
      warn "Use 1-32 lowercase letters, digits, underscore or hyphen; root is not allowed"
      continue
    fi
    if id "$new_username" >/dev/null 2>&1; then
      candidate_uid="$(id -u "$new_username")"
      if (( candidate_uid < 1000 || candidate_uid == 65534 )); then
        warn "System account cannot be modified: $new_username"
        continue
      fi
      warn "User $new_username already exists; its password and SSH key will be updated"
    fi
    break
  done

  default_ssh_port="20202"
  if [[ -e "$SSH_PORT_CONFIG" ]]; then
    [[ -f "$SSH_PORT_CONFIG" && ! -L "$SSH_PORT_CONFIG" ]] \
      || die "$SSH_PORT_CONFIG must be a regular non-symlink file"
    selected_step2_port="$(sed -n 's/^SSH_PORT=//p' "$SSH_PORT_CONFIG" | head -n1 | tr -d '\r')"
    is_valid_port "$selected_step2_port" \
      || die "Invalid SSH port in $SSH_PORT_CONFIG"
    ssh_port="$((10#$selected_step2_port))"
    log "Using SSH port ${ssh_port} selected in step 2"
  elif [[ -f "$ENV_FILE" ]]; then
    saved_ssh_port="$(read_env_value SSH_PORT)"
    if is_valid_port "$saved_ssh_port"; then
      default_ssh_port="$saved_ssh_port"
    fi
  fi

  if [[ -z "${ssh_port:-}" ]]; then
    warn "The SSH port from step 2 was not found; select it now"
    while :; do
      read -rp "SSH port [${default_ssh_port}]: " ssh_port
      ssh_port="${ssh_port:-$default_ssh_port}"
      if is_valid_port "$ssh_port"; then
        ssh_port="$((10#$ssh_port))"
        break
      fi
      warn "SSH port must be a number between 1 and 65535"
    done
  fi

  while :; do
    printf '\nSSH key setup:\n'
    printf '  1 - copy a working key from an existing user (recommended)\n'
    printf '  2 - paste a public key manually\n'
    read -rp 'Select [1]: ' key_method
    key_method="${key_method:-1}"

    if [[ "$key_method" == 1 ]]; then
      read -rp 'Existing username [hermes]: ' source_username
      source_username="${source_username:-hermes}"

      if ! id "$source_username" >/dev/null 2>&1; then
        warn "User does not exist: $source_username"
        continue
      fi

      source_home="$(getent passwd "$source_username" | cut -d: -f6)"
      source_key_file="${source_home}/.ssh/authorized_keys"
      if [[ ! -f "$source_key_file" || -L "$source_key_file" ]]; then
        warn "A regular authorized_keys file was not found for $source_username"
        continue
      fi

      ssh_public_key=""
      key_test="$(mktemp)"
      chmod 600 "$key_test"
      while IFS= read -r candidate_key || [[ -n "$candidate_key" ]]; do
        candidate_key="${candidate_key//$'\r'/}"
        [[ -n "$candidate_key" && "$candidate_key" != \#* ]] || continue
        printf '%s\n' "$candidate_key" > "$key_test"
        if ssh-keygen -l -f "$key_test" >/dev/null 2>&1; then
          ssh_public_key="$candidate_key"
          break
        fi
      done < "$source_key_file"
      rm -f -- "$key_test"

      if [[ -z "$ssh_public_key" ]]; then
        warn "No valid SSH public key was found for $source_username"
        continue
      fi
      log "The SSH key was copied from user $source_username"
      break
    fi

    if [[ "$key_method" == 2 ]]; then
      read -rp "Paste the SSH public key for ${new_username}: " ssh_public_key
      if [[ "$ssh_public_key" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]]+[A-Za-z0-9+/]+={0,3}([[:space:]].*)?$ ]]; then
        break
      fi
      warn "Public key format is invalid"
      continue
    fi

    warn "Select 1 or 2"
  done

  while :; do
    read -rsp "Password for ${new_username}: " pass
    printf '\n'
    read -rsp 'Repeat password: ' pass2
    printf '\n'
    [[ -n "$pass" ]] || { warn "Password must not be empty"; continue; }
    [[ "$pass" == "$pass2" ]] && break
    warn "Passwords do not match"
  done

  install -d -m 700 -o root -g root "$(dirname "$ENV_FILE")" "$(dirname "$HASH_FILE")"
  umask 077
  printf '%s' "$pass" | openssl passwd -6 -stdin > "$HASH_FILE"
  cat > "$ENV_FILE" <<EOF
NEW_USERNAME=${new_username}
SSH_PORT=${ssh_port}
SSH_PUBLIC_KEY=${ssh_public_key}
PASSWORD_AUTH=no
PASSWORDLESS_SUDO=no
MANAGE_UFW=yes
EOF
  chmod 600 "$ENV_FILE" "$HASH_FILE"
}

[[ "$EUID" -eq 0 ]] || die "Run this script as root"
ACTION=""
select_action

if [[ "$ACTION" == "add-ports" ]]; then
  add_ufw_ports_interactive
  printf '\nDone. SSH and user settings were not changed.\n'
  exit 0
fi

require_command openssl
require_command ssh-keygen
[[ ! -L "$ENV_FILE" && ! -L "$HASH_FILE" ]] || die "Configuration files must not be symbolic links"
if [[ -e "$ENV_FILE" ]]; then
  require_regular_root_file "$ENV_FILE"
  backup_file "$ENV_FILE"
fi
if [[ -e "$HASH_FILE" ]]; then
  require_regular_root_file "$HASH_FILE"
  backup_file "$HASH_FILE"
fi
collect_user_configuration
require_regular_root_file "$ENV_FILE"
require_regular_root_file "$HASH_FILE"

# Parse only known dotenv keys. Never source a root-owned configuration file.
NEW_USERNAME="$(read_env_value NEW_USERNAME)"
SSH_PORT="$(read_env_value SSH_PORT)"
SSH_PUBLIC_KEY="$(read_env_value SSH_PUBLIC_KEY)"
PASSWORD_AUTH="$(read_env_value PASSWORD_AUTH)"
PASSWORDLESS_SUDO="$(read_env_value PASSWORDLESS_SUDO)"
MANAGE_UFW="$(read_env_value MANAGE_UFW)"

SSH_PORT="${SSH_PORT:-20202}"
PASSWORD_AUTH="${PASSWORD_AUTH:-no}"
PASSWORDLESS_SUDO="${PASSWORDLESS_SUDO:-no}"
MANAGE_UFW="${MANAGE_UFW:-no}"
NEW_PASSWORD_HASH="$(tr -d '\r\n' < "$HASH_FILE")"

[[ "$NEW_USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Invalid NEW_USERNAME"
[[ "$NEW_USERNAME" != root ]] || die "NEW_USERNAME must not be root"
if id "$NEW_USERNAME" >/dev/null 2>&1; then
  existing_uid="$(id -u "$NEW_USERNAME")"
  (( existing_uid >= 1000 && existing_uid != 65534 )) || die "Refusing to modify a system account: $NEW_USERNAME"
fi
is_valid_port "$SSH_PORT" || die "SSH_PORT must be between 1 and 65535"
validate_boolean PASSWORD_AUTH "$PASSWORD_AUTH"
validate_boolean PASSWORDLESS_SUDO "$PASSWORDLESS_SUDO"
validate_boolean MANAGE_UFW "$MANAGE_UFW"
[[ "$NEW_PASSWORD_HASH" == \$* && "$NEW_PASSWORD_HASH" != *:* ]] || die "Invalid password hash"

if [[ -z "$SSH_PUBLIC_KEY" ]]; then
  die "SSH_PUBLIC_KEY is required; refusing to configure a password-only SSH account"
fi

log "Checking packages installed by step 2"

for command_name in find sshd ssh-keygen visudo systemctl; do
  require_command "$command_name"
done

key_check="$(mktemp)"
trap 'rm -f -- "${key_check:-}"' EXIT
chmod 600 "$key_check"
printf '%s\n' "$SSH_PUBLIC_KEY" > "$key_check"
ssh-keygen -l -f "$key_check" >/dev/null 2>&1 || die "SSH_PUBLIC_KEY is not a valid public key"

if id "$NEW_USERNAME" >/dev/null 2>&1; then
  log "User $NEW_USERNAME already exists"
else
  log "Creating user $NEW_USERNAME"
  useradd --create-home --shell /bin/bash -- "$NEW_USERNAME"
fi

log "Setting password hash and sudo membership for $NEW_USERNAME"
printf '%s:%s\n' "$NEW_USERNAME" "$NEW_PASSWORD_HASH" | chpasswd -e
usermod -aG sudo -- "$NEW_USERNAME"

SUDOERS_FILE="/etc/sudoers.d/${NEW_USERNAME}"
backup_file "$SUDOERS_FILE"
if [[ "$PASSWORDLESS_SUDO" == yes ]]; then
  printf '%s ALL=(ALL:ALL) NOPASSWD:ALL\n' "$NEW_USERNAME" > "$SUDOERS_FILE"
else
  printf '%s ALL=(ALL:ALL) ALL\n' "$NEW_USERNAME" > "$SUDOERS_FILE"
fi
chmod 440 "$SUDOERS_FILE"
visudo -cf "$SUDOERS_FILE" >/dev/null || die "sudoers validation failed"

user_home="$(getent passwd "$NEW_USERNAME" | cut -d: -f6)"
user_group="$(id -gn "$NEW_USERNAME")"
[[ -n "$user_home" && "$user_home" == /* ]] || die "Could not determine user home"
[[ -d "$user_home" && ! -L "$user_home" ]] || die "User home is not a regular directory: $user_home"

# OpenSSH StrictModes rejects keys when the home directory, .ssh or
# authorized_keys has unsafe ownership or permissions. Repair all three on
# every run so an existing user can be fixed by running this script again.
chown "$NEW_USERNAME:$user_group" "$user_home"
chmod 750 "$user_home"
[[ ! -L "$user_home/.ssh" ]] || die "Refusing to use a symbolic link as $user_home/.ssh"
install -d -m 700 -o "$NEW_USERNAME" -g "$user_group" "$user_home/.ssh"
[[ ! -L "$user_home/.ssh/authorized_keys" ]] \
  || die "Refusing to use a symbolic link as $user_home/.ssh/authorized_keys"
touch -- "$user_home/.ssh/authorized_keys"
if ! grep -Fqx -- "$SSH_PUBLIC_KEY" "$user_home/.ssh/authorized_keys"; then
  printf '%s\n' "$SSH_PUBLIC_KEY" >> "$user_home/.ssh/authorized_keys"
fi
chown -R --no-dereference "$NEW_USERNAME:$user_group" "$user_home/.ssh"
find "$user_home/.ssh" -xdev -type d -exec chmod 700 {} +
find "$user_home/.ssh" -xdev -type f -exec chmod 600 {} +

id -nG "$NEW_USERNAME" | tr ' ' '\n' | grep -Fqx sudo \
  || die "$NEW_USERNAME was not added to the sudo group"
[[ "$(stat -c '%U:%G' "$user_home/.ssh")" == "$NEW_USERNAME:$user_group" ]] \
  || die "Incorrect owner for $user_home/.ssh"
[[ "$(stat -c '%a' "$user_home/.ssh")" == 700 ]] \
  || die "Incorrect permissions for $user_home/.ssh"
[[ "$(stat -c '%U:%G' "$user_home/.ssh/authorized_keys")" == "$NEW_USERNAME:$user_group" ]] \
  || die "Incorrect owner for authorized_keys"
[[ "$(stat -c '%a' "$user_home/.ssh/authorized_keys")" == 600 ]] \
  || die "Incorrect permissions for authorized_keys"

if command -v restorecon >/dev/null 2>&1; then
  restorecon -RF "$user_home/.ssh" || warn "SELinux context could not be restored"
fi

ssh-keygen -l -f "$user_home/.ssh/authorized_keys" >/dev/null 2>&1 || \
  die "The installed authorized_keys file contains no valid SSH key"
log "Installed SSH key fingerprint: $(ssh-keygen -l -f "$user_home/.ssh/authorized_keys" | head -n1)"

log "Writing isolated SSH configuration"
install -d -m 755 /etc/ssh/sshd_config.d
backup_file "$SSHD_DROPIN"
cat > "$SSHD_DROPIN" <<EOF
# Managed by ochenstarik-server-3.sh
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication ${PASSWORD_AUTH}
PubkeyAuthentication yes
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
EOF
chmod 644 "$SSHD_DROPIN"

sshd -t || die "sshd syntax validation failed"
effective_port="$(sshd -T | awk '$1 == "port" { print $2; exit }')"
effective_root="$(sshd -T | awk '$1 == "permitrootlogin" { print $2; exit }')"
effective_password="$(sshd -T | awk '$1 == "passwordauthentication" { print $2; exit }')"
[[ "$effective_port" == "$SSH_PORT" ]] || die "Effective SSH port is $effective_port, expected $SSH_PORT"
[[ "$effective_root" == no ]] || die "Effective PermitRootLogin is $effective_root, expected no"
[[ "$effective_password" == "$PASSWORD_AUTH" ]] || die "Effective PasswordAuthentication is $effective_password, expected $PASSWORD_AUTH"

if [[ "$MANAGE_UFW" == yes ]]; then
  log "Allowing SSH, HTTPS, and application ports in UFW without resetting existing rules"
  allow_ufw_rule "${SSH_PORT}/tcp"
  allow_ufw_rule "443/tcp"
  allow_ufw_rule "63636/tcp"
  ufw --force enable
else
  warn "MANAGE_UFW=no: firewall was not enabled or modified"
fi

log "Configuring fail2ban without replacing existing jail.local"
install -d -m 755 /etc/fail2ban/jail.d
backup_file "$FAIL2BAN_JAIL"
cat > "$FAIL2BAN_JAIL" <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
bantime = 1h
findtime = 10m
maxretry = 5
EOF
fail2ban-client -t
systemctl enable --now fail2ban
systemctl restart fail2ban

log "Restarting SSH service"
SSH_SERVICE=""
for service_name in ssh sshd; do
  if systemctl cat "$service_name" >/dev/null 2>&1; then
    SSH_SERVICE="$service_name"
    break
  fi
done
[[ -n "$SSH_SERVICE" ]] || die "SSH systemd service not found"
systemctl restart "$SSH_SERVICE"
systemctl enable "$SSH_SERVICE" >/dev/null 2>&1 || true

systemctl is-active --quiet "$SSH_SERVICE" || die "SSH service is not active"
fail2ban-client status sshd || warn "fail2ban sshd status check failed"

printf '\nDone.\n'
printf 'New SSH port: %s\n' "$SSH_PORT"
printf 'Administrative user: %s\n' "$NEW_USERNAME"
printf 'Password SSH authentication: %s\n' "$PASSWORD_AUTH"
printf 'Passwordless sudo: %s\n' "$PASSWORDLESS_SUDO"
printf '\nOpen a NEW terminal and test before closing the current root session:\n'
printf 'ssh -p %s %s@<server-ip>\n' "$SSH_PORT" "$NEW_USERNAME"
case "$(read_ip_mode)" in
  ipv4)
    printf 'After that login succeeds, remove temporary port 22 with:\n'
    printf 'sudo ufw delete allow from 0.0.0.0/0 to any port 22 proto tcp\n'
    ;;
  ipv6)
    printf 'After that login succeeds, remove temporary port 22 with:\n'
    printf 'sudo ufw delete allow from ::/0 to any port 22 proto tcp\n'
    ;;
  both)
    printf 'After that login succeeds, remove both temporary port 22 rules:\n'
    printf 'sudo ufw delete allow from 0.0.0.0/0 to any port 22 proto tcp\n'
    printf 'sudo ufw delete allow from ::/0 to any port 22 proto tcp\n'
    ;;
esac
printf 'To enable Telegram login notifications, run ochenstarik-server-tg-4.sh.\n'
