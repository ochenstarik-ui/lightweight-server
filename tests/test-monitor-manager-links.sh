#!/usr/bin/env bash
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
script="ochenstarik-server-monitor-manager.sh"
temp_dir="$(mktemp -d)"
trap 'rm -rf -- "$temp_dir"' EXIT

helper="$temp_dir/ochenstarik-smm-hub"
awk '
  capture && /^EOF$/ { exit }
  /cat > .*HUB_HELPER.*<</ { capture=1; next }
  capture { print }
' "$script" > "$helper"
chmod 700 "$helper"

state="$temp_dir/state"
mock_bin="$temp_dir/bin"
nft_capture="$temp_dir/nft.conf"
mkdir -p "$state/nodes" "$state/tokens" "$mock_bin"
sed -i "s|^readonly STATE_DIR=.*|readonly STATE_DIR=\"$state\"|" "$helper"
sed -i "s|^readonly WG_CONFIG=.*|readonly WG_CONFIG=\"$temp_dir/smm0.conf\"|" "$helper"
sed -i 's/^require_root() .*/require_root() { :; }/' "$helper"
sed -i 's/ -o root -g root//g' "$helper"

cat > "$mock_bin/nft" <<'EOF'
#!/usr/bin/env bash
previous=''
for argument in "$@"; do
  if [[ "$previous" == -f ]]; then
    cp -- "$argument" "$NFT_CAPTURE"
  fi
  previous="$argument"
done
exit 0
EOF
chmod 700 "$mock_bin/nft"

cat > "$state/hub.conf" <<'EOF'
HUB_ENDPOINT=hub.example.test
WG_PORT=51820
HUB_ADDRESS=10.77.0.1
MESH_CIDR=10.77.0.0/24
EOF
printf 'test-hub-private-key\n' > "$state/hub.key"
cat > "$state/nodes/ai-agent.node" <<'EOF'
NAME=ai-agent
ADDRESS=10.77.0.2
PUBLIC_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
EOF
cat > "$state/nodes/home.node" <<'EOF'
NAME=home
ADDRESS=10.77.0.3
PUBLIC_KEY=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
EOF
printf 'legacy-policy home\n' > "$state/links"

PATH="$mock_bin:$PATH" NFT_CAPTURE="$nft_capture" \
  "$helper" link-connect ai-agent home tcp 2222 120

read -r source target cidr protocol port expires < "$state/links"
[[ "$source" == ai-agent ]]
[[ "$target" == home ]]
[[ "$cidr" == 10.77.0.3/32 ]]
[[ "$protocol" == tcp ]]
[[ "$port" == 2222 ]]
(( expires > $(date +%s) ))
grep -Fq 'ip saddr 10.77.0.2 ip daddr 10.77.0.3/32 tcp dport 2222 accept' "$nft_capture"

if PATH="$mock_bin:$PATH" NFT_CAPTURE="$nft_capture" \
  "$helper" link-connect ai-agent home tcp 70000 120 >/dev/null 2>&1; then
  echo 'Invalid port was accepted.' >&2
  exit 1
fi

printf 'ai-agent home 10.77.0.3/32 udp 53 1\n' >> "$state/links"
PATH="$mock_bin:$PATH" NFT_CAPTURE="$nft_capture" "$helper" firewall-restore
[[ "$(wc -l < "$state/links")" -eq 1 ]]

PATH="$mock_bin:$PATH" NFT_CAPTURE="$nft_capture" \
  "$helper" link-disconnect ai-agent home tcp 2222
[[ ! -s "$state/links" ]]
if grep -Fq 'dport 2222 accept' "$nft_capture"; then
  echo 'Disconnected policy remained in nftables.' >&2
  exit 1
fi

grep -Fq 'OnUnitActiveSec=1min' "$script"
printf 'Server Monitor Manager Link policy checks passed.\n'
