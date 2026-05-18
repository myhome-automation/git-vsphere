# Day-to-day operations

How to shut down, power up, and otherwise wrangle the home-lab cluster.
All playbooks are under `ansible/playbooks/`.

---

## Shutdown

**Cluster-only (vault-server LEFT RUNNING) — default:**
```bash
cd ansible/
ansible-playbook -i inventory/hosts.ini --vault-password-file=.vault_pass \
  playbooks/cluster_shutdown.yml
```
Shuts down 8 VMs in order: workers → dns + lb → masters. vault-server untouched.

**Everything (cluster + vault-server) — explicit opt-in:**
```bash
ansible-playbook ... playbooks/all_shutdown.yml
```
Same order as above, then vault-server last. Use before powering off the
ESXi host or doing physical maintenance.

Uses `async: 1, poll: 0` so the ansible run doesn't hang waiting for the
SSH session it just told to die. VMs are off ~30 s after dispatch.

Verify everything actually stopped:
```bash
ssh root@192.168.1.174 'vim-cmd vmsvc/getallvms | while read v _; do \
  case $v in [0-9]*) printf "%s " $v; vim-cmd vmsvc/power.getstate $v | tail -1;; esac; done'
```

---

## Power up

**Cluster-only (assumes vault-server already running) — default:**
```bash
cd ansible/
ansible-playbook -i inventory/hosts.ini --vault-password-file=.vault_pass \
  playbooks/cluster_powerup.yml
```
Brings up dns + lb → masters → workers in dependency order.

**Everything (vault-server first, then cluster):**
```bash
ansible-playbook ... playbooks/all_powerup.yml
```
Use after a full host reboot or `all_shutdown.yml`.

Both playbooks run locally on the ansible controller (since target VMs are
off and unreachable). For each VM:
1. Look up vmid via `ssh root@192.168.1.174 vim-cmd vmsvc/getallvms`
2. Skip if already powered on
3. Otherwise `vim-cmd vmsvc/power.on <vmid>`

Then waits up to 5 min for SSH on each host (port 22 probe).

Cluster API typically reachable on `https://192.168.1.50:6443` within
~1 min of all VMs being SSHable (kubelet + control plane pods need to
re-establish).

### Powerup that "succeeds" but leaves all VMs off

Symptoms: `power on <vmid>` prints `Power on failed`; `hostd.log` says
`State Transition (VM_STATE_OFF -> VM_STATE_POWERING_ON) not allowed for this Vm`;
the playbook's wait_for SSH then times out at 5 minutes.

Root cause checklist (run in order):

1. **ESXi in maintenance mode** (most common after a dirty host shutdown).
   ```bash
   ssh root@192.168.1.174 'vim-cmd hostsvc/runtimeinfo | grep -i maintenance'
   # if inMaintenanceMode = true
   ssh root@192.168.1.174 'vim-cmd hostsvc/maintenance_mode_exit'
   ```
   Then re-run `cluster_powerup.yml`.

2. **hostd VMX cache stale** — `vim-cmd vmsvc/reload <vmid>` then retry.

3. **Worse hostd state** — `/etc/init.d/hostd restart` (safe when no VMs running).

4. **Last resort** — `/sbin/services.sh restart` followed by
   `vim-cmd vmsvc/unregister <vmid>` + `vim-cmd solo/registervm <vmx-path>`.
   (Note that re-register gives the VM a new vmid; the playbook resolves
   by name so it still finds the host.)

---

## Reset the kubernetes cluster (keep VMs)

```bash
cd ansible/
ansible-playbook -i inventory/hosts.ini --vault-password-file=.vault_pass \
  playbooks/k8s_reset.yml
```

`kubeadm reset --force` on every master and worker, plus:
- `rm -rf /var/lib/etcd /etc/cni/net.d /var/lib/cni /etc/calico /var/lib/kubelet /etc/kubernetes /root/.kube`
- Flush all iptables tables (`iptables -F`, `-t nat -F`, etc.)
- Restart containerd

After reset, run `site.yml --tags k8s,calico,istio` to rebuild the
cluster from scratch.

---

## Change pod CIDR

Tigera operator strictly enforces `Calico IPPool CIDR == kubeadm
--pod-network-cidr`. To change CIDR:

1. Edit `ansible/group_vars/all/vars.yml` → `pod_network_cidr: "10.x.x.x/16"`
2. Edit `ansible/playbooks/cni_calico.yml` → `pod_cidr: "10.x.x.x/16"` to match
3. `ansible-playbook playbooks/k8s_reset.yml` (cluster down)
4. `ansible-playbook playbooks/site.yml --tags k8s,calico,istio` (cluster back up)

Cannot be done in-place — kubeadm's pod-network-cidr is baked into
kube-controller-manager's `--cluster-cidr` flag at init time.

---

## Re-clone a single VM (recovery from corruption)

See [vault-server.md](vault-server.md) section V2 — single-clone recovery
via vmkfstools + snapshot of running vault-server.

---

## Add bstha key / SSH to a fresh host

If you just cloned a new VM and need bstha access:
```bash
ansible-playbook -i inventory/hosts.ini --vault-password-file=.vault_pass \
  playbooks/bootstrap-users.yml --limit <new-host>
```

This is idempotent and re-applies on any host in the `everyone` group.

---

## Roll one new master / worker

If a master or worker is unrecoverable:

1. ESXi side: `vim-cmd vmsvc/unregister <vmid>`, `rm -rf` the directory.
2. Re-clone via vmkfstools (see [vault-server.md](vault-server.md) V2).
3. Add to inventory (already there if you used the same name).
4. `kubectl delete node <name>` from kmaster1.
5. Run base.yml + bootstrap-users.yml + relevant k8s playbook on that one host:
   ```
   ansible-playbook playbooks/site.yml --limit <new-host> --tags base,k8s
   ```

---

## Cluster reach-out test (after powerup)

```bash
# From the packer host
ssh -i /apps/git-code/keys/ansible-key ansible@192.168.1.186 \
  'sudo KUBECONFIG=/root/.kube/config kubectl get nodes -o wide; \
   sudo KUBECONFIG=/root/.kube/config kubectl get pods -A | head -20'

# DNS
dig @192.168.1.188 kmaster1.myhomelab.com +short    # forward
dig @192.168.1.188 -x 192.168.1.186 +short          # reverse

# k8s API via VIP
curl -k https://192.168.1.50:6443/healthz           # should return ok
```

---

## LB-pair operations

### Check VIP holder
```bash
for h in lb1 lb2; do
  echo "-- $h --"
  ssh ansible@$h 'ip -4 addr show ens192 | grep 192.168.1.50 || echo "no VIP"'
done
```
Exactly one of them should print the VIP line. If neither does, both
keepalived units are down — start with `systemctl status keepalived`.

### Verify both boxes are fully provisioned
Per-host snapshot — `haproxy`, `keepalived`, `dnsmasq` must all be `active`:
```bash
for h in lb1 lb2; do
  echo "-- $h --"
  ssh ansible@$h 'for s in haproxy keepalived dnsmasq; do
    printf "%-12s %s\n" "$s" "$(systemctl is-active $s)"
  done'
done
```

### Test failover (intentional, ~3 s disruption)
```bash
ssh ansible@lb1 'sudo systemctl stop keepalived'           # remove MASTER
sleep 4
ssh ansible@lb2 'ip -4 addr show ens192 | grep 192.168.1.50'   # VIP migrated
dig @192.168.1.50 kmaster1.myhomelab.com +short                # DNS still works
curl -sk https://192.168.1.50:6443/healthz                     # API still works
ssh ansible@lb1 'sudo systemctl start keepalived'          # VIP returns (preempt)
```

### Force a planned switchover (without "killing" lb1)
keepalived re-reads the config on `reload`; lowering lb1's priority
below lb2's makes lb2 become MASTER cleanly.
```bash
ssh ansible@lb1 'sudo sed -i "s/priority 101/priority 99/" /etc/keepalived/keepalived.conf'
ssh ansible@lb1 'sudo systemctl reload keepalived'
# work happens on lb1 (e.g. dnf update, reboot) — lb2 holds VIP throughout
ssh ansible@lb1 'sudo sed -i "s/priority 99/priority 101/" /etc/keepalived/keepalived.conf'
ssh ansible@lb1 'sudo systemctl reload keepalived'         # lb1 reclaims VIP
```

### Recover one LB after an extended outage
After lb2 was off for a while (e.g. rebuild):
```bash
# Re-fetch any DNS zone updates / firewall rules
ansible-playbook ... playbooks/site.yml --limit lb2 --tags dns,lb
# Confirm dnsmasq + keepalived + haproxy come up
ssh ansible@lb2 'for s in haproxy keepalived dnsmasq; do systemctl is-active $s; done'
```

---

## Kubeconfig on the workstation (multi-cluster)

The workstation runs a **local k3OS cluster** (used for building docker
images) alongside the **homelab** vsphere cluster, so `~/.kube/config`
holds both as named contexts. Switch with `kubectl config use-context`.

**One-time fetch / refresh of the homelab kubeconfig:**
```bash
scripts/fetch-kubeconfig.sh homelab 192.168.1.186
# - ssh's to kmaster1, sudo-reads /etc/kubernetes/admin.conf
# - renames cluster/user/context to "homelab"
# - merges into ~/.kube/config (atomically; preserves other contexts)
# - verifies the connection
```

The script is generic — re-use it for any future cluster:
```bash
scripts/fetch-kubeconfig.sh <ctx-name> <master-host> [ssh-user] [ssh-key] [remote-path]

# Examples:
scripts/fetch-kubeconfig.sh homelab     192.168.1.186                      # this repo's defaults
scripts/fetch-kubeconfig.sh staging     10.0.0.5 ubuntu ~/.ssh/staging.pem
scripts/fetch-kubeconfig.sh k3s-edge    edge.lan root ~/.ssh/edge.key /etc/rancher/k3s/k3s.yaml
```

Daily use:
```bash
kubectl config get-contexts                     # see all clusters
kubectl config use-context homelab              # vsphere cluster
kubectl config use-context k3os-local           # local workstation cluster (docker builds)

# Or per-command without flipping current-context:
kubectl --context homelab get nodes
kubectl --context k3os-local get nodes
```

The homelab kubeconfig's server URL is `https://192.168.1.50:6443` (the
keepalived VIP), so any one master going down doesn't break kubectl as
long as lb1 + at least one master are up.

---

## Vault — unseal and crash-loop recovery (on local k3s)

Vault on `k3os-local` starts up **sealed** after every pod restart. The
helm chart's liveness probe MUST tolerate sealed state (`sealedcode=204`)
or the kubelet will kill the pod before you can run
`vault operator unseal`. The fix lives in `argocd/vault.yaml` +
`vault/values.yaml` (commit `d6d838e`, 2026-05-18) — verify the
StatefulSet's liveness path includes `sealedcode=204`:

```bash
kubectl --context k3os-local -n vault get sts vault \
  -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.httpGet.path}{"\n"}'
# expect: /v1/sys/health?standbyok=true&sealedcode=204&uninitcode=204
```

### Unseal one or all pods

```bash
# All pods, applying first 3 unseal keys from init.json
for r in vault-0 vault-1 vault-2; do
  jq -r '.unseal_keys_b64[:3][]' ~/.vault/init.json | while read key; do
    kubectl --context k3os-local -n vault exec $r -- \
      vault operator unseal "$key" 2>/dev/null || true
  done
done

# Confirm
kubectl --context k3os-local -n vault exec vault-0 -- vault status | grep -E "Sealed|HA Mode"
```

### Service routing — leader-only vs all pods

There are 4 Services in the `vault` namespace; the relevant NodePorts:

| Service | NodePort | Selector | Use for |
|---|---|---|---|
| `vault` | 30200 | all pods (ready) | DON'T use — load-balances over sealed pods too |
| `vault-active` | **31326** | leader only | what the edge nginx upstream points at |
| `vault-standby` | 32012 | followers | rarely needed |

### vault-1 still CrashLoopBackOff after fix

That's the Calico IPPool overlap — `192.168.0.0/16` ∩ home `192.168.1.0/24`
blocks pod-to-pod traffic for vault-1's allocated pod IP. Workaround applied:
the `k3s-pod-masq.service` systemd unit on gdragon masquerades pod →
external. Proper destructive fix: migrate the Calico IPPool to a
non-overlapping CIDR (rebuilds all pods on k3s). See `vault/README.md`.

---

## Edge nginx-proxy on .203 — rebuild + redeploy

The proxy config (`nginx-proxy/nginx.conf`) is baked into the image, so any
routing change needs a new image. Tag scheme: `homelab-proxy-X.Y`.

```bash
# 1. Edit nginx-proxy/nginx.conf locally and commit.
$EDITOR nginx-proxy/nginx.conf

# 2. Push build context to .203 and build there (rootless podman).
scp nginx-proxy/{Dockerfile,nginx.conf} bstha@192.168.1.203:/tmp/
ssh bstha@192.168.1.203 \
  'cd /tmp && podman build -t quay.io/bpraisa/nginx:homelab-proxy-1.5 .'

# 3. Push to quay (bootstrap login once via playbook if needed).
ansible-playbook -i inventory/hosts.ini --vault-password-file=.vault_pass \
  playbooks/quay-login.yml          # idempotent — refreshes authfile
ssh bstha@192.168.1.203 \
  'podman push --authfile ~/.config/containers/auth.json \
   quay.io/bpraisa/nginx:homelab-proxy-1.5'

# 4. Bump install.sh default and re-run it.
sed -i 's/homelab-proxy-1.4/homelab-proxy-1.5/' nginx-proxy/install.sh
bash nginx-proxy/install.sh 192.168.1.203
```

If a new tag was pushed but `install.sh` already had the right tag, just
manually rotate:

```bash
ssh bstha@192.168.1.203 '
  for n in nginx-1:80 nginx-2:8080; do
    name=${n%%:*}; port=${n##*:}
    podman rm -f $name >/dev/null 2>&1
    podman run -d --restart=always --name $name -p ${port}:80 \
      quay.io/bpraisa/nginx:homelab-proxy-1.5
  done
  podman ps --format "{{.Names}} {{.Image}}"
'
```

### Verify all six paths after a deploy

```bash
for p in / /grafana/ /prometheus/ /loki/ready /ui/ /argocd/ /v1/sys/health; do
  printf "%-22s %s\n" "$p" \
    "$(curl -sSL -o /dev/null -w '%{http_code} %{url_effective}' http://192.168.1.203$p)"
done
# all should be 2xx (or 200 after redirect-follow)
```

---

## Push a new image to quay.io

The robot account credentials are in ansible-vault
(`group_vars/all/vault.yml` → `vault_quay_username` / `vault_quay_password`)
and the `quay-login.yml` playbook persists `auth.json` on the edge_proxy
host.

```bash
# Bootstrap or refresh the persistent authfile
ansible-playbook -i inventory/hosts.ini --vault-password-file=.vault_pass \
  playbooks/quay-login.yml

# Then push anything that's been tagged for quay
ssh bstha@192.168.1.203 \
  'podman push --authfile ~/.config/containers/auth.json quay.io/bpraisa/<repo>:<tag>'
```

### "unauthorized" on push to a new quay repo

quay.io robot accounts are scoped **per-repo**, not org-wide. A freshly
created repo doesn't grant your existing robot anything by default.

Symptom:
```
Error: writing blob: initiating layer upload to /v2/bpraisa/<new-repo>/blobs/uploads/
  in quay.io: unauthorized: access to the requested resource is not authorized
```

Fix: at `https://quay.io/repository/bpraisa/<new-repo>` →
`Settings → User and Robot Permissions` → add the robot with **Write**
access. Then retry the push.
