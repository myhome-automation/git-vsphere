#!/usr/bin/env bash
# platform-startup.sh — bring the whole home lab UP in dependency order after a
# cold boot / power outage. Run from gdragon (192.168.1.181, the Ansible control
# host + repo host). Idempotent; safe to re-run.
#
# Dependency order (nothing here depends on something started later):
#   1. ESXi host          (must be out of maintenance mode)
#   0. DNS (.203)          authoritative biplextech.com runs on the ALWAYS-ON
#                          Ubuntu edge box — NOT on ESXi — so it's already up
#                          before this script runs (moved off .202 2026-06-24).
#   3. Load balancers      lb1 .188 (VIP MASTER) -> lb2 .185 (BACKUP)
#   4. Control plane       kmaster1/2/3
#   5. Workers             kworker1/2/3
#   6. Platform (GitOps)   ArgoCD self-reconciles: MetalLB -> Longhorn(StorageClass)
#                          -> cert-manager/ingress(.51) -> Vault -> Consul -> ...
#   7. Vault unseal        (Vault always boots SEALED)
#   8. Mgmt/security        gdragon k3s (AWX/OpenVAS) + edge nginx .203 (systemd)
#
# See docs/cold-boot-resilience.md (no circular deps) and docs/architecture.md.
set -uo pipefail

REPO=/apps/git-code/git-vsphere
ANS="$REPO/ansible"
ESXI=192.168.1.174
KEY=/apps/git-code/keys/ansible-key
MASTER=192.168.1.186
K3S=/usr/local/bin/k3s
VAULT_KEYS="$HOME/.vault/biplextech-init.json"   # created at `vault operator init`; NEVER commit
k(){ ssh -o StrictHostKeyChecking=no -i "$KEY" ansible@"$MASTER" "sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf $*"; }

echo "== 1/8  ESXi host: clear maintenance mode (silent power-on killer) =="
ssh -o StrictHostKeyChecking=no root@"$ESXI" \
  'vim-cmd hostsvc/maintenance_mode_exit 2>/dev/null; vim-cmd hostsvc/runtimeinfo | grep -i maintenance'

echo "== 2-5/8  Power on the 8 cluster VMs (lb -> masters -> workers) =="
# cluster_powerup.yml: lb1,lb2,masters,workers; waits for SSH on each.
# vault-server (.202) is POWERED OFF / decommissioned (2026-06-24) — its DNS role
# moved to the always-on .203 edge box, Vault runs in-cluster, and its RAM/CPU is
# reserved for boosting the cluster later. Use all_powerup.yml only if you ever
# need to revive that VM.
cd "$ANS"
ANSIBLE_CONFIG="$PWD/ansible.cfg" ansible-playbook playbooks/cluster_powerup.yml || {
  echo "powerup playbook failed — check ESXi + VM state"; exit 1; }

echo "== 5b/8  FORCE CLOCK STEP on every node (CRITICAL) =="
# The ESXi host clock drifts; VMware-Tools syncs VMs to the wrong time on boot.
# Even a few minutes of skew makes etcd time out -> apiservers CrashLoopBackOff
# -> cluster-wide Forbidden. Step the clock BEFORE expecting k8s to be healthy.
for ip in 188 185 186 189 187 182 183 184; do
  timeout 15 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$KEY" \
    ansible@192.168.1.$ip 'sudo chronyc makestep >/dev/null 2>&1 && echo "  .'$ip' stepped"' 2>&1 || true
done

echo "== wait for k8s API (VIP 192.168.1.50:6443) =="
for _ in $(seq 1 30); do k get nodes >/dev/null 2>&1 && break; sleep 10; done
k get nodes || echo "  WARN: k8s API not ready yet — re-check clocks (chronyc tracking)"

echo "== 6/8  Wait for GitOps storage + ingress (MetalLB -> Longhorn -> ingress .51) =="
for _ in $(seq 1 40); do
  sc=$(k get storageclass --no-headers 2>/dev/null | wc -l)
  ip=$(k -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  echo "  storageclasses=$sc  ingressIP=${ip:-none}"
  [ "${sc:-0}" -ge 1 ] && [ "$ip" = "192.168.1.51" ] && break
  sleep 15
done

echo "== 7/8  Unseal Vault (boots sealed) =="
if [ -f "$VAULT_KEYS" ] && command -v jq >/dev/null; then
  for r in vault-0 vault-1 vault-2; do
    jq -r '.unseal_keys_b64[:3][]' "$VAULT_KEYS" | while read -r key; do
      k -n vault exec "$r" -- vault operator unseal "$key" >/dev/null 2>&1 || true
    done
  done
  k -n vault exec vault-0 -- vault status 2>/dev/null | grep -E 'Sealed|HA Mode' || true
else
  echo "  SKIP: $VAULT_KEYS not found. Vault not initialized yet, OR keys missing."
  echo "  First boot only — initialize once:"
  echo "    kubectl -n vault exec vault-0 -- vault operator init -key-shares=5 -key-threshold=3 -format=json > $VAULT_KEYS"
  echo "    chmod 600 $VAULT_KEYS   # NEVER commit"
fi

echo "== 8/8  Mgmt/security tier =="
echo "  gdragon k3s:"; systemctl is-active k3s 2>/dev/null && sudo "$K3S" kubectl get pods -A --no-headers 2>/dev/null | grep -E 'awx|openvas' || true
echo "  edge nginx .203:"; ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 bstha@192.168.1.203 'systemctl is-active nginx' 2>/dev/null || true

echo
echo "STARTUP COMPLETE. Endpoints: see docs/architecture.md (## Endpoints)."
