# Restart sequence — safe power-down and power-up

The home lab has dependencies across 9 vSphere VMs (homelab cluster) +
1 workstation k3s (gdragon). Going down or coming back up in the wrong
order causes recoverable but annoying breakage: kubeadm join timeouts,
Calico BGP "not established," DNS NXDOMAIN, Prometheus "out-of-order
sample." This page is the canonical order so you don't hit any of them.

---

## TL;DR

```
# Full shutdown of homelab (cluster + vault-server)
cd ansible/
ansible-playbook -i inventory/hosts.ini --vault-password-file=.vault_pass \
  playbooks/all_shutdown.yml

# Full powerup (correct order + clock-step + health probe)
ansible-playbook -i inventory/hosts.ini --vault-password-file=.vault_pass \
  playbooks/all_powerup.yml
```

`all_powerup.yml` already does everything below in the right order.
Keep reading only if you want to know *why* each step matters or you're
debugging.

---

## Dependency graph

```
          ┌──────────────┐
          │  ESXi host   │  (192.168.1.174)
          │  192.168.1.174│   - must be up before any VM
          │              │   - its clock matters — see "NTP" below
          └──────┬───────┘
                 │
        ┌────────┴────────┐
        │  vault-server   │  (192.168.1.202) — clone source, owns no
        │                 │   live workload, but kept first so vmkfstools
        │                 │   re-clones work without re-shuffling.
        └────────┬────────┘
                 │
       ┌─────────┴─────────┐
       │  lb1 + lb2 (HA)   │  (192.168.1.188, .185) — keepalived VIP
       │                   │   192.168.1.50; HAProxy fronts API/HTTP/HTTPS;
       │                   │   dnsmasq HA serves myhomelab.com.
       │                   │   NEEDS to be up before kubeadm masters join
       │                   │   (they reach each other through the VIP).
       └─────────┬─────────┘
                 │
   ┌─────────────┼─────────────┐
   │             │             │
┌──┴──┐       ┌──┴──┐       ┌──┴──┐
│kmas1│  ←→   │kmas2│  ←→   │kmas3│   etcd quorum, kube-apiserver
└──┬──┘       └──┬──┘       └──┬──┘   Need 2 of 3 to be healthy.
   │             │             │
   └─────────────┼─────────────┘
                 │
   ┌─────────────┼─────────────┐
   │             │             │
┌──┴──┐       ┌──┴──┐       ┌──┴──┐
│kwrk1│       │kwrk2│       │kwrk3│   kubelet, workloads, Calico BGP peers
└─────┘       └─────┘       └─────┘
```

Workstation `gdragon` (192.168.1.181) is on the home network but
independent — its k3s + monitoring stack can come up at any time. The
homelab Prometheus will retry remote_write until gdragon's Prometheus
is up.

---

## Power down (correct order)

`all_shutdown.yml` dispatches shutdowns in this order, with `async: 1
poll: 0` so each play doesn't hang waiting for the SSH session it's
about to kill.

| Step | Hosts | Why this order |
|---|---|---|
| 1 | k8s_workers (kwrk1/2/3) | Workloads stop first. No quorum impact. |
| 2 | loadbalancers (lb1 + lb2) | DNS + VIP go down — no more reachable API. |
| 3 | k8s_masters (kmas1/2/3) | etcd quorum is irrelevant once everything else is gone. Shut down together rather than serially to avoid alarm noise. |
| 4 | vault-server | Last to go down; first to come up. Idle workload but kept as the clone source. |

After dispatch, VMs are off in ~25-30 s. Verify on ESXi:

```bash
ssh root@192.168.1.174 'vim-cmd vmsvc/getallvms | while read v rest; do
  case $v in [0-9]*) printf "%s " $v; vim-cmd vmsvc/power.getstate $v | tail -1;; esac; done'
```

If you only want to take the *cluster* down and leave vault-server
running (e.g., to do a Kubernetes-only reset), use
`cluster_shutdown.yml` instead.

---

## Power up (correct order)

`all_powerup.yml` chains:
1. `vault-server` first (its own pre-play).
2. `cluster_powerup.yml` — `lb1, lb2, kmaster1, kmaster2, kmaster3,
   kworker1, kworker2, kworker3` with `throttle: 1` (one at a time so
   dependencies settle), then waits for SSH on each IP.
3. **Post-powerup hygiene**:
   - `chronyc makestep` on every host. *This is critical* — see "NTP"
     below.
4. **Health probe**:
   - GET `https://192.168.1.50:6443/healthz` (k8s API via VIP, retries
     12 × 5 s).
   - `dig @192.168.1.50 kmaster1.myhomelab.com` (DNS via VIP).
   - Prints "OK" or "FAIL" with the response code.

Typical wall time: ~6-8 min for all 9 VMs to come up + APIs healthy.

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
