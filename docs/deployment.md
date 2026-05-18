# Deployment runbook — zero to running cluster

End-to-end procedure to bring up the full 9-VM stack from a clean
ESXi host with a working `vault-server` template. For the
architecture, see [architecture.md](architecture.md); for issues hit
along the way, see the per-component troubleshooting files in
[README.md](README.md).

---

## 0. Preconditions

On the ESXi host (`192.168.1.174`):
- `vault-server` VM exists, Rocky 9.7, powered on or off, manually bootstrapped with:
  - `ansible` user, NOPASSWD sudo, ed25519 key authorized
  - `ipv6.disable=1` (sysctl + grub)
  - GUI removed (`dnf groupremove "Server with GUI"`)

On the workstation:
- `/apps/git-code/git-vsphere/` checked out
- `/apps/git-code/keys/ansible-key` and `.pub` present
- ansible + python3 installed; `ansible.cfg` configured (already in repo)
- `ansible/.vault_pass` populated (file is gitignored)
- `ansible/inventory/group_vars` symlink: `ln -sfn ../group_vars ansible/inventory/group_vars`
- root SSH to ESXi works: `ssh root@192.168.1.174 'echo ok'`

---

## 1. Clone the 8 cluster VMs from vault-server

```bash
cd /apps/git-code/git-vsphere
bash terraform/clone-from-vault.sh
```

The script (driver runs locally, work is piped to ESXi as POSIX `sh`):

1. Powers off vault-server (graceful, 30 s timeout, hard fallback).
2. `vmkfstools -i ... -d thin` × 9 in parallel — thin clones of
   vault-server's vmdk into per-VM directories.
3. Generates a fresh VMX per clone (new UUID + MAC, role-appropriate
   CPU/RAM/disk size).
4. `vim-cmd solo/registervm` × 9.
5. Powers vault-server back ON first, then powers on all 9 clones.
6. Waits up to 5 minutes for VMware Tools to report DHCP-assigned IPs.
7. Writes `ansible/inventory/hosts.ini` from the discovered IPs.

> Edit the inventory afterward to add the per-host `keepalived_state` /
> `keepalived_priority` for lb1 / lb2 — the script doesn't populate
> these yet. See `ansible/inventory/hosts.ini.example`.

Verify clones came up:
```bash
ansible -i ansible/inventory/hosts.ini --vault-password-file=ansible/.vault_pass \
  everyone -m ping
```

---

## 2. Bootstrap `bstha` user on every host

```bash
cd ansible/
ansible-playbook -i inventory/hosts.ini --vault-password-file=.vault_pass \
  playbooks/bootstrap-users.yml
```

Adds the `bstha` user with NOPASSWD sudo + ed25519 key on all 9 hosts
(via the `everyone` group, which includes vault-server).

---

## 3. Provision the cluster

The default `site.yml` runs every stage in order:

```bash
ansible-playbook -i inventory/hosts.ini --vault-password-file=.vault_pass \
  playbooks/site.yml
```

What runs and what each tag covers:

| Stage | Tag(s) | Playbook | Targets | What happens |
|-------|--------|----------|---------|---------------|
| 1 | `base` | base.yml | `cluster` (excludes vault) | LVM extend, hostname, SSH lockdown, common pkgs, ipv6 off, firewalld, timezone |
| 2 | `dns` | dns.yml | `loadbalancers` (lb1+lb2) | dnsmasq HA pair with bind-dynamic; resolver play points `everyone` at the VIP |
| 3 | `lb` | loadbalancer.yml | `loadbalancers` | HAProxy + keepalived MASTER/BACKUP (state/priority from inventory vars) |
| 4 | `k8s_master` (+ `k8s`) | k8s_master.yml | `k8s_masters` | containerd, kubeadm init kmaster1 with `--control-plane-endpoint=192.168.1.50:6443`, join kmaster2/3 (serial:1) |
| 5 | `k8s_worker` (+ `k8s`) | k8s_worker.yml | `k8s_workers` | containerd, kubeadm join × 3 |
| 6 | `calico` (+ `cni`, `k8s`) | cni_calico.yml | `kmaster1` | Tigera operator, Installation CR with `cidr: 10.0.0.0/16`, replace Flannel |
| 7 | `istio` (+ `mesh`, `k8s`) | istio.yml | `kmaster1` | istioctl install, profile `default`, label `default` ns for sidecar injection |

Re-runnable on individual stages:
```bash
ansible-playbook ... playbooks/site.yml --tags base
ansible-playbook ... playbooks/site.yml --tags dns,lb
ansible-playbook ... playbooks/site.yml --tags k8s,calico,istio
ansible-playbook ... playbooks/site.yml --skip-tags update   # skip slow `dnf *update*`
```

Total wall time on first run: roughly **20-30 min** (most is `dnf
update` on 9 hosts; `--skip-tags update` cuts it to ~10 min).

---

## 4. Fetch the kubeconfig to the workstation

```bash
scripts/fetch-kubeconfig.sh homelab 192.168.1.186
```

Merges the cluster as context `homelab` into `~/.kube/config` alongside
any other clusters (e.g. the `k3os-local` workstation cluster used for
image builds). Switch with `kubectl config use-context homelab`.

The script handles ssh-as-ansible + sudo, kubeconfig rename, atomic
merge, and a connectivity smoke test. Re-runnable any time — replaces
the existing `homelab` entry.

---

## 5. Verification checklist

```bash
# All 6 k8s nodes Ready
kubectl --context homelab get nodes
# Expected: 3 control-plane + 3 worker, STATUS=Ready, VERSION=v1.36.1

# All system pods Running
kubectl --context homelab get pods -A | grep -v Running | grep -v Completed
# Expected: only header line

# Calico is healthy
kubectl --context homelab get tigerastatus
# Expected: apiserver/calico True/True; ippools may show stale Degraded
# (see docs/calico.md C2 — cosmetic, IPPool itself is fine)

# Calico BGP between nodes
POD=$(kubectl --context homelab -n calico-system get pod -l k8s-app=calico-node -o name | head -1)
kubectl --context homelab -n calico-system exec $POD -c calico-node -- /bin/calico-node -felix-ready -bird-ready
# Expected: exit 0; no "BGP not established"

# Istio control plane
kubectl --context homelab -n istio-system get pods
# Expected: istiod + istio-ingressgateway both 1/1 Running

# DNS via VIP
dig @192.168.1.50 kmaster1.myhomelab.com +short    # 192.168.1.186
dig @192.168.1.50 -x 192.168.1.186 +short          # kmaster1.myhomelab.com.

# k8s API via VIP
curl -sk https://192.168.1.50:6443/healthz         # ok

# LB pair state
ssh ansible@lb1 'ip -4 addr show ens192 | grep 192.168.1.50'   # MASTER has VIP
ssh ansible@lb2 'ip -4 addr show ens192 | grep 192.168.1.50'   # BACKUP — no VIP

# Failover sanity (optional, ~10 s of disruption)
ssh ansible@lb1 'sudo systemctl stop keepalived'
sleep 4
ssh ansible@lb2 'ip -4 addr show ens192 | grep 192.168.1.50'   # VIP moved here
curl -sk https://192.168.1.50:6443/healthz                     # still ok
ssh ansible@lb1 'sudo systemctl start keepalived'              # VIP returns
```

---

## 6. After-deploy artifacts

| Path | What | Notes |
|------|------|-------|
| `~/.kube/config` (workstation) | Merged kubeconfig | Contexts: `homelab`, `k3os-local` |
| `/root/.kube/config` (kmaster1) | Admin kubeconfig | Server already points at VIP |
| `/root/kubeadm-init.log` (kmaster1) | kubeadm init output | Has join tokens (expired after 24 h) |
| `/opt/istio/istio-1.27.2/` (kmaster1) | istioctl + samples/ | `samples/addons/` for Kiali/Grafana/Jaeger |
| `/etc/dnsmasq.hosts.d/myhomelab.hosts` (lb1, lb2) | Internal A/PTR zone | Identical on both LBs |

---

## 7. Common deployment-time gotchas

| Symptom | Where it bites | Fix |
|---------|----------------|-----|
| `'vip' is undefined` etc. in plays | group_vars not auto-loaded | Check `ansible/inventory/group_vars` symlink exists |
| `bash: ... '$(...)' not found` in ESXi piped scripts | ESXi has busybox `sh`, not bash | Use `sh -s` and POSIX-only |
| `dnsmasq: cannot set --bind-interfaces and --bind-dynamic` | Rocky 9 default `/etc/dnsmasq.conf` | Already commented out by dns.yml |
| calico-node 0/1 after powerup | firewalld blocks BGP / pod CIDR | Already fixed in k8s_master.yml + k8s_worker.yml; see [calico.md](calico.md) C1 |
| `kubeadm init` fails with "unknown service runtime.v1.RuntimeService" | Rocky's containerd ships with CRI disabled | Always regenerate config — k8s_master.yml does this |
| ovftool / Packer attempts | Both abandoned | Don't reach for them; only `terraform/clone-from-vault.sh` is current |
| `cluster_powerup.yml`: all `power.on` calls succeed at the playbook level but every VM stays `Powered off`; hostd.log says "State Transition not allowed" | ESXi host is in maintenance mode (sometimes set automatically after a dirty shutdown) | `ssh root@192.168.1.174 'vim-cmd hostsvc/maintenance_mode_exit'`. See [operations.md](operations.md) "Powerup that succeeds but leaves all VMs off". |

Full per-component breakdowns under `docs/` — see [README.md](README.md).
