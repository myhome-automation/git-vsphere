#!/usr/bin/env bash
# Build the custom nginx-homelab-proxy image on the remote Ubuntu host
# (which has podman) and push it to quay.io.
#
# Usage:
#   bash build-and-push.sh quay.io/<your-org>/nginx-homelab-proxy:1.0
#
# Prereq, one-time:
#   ssh 192.168.1.203 'sudo podman login quay.io'
#   (enter quay.io username + password / robot token interactively)
set -euo pipefail

IMG="${1:-}"
HOST="${REMOTE_HOST:-192.168.1.203}"

if [[ -z "$IMG" ]]; then
  echo "Usage: $0 <full-image-tag> e.g. quay.io/myorg/nginx-homelab-proxy:1.0" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> copy build context to ${HOST}:/tmp/nginx-proxy-build/"
ssh "$HOST" 'rm -rf /tmp/nginx-proxy-build && mkdir -p /tmp/nginx-proxy-build'
scp "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR/nginx.conf" "$HOST":/tmp/nginx-proxy-build/

echo "==> build image: $IMG"
ssh "$HOST" "cd /tmp/nginx-proxy-build && sudo podman build -t '$IMG' ."

echo "==> push image (must have 'podman login quay.io' first)"
ssh "$HOST" "sudo podman push '$IMG'"

echo "==> done — pull with:"
echo "  podman pull $IMG"
