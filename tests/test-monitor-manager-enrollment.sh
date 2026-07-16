#!/usr/bin/env bash
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
script="ochenstarik-server-monitor-manager.sh"
temp_dir="$(mktemp -d)"
trap 'rm -rf -- "$temp_dir"' EXIT

[[ -s "$script" ]]
grep -Fq 'code="SMM2-' "$script"
grep -Fq 'request_code="SMMREQ1-' "$script"
grep -Fq 'SMMACK1-' "$script"
grep -Fq 'expires=$(( $(date +%s) + 600 ))' "$script"
grep -Fq 'mv -- "$token_file" "$consuming_file"' "$script"
grep -Fq 'private_key="$(wg genkey)"' "$script"

if grep -Fq 'PRIVATE_KEY=%s' "$script"; then
  echo 'Enrollment payload must not contain a private WireGuard key.' >&2
  exit 1
fi

helper="$temp_dir/ochenstarik-smm-hub"
awk '
  capture && /^EOF$/ { exit }
  /cat > .*HUB_HELPER.*<</ { capture=1; next }
  capture { print }
' "$script" > "$helper"
chmod 700 "$helper"

state="$temp_dir/state"
mock_bin="$temp_dir/bin"
mkdir -p "$state/nodes" "$state/tokens" "$mock_bin"
sed -i "s|^readonly STATE_DIR=.*|readonly STATE_DIR=\"$state\"|" "$helper"
sed -i "s|^readonly WG_CONFIG=.*|readonly WG_CONFIG=\"$temp_dir/smm0.conf\"|" "$helper"
sed -i 's/^require_root() .*/require_root() { :; }/' "$helper"
sed -i 's/ -o root -g root//g' "$helper"

public_key='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
cat > "$mock_bin/wg" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == pubkey ]]; then
  printf '%s\n' '$public_key'
  exit 0
fi
exit 0
EOF
cat > "$mock_bin/ip" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod 700 "$mock_bin/wg" "$mock_bin/ip"

cat > "$state/hub.conf" <<'EOF'
HUB_ENDPOINT=hub.example.test
WG_PORT=51820
HUB_ADDRESS=10.77.0.1
MESH_CIDR=10.77.0.0/24
EOF
printf 'test-hub-private-key\n' > "$state/hub.key"
: > "$state/links"

output="$(PATH="$mock_bin:$PATH" "$helper" node-code test-node)"
join_code="$(printf '%s\n' "$output" | grep '^SMM2-')"
[[ -n "$join_code" ]]

decode_base64url() {
  local data="$1"
  data="${data//-/+}"
  data="${data//_/\/}"
  case $(( ${#data} % 4 )) in
    2) data+='==' ;;
    3) data+='=' ;;
  esac
  printf '%s' "$data" | base64 -d
}

payload="$(decode_base64url "${join_code#SMM2-}")"
token="$(printf '%s\n' "$payload" | awk -F= '$1 == "TOKEN" { print $2 }')"
name="$(printf '%s\n' "$payload" | awk -F= '$1 == "NAME" { print $2 }')"
address="$(printf '%s\n' "$payload" | awk -F= '$1 == "ADDRESS" { print $2 }')"
[[ "$name" == test-node ]]
[[ "$address" == 10.77.0.2/32 ]]
[[ "$token" =~ ^[a-f0-9]{64}$ ]]
[[ "$payload" != *PRIVATE_KEY* ]]

request_payload="$(printf 'VERSION=1\nTOKEN=%s\nNAME=%s\nADDRESS=%s\nPUBLIC_KEY=%s\n' \
  "$token" "$name" "$address" "$public_key")"
request_code="SMMREQ1-$(printf '%s' "$request_payload" | base64 -w0 | tr '+/' '-_' | tr -d '=')"
enroll_output="$(PATH="$mock_bin:$PATH" SMM_ENROLL_REQUEST="$request_code" "$helper" node-enroll)"
grep -Eq '^SMMACK1-[a-f0-9]{64}$' <<< "$enroll_output"
grep -Fqx 'NAME=test-node' "$state/nodes/test-node.node"
grep -Fqx "PUBLIC_KEY=$public_key" "$state/nodes/test-node.node"

if PATH="$mock_bin:$PATH" SMM_ENROLL_REQUEST="$request_code" "$helper" node-enroll >/dev/null 2>&1; then
  echo 'Enrollment token was accepted more than once.' >&2
  exit 1
fi

printf 'Server Monitor Manager enrollment checks passed.\n'
