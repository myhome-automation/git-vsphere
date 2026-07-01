#!/usr/bin/env bash
# Rebuild the two SEPARATE kubeconfig files on the edge-203 control host so it
# can reach BOTH clusters:
#   ~/.kube/k8s.conf  -> context 'k8s'  -> kubeadm cluster via VIP 192.168.1.50:6443
#   ~/.kube/k3s.conf  -> context 'k3s'  -> gdragon's k3s   via 192.168.1.181:6443
#
# They are kept as separate files (NOT merged into ~/.kube/config) and exposed
# to kubectl together via KUBECONFIG (set in ~/.bashrc):
#   export KUBECONFIG="$HOME/.kube/k8s.conf:$HOME/.kube/k3s.conf"
# Switch with:  kubectl config use-context k8s | k3s
#
# Reproducible / idempotent — safe to re-run (e.g. after a rebuild of .203).
# Both kubeconfigs are cluster-admin credentials — mode 0600, NEVER commit them.
#
# Prereqs on .203:
#   - kubectl on PATH (matching-ish minor; install v1.36.1 for the kubeadm cluster).
#   - Fleet SSH key at /apps/git-code/keys/ansible-key (reaches ansible@kmaster1).
#   - Dedicated gdragon key ~/.ssh/gdragon_ed25519 authorized for bstha@192.168.1.181
#     (ssh 'gdragon' alias in ~/.ssh/config). gdragon firewalld already allows
#     .203 -> 6443 (public-zone rich rule).
set -euo pipefail

KUBE_DIR="${HOME}/.kube"
mkdir -p "$KUBE_DIR"; chmod 700 "$KUBE_DIR"

# --- k8s: kubeadm cluster (admin.conf already advertises the VIP .50) ----------
K8S_KEY="${K8S_KEY:-/apps/git-code/keys/ansible-key}"
K8S_HOST="${K8S_HOST:-192.168.1.186}"          # kmaster1
echo "==> fetching kubeadm admin.conf from ansible@${K8S_HOST}"
ssh -i "$K8S_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    "ansible@${K8S_HOST}" 'sudo cat /etc/kubernetes/admin.conf' > "${KUBE_DIR}/k8s.conf.raw"
# rename cluster/user/context -> k8s (kubeadm ships cluster=kubernetes,
# user=kubernetes-admin, context=kubernetes-admin@kubernetes)
sed -i -e 's/^  name: kubernetes$/  name: k8s/' \
       -e 's/^    cluster: kubernetes$/    cluster: k8s/' \
       -e 's/^- name: kubernetes-admin$/- name: k8s/' \
       -e 's/^    user: kubernetes-admin$/    user: k8s/' \
       -e 's/^  name: kubernetes-admin@kubernetes$/  name: k8s/' \
       -e 's/^current-context: kubernetes-admin@kubernetes$/current-context: k8s/' \
       "${KUBE_DIR}/k8s.conf.raw"
install -m 0600 "${KUBE_DIR}/k8s.conf.raw" "${KUBE_DIR}/k8s.conf"
rm -f "${KUBE_DIR}/k8s.conf.raw"

# --- k3s: gdragon (k3s.yaml advertises 127.0.0.1 -> rewrite to gdragon LAN IP) --
K3S_SSH="${K3S_SSH:-gdragon}"                   # ~/.ssh/config alias -> bstha@192.168.1.181
K3S_IP="${K3S_IP:-192.168.1.181}"
echo "==> fetching k3s.yaml from ${K3S_SSH}"
ssh -o BatchMode=yes "$K3S_SSH" 'sudo cat /etc/rancher/k3s/k3s.yaml' > "${KUBE_DIR}/k3s.conf.raw"
sed -i -e "s#server: https://127.0.0.1:6443#server: https://${K3S_IP}:6443#" \
       -e 's/^  name: default$/  name: k3s/' \
       -e 's/^    cluster: default$/    cluster: k3s/' \
       -e 's/^- name: default$/- name: k3s/' \
       -e 's/^    user: default$/    user: k3s/' \
       -e 's/^current-context: default$/current-context: k3s/' \
       "${KUBE_DIR}/k3s.conf.raw"
install -m 0600 "${KUBE_DIR}/k3s.conf.raw" "${KUBE_DIR}/k3s.conf"
rm -f "${KUBE_DIR}/k3s.conf.raw"

# --- ensure KUBECONFIG is wired in ~/.bashrc -----------------------------------
if ! grep -q 'KUBECONFIG=.*k8s.conf' "${HOME}/.bashrc" 2>/dev/null; then
  {
    echo ''
    echo '# Separate kubeconfig per cluster (k8s = kubeadm VIP .50; k3s = gdragon .181), merged for kubectl'
    echo 'export KUBECONFIG="$HOME/.kube/k8s.conf:$HOME/.kube/k3s.conf"'
  } >> "${HOME}/.bashrc"
  echo "==> added KUBECONFIG to ~/.bashrc"
fi

export KUBECONFIG="${KUBE_DIR}/k8s.conf:${KUBE_DIR}/k3s.conf"
echo; echo "==> contexts:"; kubectl config get-contexts
echo; echo "==> k8s nodes:"; kubectl --context k8s get nodes --no-headers 2>&1 | head
echo; echo "==> k3s nodes:"; kubectl --context k3s get nodes --no-headers 2>&1 | head
