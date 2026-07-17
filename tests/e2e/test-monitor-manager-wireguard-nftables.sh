#!/usr/bin/env bash
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.."

for command in ip wg nft nc timeout awk sed; do
  command -v "$command" >/dev/null || { echo "$command is required" >&2; exit 1; }
done
[[ "$EUID" -eq 0 ]] || { echo 'run as root' >&2; exit 1; }

temporary="$(mktemp -d)"
suffix="${GITHUB_RUN_ID:-$$}"
hub="smm-hub-${suffix}"
source="smm-source-${suffix}"
target="smm-target-${suffix}"
listener_pid=''

cleanup() {
  [[ -z "$listener_pid" ]] || kill "$listener_pid" >/dev/null 2>&1 || true
  ip netns delete "$source" >/dev/null 2>&1 || true
  ip netns delete "$target" >/dev/null 2>&1 || true
  ip netns delete "$hub" >/dev/null 2>&1 || true
  rm -rf -- "$temporary"
}
trap cleanup EXIT

for namespace in "$hub" "$source" "$target"; do
  ip netns add "$namespace"
  ip -n "$namespace" link set lo up
done

ip link add smm-hub-source type veth peer name smm-source-wan
ip link set smm-hub-source netns "$hub"
ip link set smm-source-wan netns "$source"
ip -n "$hub" address add 192.0.2.1/30 dev smm-hub-source
ip -n "$source" address add 192.0.2.2/30 dev smm-source-wan
ip -n "$hub" link set smm-hub-source up
ip -n "$source" link set smm-source-wan up

ip link add smm-hub-target type veth peer name smm-target-wan
ip link set smm-hub-target netns "$hub"
ip link set smm-target-wan netns "$target"
ip -n "$hub" address add 192.0.2.5/30 dev smm-hub-target
ip -n "$target" address add 192.0.2.6/30 dev smm-target-wan
ip -n "$hub" link set smm-hub-target up
ip -n "$target" link set smm-target-wan up

umask 077
wg genkey > "$temporary/hub.key"
wg genkey > "$temporary/source.key"
wg genkey > "$temporary/target.key"
wg pubkey < "$temporary/hub.key" > "$temporary/hub.pub"
wg pubkey < "$temporary/source.key" > "$temporary/source.pub"
wg pubkey < "$temporary/target.key" > "$temporary/target.pub"

for namespace in "$hub" "$source" "$target"; do
  ip -n "$namespace" link add smm0 type wireguard
done
ip netns exec "$hub" wg set smm0 \
  private-key "$temporary/hub.key" listen-port 51820 \
  peer "$(<"$temporary/source.pub")" allowed-ips 10.77.0.2/32 \
  peer "$(<"$temporary/target.pub")" allowed-ips 10.77.0.3/32
ip netns exec "$source" wg set smm0 \
  private-key "$temporary/source.key" \
  peer "$(<"$temporary/hub.pub")" endpoint 192.0.2.1:51820 allowed-ips 10.77.0.0/24 persistent-keepalive 1
ip netns exec "$target" wg set smm0 \
  private-key "$temporary/target.key" \
  peer "$(<"$temporary/hub.pub")" endpoint 192.0.2.5:51820 allowed-ips 10.77.0.0/24 persistent-keepalive 1

ip -n "$hub" address add 10.77.0.1/24 dev smm0
ip -n "$source" address add 10.77.0.2/32 dev smm0
ip -n "$target" address add 10.77.0.3/32 dev smm0
for namespace in "$hub" "$source" "$target"; do
  ip -n "$namespace" link set smm0 up
done
ip -n "$source" route add 10.77.0.0/24 dev smm0
ip -n "$target" route add 10.77.0.0/24 dev smm0
ip netns exec "$hub" sysctl -q -w net.ipv4.ip_forward=1

helper="$temporary/ochenstarik-smm-hub"
awk '
  capture && /^EOF$/ { exit }
  /cat > .*HUB_HELPER.*<</ { capture=1; next }
  capture { print }
' ochenstarik-server-monitor-manager.sh > "$helper"
chmod 700 "$helper"
state="$temporary/state"
mkdir -p "$state/nodes" "$state/tokens"
sed -i "s|^readonly STATE_DIR=.*|readonly STATE_DIR=\"$state\"|" "$helper"
sed -i "s|^readonly WG_CONFIG=.*|readonly WG_CONFIG=\"$temporary/smm0.conf\"|" "$helper"
cat > "$state/hub.conf" <<'EOF'
HUB_ENDPOINT=203.0.113.10
WG_PORT=51820
HUB_ADDRESS=10.77.0.1
MESH_CIDR=10.77.0.0/24
EOF
cp "$temporary/hub.key" "$state/hub.key"
cat > "$state/nodes/source.node" <<EOF
NAME=source
ADDRESS=10.77.0.2
PUBLIC_KEY=$(<"$temporary/source.pub")
EOF
cat > "$state/nodes/target.node" <<EOF
NAME=target
ADDRESS=10.77.0.3
PUBLIC_KEY=$(<"$temporary/target.pub")
EOF
touch "$state/links" "$state/audit.jsonl"
printf '0\n' > "$state/policy.version"

start_listener() {
  local namespace="$1"
  ip netns exec "$namespace" sh -c 'printf allowed | timeout 10 nc -l 2222' &
  listener_pid=$!
  sleep 0.2
}

ip netns exec "$hub" "$helper" link-connect source target tcp 2222 120
start_listener "$target"
response="$(timeout 8 ip netns exec "$source" nc -w 5 10.77.0.3 2222)"
wait "$listener_pid"
listener_pid=''
[[ "$response" == allowed ]]

# The policy is directional: the reverse connection must remain blocked.
start_listener "$source"
if timeout 3 ip netns exec "$target" nc -w 2 10.77.0.2 2222 >/dev/null 2>&1; then
  echo 'Reverse traffic bypassed the directional Link.' >&2
  exit 1
fi
kill "$listener_pid" >/dev/null 2>&1 || true
wait "$listener_pid" 2>/dev/null || true
listener_pid=''

ip netns exec "$hub" "$helper" link-disconnect source target tcp 2222
start_listener "$target"
if timeout 3 ip netns exec "$source" nc -w 2 10.77.0.3 2222 >/dev/null 2>&1; then
  echo 'Traffic remained available after the Link kill switch.' >&2
  exit 1
fi
kill "$listener_pid" >/dev/null 2>&1 || true
wait "$listener_pid" 2>/dev/null || true
listener_pid=''

ip netns exec "$hub" wg show smm0 latest-handshakes | awk '$2 > 0 { found=1 } END { exit !found }'
grep -Fq '"state":"Active"' "$state/audit.jsonl"
grep -Fq '"state":"Disabled"' "$state/audit.jsonl"

printf 'Real WireGuard and nftables directional Link checks passed.\n'
