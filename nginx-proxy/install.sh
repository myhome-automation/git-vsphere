#!/usr/bin/env bash
# Deploy 2-podman-nginx HA reverse proxy on the Ubuntu host
# (192.168.1.203 / gdragon-ubuntu). Path-based routing to k3s apps.
#
# Run from the workstation (ansible/this repo). Idempotent: re-running
# pulls the latest config + restarts both containers.
set -euo pipefail

HOST="${1:-192.168.1.203}"

scp -o StrictHostKeyChecking=no "$(dirname "$0")/nginx.conf" "$HOST":/tmp/nginx.conf
ssh -o StrictHostKeyChecking=no "$HOST" 'bash -s' <<'REMOTE'
set -e
echo "==> stop system nginx if present"
sudo systemctl stop nginx 2>/dev/null || true
sudo systemctl disable nginx 2>/dev/null || true

echo "==> ensure podman is installed"
which podman >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq podman; }

echo "==> stage config"
sudo mkdir -p /etc/podman-proxy
sudo mv /tmp/nginx.conf /etc/podman-proxy/nginx.conf
sudo chmod 644 /etc/podman-proxy/nginx.conf

echo "==> pull nginx image"
sudo podman pull docker.io/library/nginx:1.27-alpine

for pair in "nginx-1:80" "nginx-2:8080"; do
  name="${pair%%:*}"; port="${pair##*:}"
  echo "==> (re)launch $name on host port $port"
  sudo podman rm -f "$name" 2>/dev/null || true
  sudo podman run -d --restart=always --name "$name" \
    -p "${port}:80" \
    -v /etc/podman-proxy/nginx.conf:/etc/nginx/conf.d/default.conf:ro,Z \
    docker.io/library/nginx:1.27-alpine
done

echo "==> done"
sudo podman ps --format 'table {{.Names}} {{.Status}} {{.Ports}}'
REMOTE
