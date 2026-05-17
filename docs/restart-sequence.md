# Restart sequence — safe power-down and power-up

The home lab spans **two physical machines**:

| Tier | Hardware | What runs there |
|---|---|---|
| **Workstation** | `gdragon` (192.168.1.181) | k3s (single-node) + monitoring stack (Prometheus / Grafana / Loki) + ArgoCD. **This is where ansible runs from.** |
| **ESXi host** | `192.168.1.174` (HP Z620) | 9 VMs: vault-server + 6 k8s nodes + lb1 + lb2 (the "homelab" cluster). |

Going down or coming back up in the wrong order causes recoverable but
annoying breakage: kubeadm join timeouts, Calico BGP "not established,"
DNS NXDOMAIN, Prometheus "out-of-order sample." This page is the
canonical order so you don't hit any of them.

---

## TL;DR — full power-down

The asymmetry: ansible runs **from gdragon**, so gdragon must stay up
until *after* the homelab is gone, and must come up *before* the
homelab is brought back.

```bash
# All from gdragon (the workstation):

# 1. Stop the homelab cluster (vSphere VMs)        ─────  workers → LBs → masters → vault
cd /apps/git-code/git-vsphere/ansible
ansible-playbook -i inventory/hosts.ini --vault-password-file=.vault_pass \
  playbooks/all_shutdown.yml

# 2. (Optional) Stop the ESXi host                 ─────  only for physical maintenance
ssh root@192.168.1.174 'shutdown -h now'

# 3. Stop the workstation last                     ─────  monitoring stack quiesces with it
sudo shutdown -h now      # run on gdragon itself
```

## TL;DR — full power-up

```bash
# 1. Power on gdragon first                        ─────  k3s + monitoring auto-start
#                                                          (k3s.service is `enabled`)

# 2. Power on ESXi host (if it was off)            ─────  press the box's power button,
#                                                          or use IPMI / Wake-on-LAN

# 3. Bring up the homelab cluster from gdragon     ─────  vault → LBs → masters → workers
#                                                          + chronyc makestep + health probe
cd /apps/git-code/git-vsphere/ansible
ansible-playbook -i inventory/hosts.ini --vault-password-file=.vault_pass \
  playbooks/all_powerup.yml
```

`all_powerup.yml` already does step 3 in the right order, syncs clocks
afterward, and prints OK/FAIL for the API + DNS probes. Keep reading
only if you want to know *why* each step matters or you're debugging.

---

## Dependency graph (across both physical hosts)

```
  ════════════════════ HOME NETWORK 192.168.1.0/24 ════════════════════

  ╔═══════════════════════╗            ╔══════════════════════════╗
  ║  WORKSTATION gdragon  ║            ║  ESXi host 192.168.1.174 ║
  ║  192.168.1.181        ║            ║  (HP Z620)               ║
  ║                       ║            ║                          ║
  ║  k3s (single node)    ║            ║   ┌──────────────────┐   ║
  ║   ├─ Grafana   :30300 ║◄──remote_  ║   │ vault-server     │   ║
  ║   ├─ Prometheus :30320║   write    ║   │ 192.168.1.202    │   ║
  ║   ├─ Loki      :30310 ║◄──Promtail ║   └──────┬───────────┘   ║
  ║   ├─ ArgoCD           ║   push     ║          │               ║
  ║   └─ ansible          ║            ║   ┌──────┴──────────┐    ║
  ║      └─drives┐        ║            ║   │ lb1 + lb2 (HA)  │    ║
  ║              │        ║            ║   │ .188 + .185     │    ║
  ║              │ ssh   ─║───────────►║   │  → VIP .50      │    ║
  ║              │        ║            ║   └──────┬──────────┘    ║
  ║              │        ║            ║          │               ║
  ║              │        ║            ║   ┌──────┴──────────┐    ║
  ║              │        ║            ║   │ kmaster1/2/3    │    ║
  ║              │        ║            ║   └──────┬──────────┘    ║
  ║              │        ║            ║          │               ║
  ║              │        ║            ║   ┌──────┴──────────┐    ║
  ║              └────────║───────────►║   │ kworker1/2/3    │    ║
  ║                       ║            ║   └─────────────────┘    ║
  ╚═══════════════════════╝            ╚══════════════════════════╝
```

Key dependencies that drive order:
- **ansible runs from gdragon** → gdragon must be up to drive the
  homelab shutdown or powerup. So gdragon is **last off, first on**.
- **homelab Prometheus remote_writes to gdragon** → if gdragon is
  down while homelab is up, samples buffer briefly (WAL) and replay
  when gdragon returns. Short outages are fine; long outages may
  exceed the WAL.
- **Within ESXi** the order is `vault → LBs → masters → workers` for
  powerup, reversed for shutdown. Inside the homelab cluster the LBs
  must be up before masters can reach each other via the VIP.

Workstation `gdragon` is otherwise independent — its k3s + monitoring
stack starts automatically via `k3s.service` on boot.

---

## Power down (correct order)

Full order across both physical machines:

| Step | Where | Hosts | Why |
|---|---|---|---|
| **1** | from gdragon (ansible) | k8s_workers (kwrk1/2/3) | Workloads stop first. No quorum impact. |
| **2** | from gdragon (ansible) | loadbalancers (lb1 + lb2) | DNS + VIP go down — no more reachable API. |
| **3** | from gdragon (ansible) | k8s_masters (kmas1/2/3) | etcd quorum is irrelevant once everything else is gone. |
| **4** | from gdragon (ansible) | vault-server | Last vSphere VM to go down; first to come up. |
| **5** | from gdragon (manual) | ESXi host (optional) | Only for physical maintenance: `ssh root@192.168.1.174 'shutdown -h now'`. |
| **6** | on gdragon itself | gdragon (workstation) | Power off last — once it's down, no ansible to drive anything. |

Steps 1-4 are dispatched by a single `ansible-playbook all_shutdown.yml`
run with `async: 1 poll: 0` so each play doesn't hang waiting for the
SSH session it's about to kill.

After dispatch, the vSphere VMs are off in ~25-30 s. Verify on ESXi
(if it's still up):

```bash
ssh root@192.168.1.174 'vim-cmd vmsvc/getallvms | while read v rest; do
  case $v in [0-9]*) printf "%s " $v; vim-cmd vmsvc/power.getstate $v | tail -1;; esac; done'
```

If you only want to take the *cluster* down and leave vault-server
running (e.g., to do a Kubernetes-only reset), use
`cluster_shutdown.yml` instead.

---

## Power up (correct order)

Full order across both physical machines:

| Step | Where | What | Why |
|---|---|---|---|
| **1** | physical | Power on gdragon (workstation) | Hosts ansible. k3s + monitoring start automatically (`k3s.service` is `enabled`). |
| **2** | physical | Power on ESXi host (if off) | The 9 VMs can't start until the hypervisor is alive. |
| **3** | from gdragon (ansible) | `all_powerup.yml` → vault-server first | Pre-play waits for vault SSH before moving on. |
| **4** | from gdragon (ansible) | `cluster_powerup.yml` → lb1, lb2 | LBs must be up before masters (kubeadm endpoint = VIP). |
| **5** | from gdragon (ansible) | `cluster_powerup.yml` → kmaster1/2/3 | One at a time (`throttle: 1`) so etcd reaches quorum without alarm. |
| **6** | from gdragon (ansible) | `cluster_powerup.yml` → kworker1/2/3 | API has been reachable for a while by now. |
| **7** | from gdragon (ansible, auto) | `chronyc makestep` on every host | Closes the ESXi-clock-drift bug. *Critical* — see "NTP" below. |
| **8** | from gdragon (ansible, auto) | Probe API VIP + DNS VIP | Prints OK / FAIL with retry. |

Steps 3-8 are all one `ansible-playbook all_powerup.yml` invocation.

Typical wall time: ~6-8 min from "ESXi reachable" to "API + DNS OK".

After it returns, the monitoring stack on gdragon picks up homelab
metrics again within ~30 s (Prometheus operator already had the
`remote_write` config from the homelab side; the homelab Prometheus
buffered briefly during downtime and now replays its WAL).

---

## Why each non-obvious step exists

### NTP / clock-step (the #1 cause of bizarre post-restart breakage)

VMware Tools sets each VM's clock from the ESXi host on boot. If the
ESXi host has drifted (it has — see TODO in project memory), every VM
comes up with the same wrong time. chrony refuses to slew past 1000 s,
and Prometheus across the LB pair refuses to ingest `out of order`
remote_write samples → `up{cluster="homelab"}` returns empty in Grafana
even though scraping looks healthy.

`chronyc makestep` forces the step regardless of magnitude. The play
runs it on every VM in `everyone` (cluster + vault-server) after
powerup.

**ESXi host NTP is on the TODO list**; until it's fixed, do not skip
this step.

### lb1 + lb2 before masters

Masters use `kubeadm init --control-plane-endpoint=192.168.1.50:6443`,
so kube-apiserver, etcd, and `kubeadm join` all flow through the VIP.
If the LB pair isn't up, masters can boot but kubelet, etcd, and
controllers will time out trying to reach the VIP. Best to wait.

### Workers last

Workers only need the API to be reachable. Coming up after masters
avoids `node not found` / `cni not initialized` storms.

### Calico BGP recovers automatically

Once nodes are up and the VIP is reachable, calico-node pods start and
BGP peering is re-established within ~30 s. The firewalld fix (open
TCP/179, UDP/4789, TCP/5473 + trust pod CIDR) is already baked into
k8s_master.yml / k8s_worker.yml, so no manual step is needed. If you
see calico-node 0/1 anyway, see [calico.md](calico.md) C1.

---

## Verification after powerup

`all_powerup.yml` runs these automatically, but you can repeat them
manually any time:

```bash
# 1. all 6 nodes Ready
kubectl --context homelab get nodes

# 2. all system pods Running
kubectl --context homelab get pods -A | grep -vE 'Running|Completed'
# Expected: only header line

# 3. Calico BGP established on every node (run from any one)
POD=$(kubectl --context homelab -n calico-system get pod -l k8s-app=calico-node -o name | head -1)
kubectl --context homelab -n calico-system exec $POD -c calico-node -- \
  /bin/calico-node -felix-ready -bird-ready
# Expected: exit 0

# 4. k8s API + DNS via VIP
curl -sk https://192.168.1.50:6443/healthz                     # → ok
dig  @192.168.1.50 kmaster1.myhomelab.com +short               # → 192.168.1.186

# 5. cross-cluster monitoring (if Prometheus is on gdragon)
curl -sG --data-urlencode 'query=count(up) by (cluster)' \
  http://192.168.1.181:30320/api/v1/query
# Expected: both cluster=homelab and cluster=k3os-local series visible
#           within ~2 min of cluster being up.
```

---

## Reset matrix (when something is wrong)

| Symptom | Try | Doc |
|---|---|---|
| One VM didn't power on | `ssh root@192.168.1.174 'vim-cmd vmsvc/power.on <vmid>'` then re-run powerup | [operations.md](operations.md) |
| calico-node 0/1, BGP "not established" | firewalld blocked BGP — `ansible-playbook ... --tags k8s` to re-apply firewall rules | [calico.md](calico.md) C1 |
| VIP gone but lb1 looks fine | `systemctl status keepalived haproxy` on both LBs | [haproxy.md](haproxy.md) |
| DNS broken on every host | check the LB pair: `dig @192.168.1.50` vs `dig @192.168.1.188` vs `dig @192.168.1.185` | [dns.md](dns.md) |
| Prometheus shows no recent homelab data after restart | clock skew — `ansible all -m shell -a 'sudo chronyc makestep' -b` | this doc, "NTP" |
| stuck `Terminating` namespace | broken APIService — `kubectl get apiservices | grep -v True` | [monitoring/README.md](../monitoring/README.md) gotcha #2 |
| Cluster is just unhealthy beyond repair | `ansible-playbook ... playbooks/k8s_reset.yml` then `site.yml --tags k8s,calico,istio` | [operations.md](operations.md) |
