#!/usr/bin/env bash
# platform-startup.sh — bring the whole home lab UP in dependency order after the
# NIGHTLY shutdown / a cold boot. Run from gdragon (192.168.1.181, the Ansible
# control host + repo host). Idempotent; safe to re-run.
#
# ── Dependency order (nothing depends on something started later) ─────────────
#   0. gdragon k3s + edge .203   already up (k3s/nginx/dnsmasq auto-start on boot)
#   1. TRANSIT (auto-unseal) Vault on gdragon k3s  -> UNSEAL it (boots sealed).
#        The ESXi-cluster Vault auto-unseals against this, so it MUST be unsealed
#        BEFORE the cluster Vault pods start. Keys: ~/.vault/transit-init.json.
#   2. ESXi host                 clear maintenance mode (silent power-on killer)
#   3. Cluster VMs               lb1/lb2 -> kmaster1/2/3 -> kworker1/2/3
#   4. Clocks                    chronyc makestep on every node (etcd needs it)
#   5. kubelet sysctls           re-assert (protectKernelDefaults; not persisted)
#   6. Platform (GitOps)         ArgoCD self-reconciles MetalLB -> Longhorn ->
#                                cert-manager/ingress(.51) -> Vault(AUTO-unseals)
#                                -> Consul -> Gatekeeper -> Prometheus -> Jenkins
#   7. Verify Vault HA           all 3 AUTO-unsealed via transit (no manual keys)
#   8. Mgmt/security             AWX/OpenVAS (gdragon k3s) + edge nginx (.203)
#   9. OpenVAS scan              auto-start 'Scan all homelab hosts' (all hosts up)
#
# DNS for biplextech.com is authoritative on the always-on .203 edge box (NOT in
# the ESXi cluster, NOT on the decommissioned .202 VM). See docs/architecture.md
# and docs/cold-boot-resilience.md.
set -uo pipefail

REPO=/apps/git-code/git-vsphere
ANS="$REPO/ansible"
ESXI=192.168.1.174
KEY=/apps/git-code/keys/ansible-key
EDGE_KEY=$HOME/.ssh/id_ed25519
MASTER=192.168.1.186
K3S=/usr/local/bin/k3s
TRANSIT_KEYS="$HOME/.vault/transit-init.json"   # gdragon transit Vault (chmod 600, NEVER commit)
k(){ ssh -o StrictHostKeyChecking=no -i "$KEY" ansible@"$MASTER" "sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf $*"; }
kk(){ sudo "$K3S" kubectl "$@"; }   # gdragon k3s

echo "== 1/8  Unseal the TRANSIT (auto-unseal) Vault on gdragon k3s =="
# The cluster Vault can't auto-unseal until this one is unsealed + reachable
# (192.168.1.181:8200). gdragon k3s + this pod auto-start on boot, but Vault
# always boots SEALED.
if kk -n vault-transit get pod vault-transit-0 >/dev/null 2>&1; then
  for _ in $(seq 1 20); do kk -n vault-transit get pod vault-transit-0 -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running && break; sleep 5; done
  if [ -f "$TRANSIT_KEYS" ] && command -v jq >/dev/null; then
    UKEY=$(jq -r '.unseal_keys_b64[0]' "$TRANSIT_KEYS")
    kk -n vault-transit exec vault-transit-0 -- sh -c "VAULT_ADDR=http://127.0.0.1:8200 vault operator unseal '$UKEY'" >/dev/null 2>&1 || true
    echo "  transit Vault: $(kk -n vault-transit exec vault-transit-0 -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 vault status' 2>/dev/null | grep Sealed | tr -s ' ')"
  else
    echo "  WARN: $TRANSIT_KEYS missing — cannot unseal transit Vault (cluster Vault will stay sealed)."
  fi
else
  echo "  NOTE: no vault-transit deployment on gdragon k3s (kubectl apply gdragon/vault-transit/vault-transit.yaml)."
fi

echo "== 2/8  ESXi host: clear maintenance mode =="
ssh -o StrictHostKeyChecking=no root@"$ESXI" \
  'vim-cmd hostsvc/maintenance_mode_exit 2>/dev/null; vim-cmd hostsvc/runtimeinfo | grep -i maintenance'

echo "== 3/8  Power on the 8 cluster VMs (lb -> masters -> workers) =="
# vault-server (.202) is DECOMMISSIONED (DNS moved to .203; RAM/CPU reclaimed for
# the 8 GB masters). cluster_powerup.yml powers on lb1/lb2 + 3 masters + 3 workers.
cd "$ANS"
ANSIBLE_CONFIG="$PWD/ansible.cfg" ansible-playbook playbooks/cluster_powerup.yml || {
  echo "powerup playbook failed — check ESXi + VM state"; exit 1; }

echo "== 4/8  FORCE CLOCK STEP on every node (CRITICAL) =="
# VMware-Tools periodic sync is DISABLED (base.yml) so the clock no longer drifts
# while running, but a boot-time sync can still skew it once. Step it before k8s.
for ip in 188 185 186 189 187 182 183 184; do
  timeout 15 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$KEY" \
    ansible@192.168.1.$ip 'sudo chronyc makestep >/dev/null 2>&1 && echo "  .'$ip' stepped"' 2>&1 || true
done

echo "== 5/8  RE-ASSERT kubelet sysctls on every k8s node (CRITICAL) =="
# kubelet protectKernelDefaults=true asserts these and refuses to start if unset.
# Persisted in /etc/sysctl.d/99-kubelet.conf (k8s_harden.yml); re-assert as a net.
for ip in 186 189 187 182 183 184; do
  timeout 25 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$KEY" \
    ansible@192.168.1.$ip 'sudo bash -c "
      printf \"vm.overcommit_memory = 1\nkernel.panic = 10\nkernel.panic_on_oops = 1\n\" > /etc/sysctl.d/99-kubelet.conf
      sysctl -p /etc/sysctl.d/99-kubelet.conf >/dev/null 2>&1
      systemctl is-active --quiet kubelet || systemctl restart kubelet
      echo \"  .'$ip' kubelet=\$(systemctl is-active kubelet)\""' 2>&1 || echo "  .$ip unreachable"
done

echo "== wait for k8s API (VIP 192.168.1.50:6443) =="
for _ in $(seq 1 30); do k get nodes >/dev/null 2>&1 && break; sleep 10; done
k get nodes || echo "  WARN: k8s API not ready — re-check clocks/sysctls (chronyc tracking, kubelet)."

echo "== 6/8  Wait for GitOps storage + ingress (MetalLB -> Longhorn -> ingress .51) =="
for _ in $(seq 1 40); do
  sc=$(k get storageclass --no-headers 2>/dev/null | wc -l)
  ip=$(k -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  echo "  storageclasses=$sc  ingressIP=${ip:-none}"
  [ "${sc:-0}" -ge 1 ] && [ "$ip" = "192.168.1.51" ] && break
  sleep 15
done

echo "== 7/8  Verify Vault HA auto-unsealed (transit — NO manual keys) =="
# With the transit Vault unsealed (step 1), the 3 cluster Vault pods auto-unseal
# on startup. Just verify; if any stays sealed, the transit Vault is unreachable.
for _ in $(seq 1 12); do
  n=$(for p in vault-0 vault-1 vault-2; do k -n vault exec $p -- vault status 2>/dev/null | awk '/Sealed/{print $2}'; done | grep -c false)
  echo "  unsealed vault pods: ${n:-0}/3"
  [ "${n:-0}" = "3" ] && break
  sleep 10
done
[ "${n:-0}" = "3" ] || echo "  WARN: Vault not fully unsealed — check transit Vault (gdragon) + 192.168.1.181:8200 reachability."

echo "== 8/9  Mgmt/security tier =="
echo "  gdragon k3s:"; systemctl is-active k3s 2>/dev/null && kk get pods -A --no-headers 2>/dev/null | grep -E 'awx|openvas' || true
echo "  edge nginx .203:"; ssh -o StrictHostKeyChecking=no -i "$EDGE_KEY" bstha@192.168.1.203 'systemctl is-active nginx dnsmasq' 2>/dev/null || true

echo "== 9/9  Kick off the OpenVAS scan (after-reboot vuln scan of all hosts) =="
# Auto-start the 'Scan all homelab hosts' task once gvmd is responsive. All hosts
# are up by now (cluster powered on above). OpenVAS admin password is read LIVE
# from the openvas-admin Secret (NOT in git). Bounded waits — never hangs.
OVPOD=$(kk -n security get pod -l app=openvas -o name 2>/dev/null | head -1); OVPOD=${OVPOD#pod/}
if [ -n "$OVPOD" ]; then
  OVPW=$(kk -n security get secret openvas-admin -o jsonpath='{.data.PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null)
  GVM(){ kk -n security exec "$OVPOD" -- su -s /bin/sh gvm -c "gvm-cli --gmp-username admin --gmp-password '$OVPW' socket --socketpath /run/gvmd/gvmd.sock --xml '$1'" 2>/dev/null; }
  echo "  waiting for gvmd (loads VTs after boot)..."
  for _ in $(seq 1 30); do GVM '<get_version/>' | grep -q 'status="200"' && break; sleep 10; done
  TASK="Scan all homelab hosts"
  TID=$(GVM '<get_tasks/>' | tr '>' '>\n' | grep -B1 "<name>$TASK</name>" | grep -oE 'task id="[^"]+"' | head -1 | sed 's/task id="//;s/"//')
  if [ -n "$TID" ]; then
    st=$(GVM "<get_tasks task_id=\"$TID\"/>" | grep -oE '<status>[A-Za-z]+</status>' | head -1 | sed 's/<[^>]*>//g')
    if echo "$st" | grep -qiE 'Running|Requested|Queued'; then echo "  task already $st"; else GVM "<start_task task_id=\"$TID\"/>" | grep -oE 'status_text="[^"]*"' | sed 's/^/  start: /'; fi
  else
    echo "  WARN: task '$TASK' not found (create it in OpenVAS first)."
  fi
else
  echo "  OpenVAS pod not found — skipping scan kickoff."
fi

echo
echo "STARTUP COMPLETE. Apps/URLs/creds: docs/ACCESS.md"
