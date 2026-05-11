#!/usr/bin/env bash
# Serves ks.cfg via netcat on the ESXi host (port 8080) so the installer VM
# can always fetch it — installer VM and ESXi host are on the same physical box.
set -euo pipefail

PACKER_DIR="$(cd "$(dirname "$0")" && pwd)"
VARS_FILE="$PACKER_DIR/packer.pkrvars.hcl"
KS_TEMPLATE="$PACKER_DIR/http/ks.cfg"
ESXI_HOST="192.168.1.174"
ESXI_PORT=8080

if [[ ! -f "$VARS_FILE" ]]; then
  echo "ERROR: $VARS_FILE not found. Copy packer.pkrvars.hcl.example and fill in values." >&2
  exit 1
fi

# Extract build_password from vars file
BUILD_PASS=$(grep 'build_password' "$VARS_FILE" | grep -oP '(?<=")[^"]+(?=")')
if [[ -z "$BUILD_PASS" ]]; then
  echo "ERROR: build_password not found in $VARS_FILE" >&2
  exit 1
fi

# Render kickstart and copy to ESXi
RENDERED=$(mktemp)
sed "s|\${build_password}|${BUILD_PASS}|g" "$KS_TEMPLATE" > "$RENDERED"
scp -o StrictHostKeyChecking=no "$RENDERED" "root@${ESXI_HOST}:/tmp/ks.cfg"
rm -f "$RENDERED"
echo "Kickstart copied to ESXi /tmp/ks.cfg"

# Start nc HTTP server on ESXi (background loop — handles repeated GETs)
ssh -o StrictHostKeyChecking=no "root@${ESXI_HOST}" \
  "nohup sh -c 'while true; do (printf \"HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\n\"; cat /tmp/ks.cfg) | nc -l ${ESXI_PORT}; done' > /tmp/ks_server.log 2>&1 & sleep 1 && echo \$!"
echo "nc kickstart server started on ESXi port ${ESXI_PORT}"

cleanup() {
  echo "Stopping kickstart server on ESXi..."
  ssh -o StrictHostKeyChecking=no "root@${ESXI_HOST}" \
    "pkill -f ks_server.sh 2>/dev/null; pkill -f 'nc -l -p ${ESXI_PORT}' 2>/dev/null; rm -f /tmp/ks.cfg /tmp/ks_server.sh" || true
}
trap cleanup EXIT

sleep 2

cd "$PACKER_DIR"
/usr/bin/packer build -var-file=packer.pkrvars.hcl .
