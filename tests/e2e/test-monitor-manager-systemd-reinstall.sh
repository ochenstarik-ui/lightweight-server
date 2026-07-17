#!/usr/bin/env bash
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.."

command -v docker >/dev/null || { echo 'docker is required' >&2; exit 1; }
command -v ssh-keygen >/dev/null || { echo 'ssh-keygen is required' >&2; exit 1; }

run_id="${GITHUB_RUN_ID:-local}-$$"
image="smm-systemd-e2e:${run_id}"
container="smm-systemd-e2e-${run_id}"
temporary="$(mktemp -d)"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker image rm -f "$image" >/dev/null 2>&1 || true
  rm -rf -- "$temporary"
}
trap cleanup EXIT

ssh-keygen -q -t ed25519 -N '' -C 'smm-e2e' -f "$temporary/monitor-key"
public_key="$(<"$temporary/monitor-key.pub")"

docker build --pull -f tests/e2e/Dockerfile.systemd -t "$image" .
docker run -d \
  --name "$container" \
  --privileged \
  --cgroupns=host \
  --tmpfs /run \
  --tmpfs /run/lock \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  "$image" >/dev/null

for _ in $(seq 1 30); do
  docker exec "$container" systemctl show --property=Version >/dev/null 2>&1 && break
  sleep 1
done
docker exec "$container" systemctl show --property=Version >/dev/null

install_hub() {
  docker exec \
    -e "SERVER_MONITOR_PUBLIC_KEY=$public_key" \
    -e SMM_HUB_ENDPOINT=203.0.113.10 \
    -e SMM_WG_PORT=51820 \
    "$container" \
    /workspace/ochenstarik-server-monitor-manager.sh install-hub
}

install_hub
first_private_key_hash="$(docker exec "$container" sha256sum /etc/ochenstarik-server-monitor-manager/hub.key | awk '{ print $1 }')"

# A repeated install must repair units/configuration without rotating the Hub identity.
install_hub
second_private_key_hash="$(docker exec "$container" sha256sum /etc/ochenstarik-server-monitor-manager/hub.key | awk '{ print $1 }')"
[[ "$first_private_key_hash" == "$second_private_key_hash" ]]
[[ "$(docker exec "$container" grep -c 'ochenstarik-server-monitor' /var/lib/ochenstarik-server-monitor-manager/.ssh/authorized_keys)" -eq 1 ]]

# Restarting the systemd container is the CI reboot boundary: the writable rootfs is retained,
# PID 1 starts again, and only enabled units can reconstruct runtime state.
docker restart --timeout 20 "$container" >/dev/null
for _ in $(seq 1 45); do
  if docker exec "$container" systemctl is-active --quiet wg-quick@smm0.service \
      && docker exec "$container" systemctl is-active --quiet ochenstarik-smm-firewall.timer \
      && docker exec "$container" systemctl is-active --quiet ssh.service; then
    break
  fi
  sleep 1
done

docker exec "$container" systemctl is-enabled --quiet wg-quick@smm0.service
docker exec "$container" systemctl is-enabled --quiet ochenstarik-smm-firewall.service
docker exec "$container" systemctl is-enabled --quiet ochenstarik-smm-firewall.timer
docker exec "$container" systemctl is-active --quiet wg-quick@smm0.service
docker exec "$container" systemctl is-active --quiet ochenstarik-smm-firewall.timer
docker exec "$container" systemctl start ochenstarik-smm-firewall.service
docker exec "$container" ip address show dev smm0 | grep -Fq '10.77.0.1/24'
docker exec "$container" nft list table inet ochenstarik_smm | grep -Fq 'iifname "smm0" oifname "smm0" drop'
docker exec "$container" test "$(sha256sum /etc/ochenstarik-server-monitor-manager/hub.key | awk '{ print $1 }')" = "$first_private_key_hash"

printf 'Server Monitor Manager repeated-install and reboot checks passed.\n'
