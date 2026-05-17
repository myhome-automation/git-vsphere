#!/usr/bin/env bash
# Fetch a kubeconfig from a remote control-plane node, rename its cluster /
# user / context to a stable name, and merge it into ~/.kube/config so that
# multiple clusters can coexist and be switched via `kubectl config
# use-context <name>`.
#
# Designed to be re-runnable for additional clusters: each cluster goes in
# as its own context. Existing contexts with the same name are replaced.
#
# Usage:
#   scripts/fetch-kubeconfig.sh <context-name> <host> [ssh-user] [ssh-key] [remote-path]
#
# Examples:
#   # Homelab cluster (default user/key from this repo)
#   scripts/fetch-kubeconfig.sh homelab 192.168.1.186
#
#   # Another cluster on a different host
#   scripts/fetch-kubeconfig.sh staging 10.0.0.5 ubuntu ~/.ssh/staging.pem
#
# After running:
#   kubectl config get-contexts
#   kubectl config use-context homelab
#   kubectl --context homelab get nodes
set -euo pipefail

CTX_NAME="${1:-}"
REMOTE_HOST="${2:-}"
SSH_USER="${3:-ansible}"
SSH_KEY="${4:-/apps/git-code/keys/ansible-key}"
REMOTE_PATH="${5:-/etc/kubernetes/admin.conf}"

if [[ -z "$CTX_NAME" || -z "$REMOTE_HOST" ]]; then
  echo "Usage: $0 <context-name> <host> [ssh-user] [ssh-key] [remote-path]" >&2
  exit 2
fi

KUBE_DIR="${HOME}/.kube"
LOCAL_CONFIG="${KUBE_DIR}/config"
mkdir -p "$KUBE_DIR"
chmod 700 "$KUBE_DIR"

TMP_RAW="$(mktemp "${TMPDIR:-/tmp}/kc-raw.XXXXXX")"
TMP_RENAMED="$(mktemp "${TMPDIR:-/tmp}/kc-rename.XXXXXX")"
TMP_MERGED="$(mktemp "${TMPDIR:-/tmp}/kc-merged.XXXXXX")"
trap 'rm -f "$TMP_RAW" "$TMP_RENAMED" "$TMP_MERGED"' EXIT

echo "==> fetching ${REMOTE_PATH} from ${SSH_USER}@${REMOTE_HOST}"
# sudo cat — admin.conf is root-readable only. Pipe through ssh.
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    "${SSH_USER}@${REMOTE_HOST}" "sudo cat ${REMOTE_PATH}" > "$TMP_RAW"

if ! head -1 "$TMP_RAW" | grep -q '^apiVersion:'; then
  echo "ERROR: fetched file does not look like a kubeconfig:" >&2
  head -3 "$TMP_RAW" >&2
  exit 1
fi

# Rename cluster / user / context using kubectl on the raw file.
# kubeadm produces: cluster=kubernetes user=kubernetes-admin context=kubernetes-admin@kubernetes
# Rewrite all three to the given context name for clean multi-cluster merging.
echo "==> renaming cluster/user/context to '${CTX_NAME}'"
export KUBECONFIG="$TMP_RAW"
OLD_CTX="$(kubectl config current-context)"
OLD_CLUSTER="$(kubectl config view --raw -o jsonpath="{.contexts[?(@.name=='${OLD_CTX}')].context.cluster}")"
OLD_USER="$(kubectl config view --raw -o jsonpath="{.contexts[?(@.name=='${OLD_CTX}')].context.user}")"

kubectl config rename-context "$OLD_CTX" "$CTX_NAME" >/dev/null
# kubectl has no rename-cluster / rename-user — do those via sed on the file.
sed -e "s/  name: ${OLD_CLUSTER}\$/  name: ${CTX_NAME}/" \
    -e "s/    cluster: ${OLD_CLUSTER}\$/    cluster: ${CTX_NAME}/" \
    -e "s/- name: ${OLD_USER}\$/- name: ${CTX_NAME}/" \
    -e "s/    user: ${OLD_USER}\$/    user: ${CTX_NAME}/" \
    "$TMP_RAW" > "$TMP_RENAMED"

# Merge: drop any pre-existing entries with this same name, then flatten.
unset KUBECONFIG
if [[ -f "$LOCAL_CONFIG" ]]; then
  echo "==> removing any existing '${CTX_NAME}' entries from ${LOCAL_CONFIG}"
  kubectl --kubeconfig "$LOCAL_CONFIG" config delete-context "$CTX_NAME" 2>/dev/null || true
  kubectl --kubeconfig "$LOCAL_CONFIG" config delete-cluster "$CTX_NAME" 2>/dev/null || true
  kubectl --kubeconfig "$LOCAL_CONFIG" config delete-user    "$CTX_NAME" 2>/dev/null || true
  KUBECONFIG="${LOCAL_CONFIG}:${TMP_RENAMED}" kubectl config view --flatten > "$TMP_MERGED"
else
  cp "$TMP_RENAMED" "$TMP_MERGED"
fi

install -m 0600 "$TMP_MERGED" "$LOCAL_CONFIG"
kubectl --kubeconfig "$LOCAL_CONFIG" config use-context "$CTX_NAME" >/dev/null

echo
echo "==> merged. Current contexts:"
kubectl --kubeconfig "$LOCAL_CONFIG" config get-contexts
echo
echo "==> verifying connection to '${CTX_NAME}'"
kubectl --kubeconfig "$LOCAL_CONFIG" --context "$CTX_NAME" get nodes 2>&1 | head -10 || {
  echo "WARN: 'get nodes' failed — server may be unreachable from this host." >&2
  echo "      Check the server: URL in ~/.kube/config and your network/VPN." >&2
}

echo
echo "Switch clusters with:"
echo "  kubectl config use-context <name>"
