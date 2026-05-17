#!/usr/bin/env bash
# Build Rocky 9 template on ESXi using Packer.
#
# Kickstart delivery: render ks.cfg locally with build_password substituted,
# scp to ESXi /tmp/ks.cfg, run an nc loop on ESXi:8080 serving the file.
# The boot_command in the HCL passes inst.ks=http://192.168.1.174:8080/ks.cfg
# so anaconda fetches it during install.
#
# Why this approach: tried OEMDRV virtual CD via Packer cd_content — anaconda
# couldn't double-mount the install CD for both stage2 and repo when a second
# CD was attached. HTTP kickstart with a single CD attached is the proven
# historical path (see TROUBLESHOOTING.md Failed Approach #1).
set -euo pipefail

PACKER_DIR="$(cd "$(dirname "$0")" && pwd)"
VARS_FILE="$PACKER_DIR/packer.pkrvars.hcl"
ESXI_HOST=192.168.1.174
KS_PORT=8080

if [[ ! -f "$VARS_FILE" ]]; then
  echo "ERROR: $VARS_FILE not found. Copy packer.pkrvars.hcl.example and fill in values." >&2
  exit 1
fi

# Pull build_password out of pkrvars (used to render ks.cfg)
BUILD_PASSWORD="$(grep -E '^[[:space:]]*build_password' "$VARS_FILE" | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/')"
if [[ -z "${BUILD_PASSWORD:-}" ]]; then
  echo "ERROR: could not read build_password from $VARS_FILE" >&2
  exit 1
fi

# ── Cleanup trap ──────────────────────────────────────────────────────────
# Kill nc loop, restore firewall, remove staged ks.cfg on exit (success or
# failure). Idempotent: || true keeps cleanup quiet if nc already exited.
cleanup() {
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$ESXI_HOST" \
    "pkill -f 'nc -l $KS_PORT' 2>/dev/null; \
     rm -f /tmp/ks.cfg /tmp/nc.log; \
     esxcli network firewall set --enabled true 2>/dev/null; \
     true" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ── Render ks.cfg ─────────────────────────────────────────────────────────
# Substitute ${build_password} placeholders with the real value.
# Other ${KVER}-style placeholders in %post shell are escaped as $${KVER}
# (legacy Packer templatefile escaping); convert them back to single ${KVER}
# so bash inside %post can expand them at install time.
KS_RENDERED=$(mktemp /tmp/ks.cfg.XXXXXX)
sed -e "s|\\\${build_password}|${BUILD_PASSWORD}|g" \
    -e 's|\$\${|${|g' \
    "$PACKER_DIR/http/ks.cfg" > "$KS_RENDERED"

# ── Stage ks.cfg on ESXi & start nc loop ──────────────────────────────────
# ESXi 6.7's sftp subsystem is buggy and fails with "Couldn't write to
# remote file" intermittently. Pipe via cat+ssh instead.
echo "==> Uploading ks.cfg to ESXi:/tmp/ks.cfg ..."
cat "$KS_RENDERED" | ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
  root@"$ESXI_HOST" "cat > /tmp/ks.cfg && chmod 644 /tmp/ks.cfg"
rm -f "$KS_RENDERED"

echo "==> Disabling ESXi firewall (re-enabled by cleanup trap) ..."
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$ESXI_HOST" \
  "esxcli network firewall set --enabled false" >/dev/null

echo "==> Starting nc loop on ESXi:$KS_PORT (serves /tmp/ks.cfg) ..."
# nohup sh -c 'while ...' & detaches so ssh returns. ESXi's busybox nc
# (OpenBSD syntax): `nc -l 8080` — NOT `-l -p 8080`. Include HTTP/1.0
# response headers so anaconda's fetch treats the body as text/plain.
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$ESXI_HOST" \
  "nohup sh -c 'while true; do (printf \"HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\n\"; cat /tmp/ks.cfg) | nc -l $KS_PORT; done' \
     >/dev/null 2>&1 </dev/null &" \
  >/dev/null 2>&1 || true

# Quick reachability check — anaconda needs this to work.
if ! curl -s --max-time 5 "http://$ESXI_HOST:$KS_PORT/" | head -1 | grep -q "^#version"; then
  echo "WARNING: nc on $ESXI_HOST:$KS_PORT didn't return ks.cfg." >&2
  echo "  Build will likely fail at 'Waiting for SSH'." >&2
  echo "  Check ESXi firewall: esxcli network firewall ruleset list | grep -i http" >&2
fi

# ── ISO placeholder ───────────────────────────────────────────────────────
# Packer stats the file:// iso_url locally before checking the ESXi remote
# cache. A real local copy is preferred (used to verify iso_checksum).
ISO_FILENAME=$(grep 'iso_url' "$PACKER_DIR/rocky9-template.pkr.hcl" | grep -oP 'Rocky[^"]+\.iso')
ISO_LOCAL="/tmp/${ISO_FILENAME}"
if [[ ! -f "$ISO_LOCAL" ]]; then
  touch "$ISO_LOCAL"
  echo "Created ISO placeholder: $ISO_LOCAL (set iso_checksum=\"none\" in HCL if using a placeholder)"
fi

# ── Run Packer ────────────────────────────────────────────────────────────
cd "$PACKER_DIR"
/usr/bin/packer build -var-file=packer.pkrvars.hcl .
