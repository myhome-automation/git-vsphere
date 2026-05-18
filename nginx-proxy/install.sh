#!/usr/bin/env bash
# Deploy 2-podman-nginx HA reverse proxy on the Ubuntu host
# (192.168.1.203 / gdragon-ubuntu). Path-based routing to k3s apps.
#
# Run from the workstation. Idempotent: re-running pulls latest image
# and restarts both containers.
#
# The image (quay.io/bpraisa/nginx:homelab-proxy-1.4) has the proxy
# config baked in, so no host volume mount is needed. Override the
# image via the IMAGE env var if you want a different version:
#   IMAGE=quay.io/bpraisa/nginx:latest bash install.sh
set -euo pipefail

HOST="${1:-192.168.1.203}"
IMAGE="${IMAGE:-quay.io/bpraisa/nginx:homelab-proxy-1.4}"

ssh -o StrictHostKeyChecking=no "$HOST" "IMAGE='$IMAGE' bash -s" <<'REMOTE'
set -e
echo "==> stop system nginx if present"
sudo systemctl stop nginx 2>/dev/null || true
sudo systemctl disable nginx 2>/dev/null || true

echo "==> ensure podman is installed"
which podman >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq podman; }

echo "==> allow rootless to bind privileged port :80"
if ! sysctl -n net.ipv4.ip_unprivileged_port_start | grep -q '^80$'; then
  echo "net.ipv4.ip_unprivileged_port_start=80" | sudo tee /etc/sysctl.d/99-rootless-low-ports.conf >/dev/null
  sudo sysctl -p /etc/sysctl.d/99-rootless-low-ports.conf
fi

echo "==> pull image $IMAGE"
podman pull "$IMAGE"

for pair in "nginx-1:80" "nginx-2:8080"; do
  name="${pair%%:*}"; port="${pair##*:}"
  echo "==> (re)launch $name on host port $port"
  podman rm -f "$name" 2>/dev/null || true
  # --restart=unless-stopped (NOT =always): survives host reboots but
  # respects explicit `podman stop` instead of immediately re-spawning
  # the container. Without this, edge_shutdown.yml's `podman stop`
  # races with the restart policy and the container comes right back.
  podman run -d --restart=unless-stopped --name "$name" -p "${port}:80" "$IMAGE"
done

echo "==> done"
podman ps --format 'table {{.Names}} {{.Status}} {{.Ports}}'
REMOTE
