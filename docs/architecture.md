# Architecture — Home Lab Kubernetes on ESXi

State as of 2026-05-16. 1 physical host, 9 VMs (1 vault workload + 8
k8s cluster).

---

## Hardware

```
┌─────────────────────────────────────────────────────────────────────────┐
│  HP Z620  (bidur.attlocal.net, 192.168.1.174)                           │
│  ESXi 6.7.0 build-8169922                                               │
│  Intel Xeon E5-2689 (8c / 16t @ 2.60 GHz)                               │
│  60 GB RAM                                                              │
│                                                                         │
│  ┌─────────────────────────┐    ┌──────────────────────────┐            │
│  │ datastore1 (VMFS-6)     │    │ datastore2 (VMFS-6)      │            │
│  │ 1.4 TB                  │    │ 931 GB                   │            │
│  │ kmaster1-3, dns1, lb1   │    │ kworker1-3, vault-server │            │
│  └─────────────────────────┘    └──────────────────────────┘            │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## VM inventory

| Role | Hostname | IP | CPU | RAM | Disk | Datastore |
|------|----------|----|-----|-----|------|-----------|
| Source / Vault | **vault-server** | 192.168.1.202 | 2 | 2 GB | 30 GB | datastore2 |
| k8s master | kmaster1 | 192.168.1.186 | 2 | 4 GB | 50 GB | datastore1 |
| k8s master | kmaster2 | 192.168.1.189 | 2 | 4 GB | 50 GB | datastore1 |
| k8s master | kmaster3 | 192.168.1.187 | 2 | 4 GB | 50 GB | datastore1 |
| k8s worker | kworker1 | 192.168.1.182 | 2 | 8 GB | 100 GB | datastore2 |
| k8s worker | kworker2 | 192.168.1.183 | 2 | 8 GB | 100 GB | datastore2 |
| k8s worker | kworker3 | 192.168.1.184 | 2 | 8 GB | 100 GB | datastore2 |
| LB + DNS (MASTER) | lb1 | 192.168.1.188 | 1 | 2 GB | 20 GB | datastore1 |
| LB + DNS (BACKUP) | lb2 | 192.168.1.185 | 1 | 1 GB | 20 GB | datastore1 |

Total: ~43 GB RAM configured (out of 60 GB host).

VIPs / virtual addresses:
- `192.168.1.50` — keepalived VIP, k8s API endpoint (HAProxy → masters)
- `myhomelab.com` — internal DNS zone served by dnsmasq on lb1

---

## Network topology

```
                     ┌──────────────────────────────────────┐
                     │   Home network 192.168.1.0/24        │
                     │   (Router: 192.168.1.1, DHCP)        │
                     └─────────┬────────────────────────────┘
                               │
                       VM Network port group
                               │
       ┌───────────────────────┼─────────────────────────────┐
       │              ┌────────┴────────┐                    │
       │              │   keepalived    │                    │
       │              │   VIP 192.168.1.50                   │
       │              │   (lb1 MASTER ⇄ lb2 BACKUP, VRRP)    │
       │              └────────┬────────┘                    │
   ┌───┴───┐  ┌────┐  ┌────┐  ┌┴───┐  ┌────┐  ┌────┐  ┌────┐
   │vault- │  │ lb1│  │ lb2│  │kma1│  │kma2│  │kma3│  │kwr*│
   │server │  │.188│  │.185│  │.186│  │.189│  │.187│  │.18*│
   │ .202  │  └─┬──┘  └─┬──┘  └──┬─┘  └─┬──┘  └─┬──┘  └─┬──┘
   └───────┘    │       │        │      │       │       │
                │       │        └──────┴───────┴───────┘
                │       │             ↑ k8s cluster
                │       │
                │       └── HAProxy + dnsmasq (active when holds VIP)
                └────────── HAProxy + dnsmasq (default holder of VIP)
                            VIP fronts: 6443 (api) 80 (http) 443 (https) 53 (dns)
```

DNS arrows:
```
[ Every host ] --(192.168.1.50  VIP)--> [ dnsmasq on VIP-holder (lb1 or lb2) ]
                                          authoritative for myhomelab.com
                                          forwards rest to 8.8.8.8 / 8.8.4.4
```

---

## Kubernetes layer

```
                       ┌─────────────────────────────────┐
                       │   client → 192.168.1.50:6443    │
                       │   (kubectl, kubeadm join, etc.) │
                       └────────────────┬────────────────┘
                                        │
                                ┌───────┴────────┐
                                │  lb1: HAProxy  │
                                │  + keepalived  │
                                │  (VIP owner)   │
                                └───────┬────────┘
                                        │ TCP roundrobin → :6443
              ┌─────────────────────────┼─────────────────────────┐
              │                         │                         │
       ┌──────┴───────┐         ┌───────┴──────┐          ┌───────┴──────┐
       │  kmaster1    │         │  kmaster2    │          │  kmaster3    │
       │ kube-apisrv  │  ←etcd→ │ kube-apisrv  │  ←etcd→  │ kube-apisrv  │
       │ controller   │         │ controller   │          │ controller   │
       │ scheduler    │         │ scheduler    │          │ scheduler    │
       │ etcd member  │         │ etcd member  │          │ etcd member  │
       └──────┬───────┘         └──────┬───────┘          └──────┬───────┘
              └──────────────────┬─────┴──────────────────┬──────┘
                                 │                        │
                          ┌──────┴──────┐         ┌───────┴──────┐
                          │  kworker1   │         │  kworker2/3  │
                          │  containerd │         │  containerd  │
                          │  kubelet    │         │  kubelet     │
                          │  Calico pod │         │  Calico pod  │
                          └─────────────┘         └──────────────┘
```

### Software stack inside the cluster

| Component | Version | Notes |
|-----------|---------|-------|
| Kubernetes | 1.36.1 | pkgs.k8s.io v1.36 channel |
| Container runtime | containerd 2.2.3 | CRI plugin re-enabled via `containerd config default` |
| CNI | Calico via Tigera operator v3.30.4 | IPPool 10.0.0.0/16, VXLAN cross-subnet |
| Service mesh | Istio 1.27.2 | `default` profile, sidecar injection on `default` ns |
| DNS (internal) | CoreDNS (k8s-internal) + dnsmasq HA on lb1+lb2 | dnsmasq for `*.myhomelab.com`, answered by VIP holder |
| Load balancer | HAProxy + keepalived HA on lb1+lb2 | MASTER lb1 / BACKUP lb2, VIP 192.168.1.50 |

### CIDRs

| Scope | CIDR | Notes |
|-------|------|-------|
| Home network | 192.168.1.0/24 | DHCP from home router |
| Pod network (Calico) | 10.0.0.0/16 | kubeadm `--pod-network-cidr` matches |
| Service network | 10.96.0.0/12 | k8s default |
| Internal domain | `myhomelab.com` | dnsmasq on lb1 |

---

## Provisioning pipeline (how this was built today)

```
[ vault-server, hand-built earlier (Rocky 9.7, GNOME) ]
                       │
                       │  (1) bootstrap: ansible user + key + ipv6 off + GUI strip
                       ↓
[ terraform/clone-from-vault.sh ]
   - power off vault-server briefly (~5-10 min)
   - vmkfstools -i -d thin × 9 (parallel)
   - generate per-VM VMX (new UUID + generated MAC)
   - vim-cmd solo/registervm × 9
   - power vault-server back ON first
   - power on 9 clones
                       │
                       ↓
[ ansible bootstrap-users.yml ]
   - bstha user + key + NOPASSWD sudo on all 9 hosts
   - remove Server with GUI group (saved ~10 GB RAM cluster-wide)
                       │
                       ↓
[ ansible site.yml ]
   1. base.yml         → LVM extend, hostname, SSH lockdown,
                         common pkgs, ipv6 disable, firewalld, timezone
   2. dns.yml          → dnsmasq HA on lb1+lb2 (myhomelab.com authoritative,
                         bind-dynamic; every host nmcli → VIP .50 as DNS)
   3. loadbalancer.yml → HAProxy + keepalived MASTER/BACKUP on lb1+lb2
   4. k8s_master.yml   → containerd, kubeadm init kmaster1, join 2/3
   5. k8s_worker.yml   → containerd, kubeadm join × 3
   6. cni_calico.yml   → Tigera operator, replace Flannel with Calico
   7. istio.yml        → istioctl install (default profile)
```

---

## What's NOT in this cluster (yet)

- splunk-monitoring VM (deferred — memory available now after GUI strip)
- ingress controller (nginx-ingress or istio-ingressgateway exposed externally)
- persistent storage (no SC, no PV provisioner)
- backup / etcd snapshot strategy
- vSphere vCenter (single ESXi host only)

---

## Storage layout (datastore → VM disk → LVM)

```
ESXi host 192.168.1.174
│
├── datastore1 (VMFS-6, 1.4 TB — control plane + infra)
│   ├── kmaster1/  scsi0:0 → 50 GB thin (sda) → VG 'rlm'
│   │              └── LVs: root / var / apps / home (extended by base.yml)
│   ├── kmaster2/  scsi0:0 → 50 GB thin (sda) → VG 'rlm' (same layout)
│   ├── kmaster3/  scsi0:0 → 50 GB thin (sda) → VG 'rlm' (same layout)
│   ├── lb1/       scsi0:0 → 20 GB thin (sda) → VG 'rlm'
│   └── dns1/      scsi0:0 → 20 GB thin (sda) → VG 'rlm'  (VM is now 'lb2' —
│                                                          dir/VMX names kept as 'dns1'
│                                                          for historical reasons)
│
└── datastore2 (VMFS-6, 931 GB — workers + clone source)
    ├── vault-server/  scsi0:0 → 30 GB (sda) — THE clone source (vmkfstools -i)
    ├── kworker1/      scsi0:0 → 100 GB thin (sda) → VG 'rlm'
    │                  └── /var extended by base.yml (containerd image store)
    ├── kworker2/      scsi0:0 → 100 GB thin (sda) → VG 'rlm'
    └── kworker3/      scsi0:0 → 100 GB thin (sda) → VG 'rlm'
```

All VM disks are thin-provisioned. `base.yml` grows the LVM PV/LV chain
(`growpart → pvresize → lvextend var +100%FREE → xfs_growfs`) so the
extra space added at clone time (vmkfstools `-X`) reaches the
filesystem. The VG name `rlm` is inherited from the vault-server source.

---

## Request flow: external HTTP to a pod

What happens when a client on the home network hits
`http://myapp.myhomelab.com/`:

```
┌──────────────────┐
│ Client (192.168.1.x)
│  - resolver = 192.168.1.188 (lb1's dnsmasq)
└────────┬─────────┘
         │ (1) DNS A?  myapp.myhomelab.com
         ▼
┌──────────────────────────────┐
│ lb1:53/udp  dnsmasq          │
│  myhomelab.com authoritative │
│  → returns A record (192.168.1.50 — the VIP, by convention)
└────────┬─────────────────────┘
         │
         │ (2) TCP :80 → 192.168.1.50
         ▼
┌──────────────────────────────┐
│ lb1: keepalived owns 192.168.1.50 (VIP)
│ → HAProxy frontend http_in
│ → backend workers_http (kworker1/2/3 :30080)
└────────┬─────────────────────┘
         │
         │ (3) TCP :30080 → kworker{1|2|3}
         ▼
┌──────────────────────────────────────────┐
│ kworker* kernel (NodePort 30080)         │
│  → kube-proxy DNAT to a Service ClusterIP (10.96.x.x)
│  → endpoint selection round-robin
│  → DNAT to a Pod IP (10.0.x.x)
└────────┬─────────────────────────────────┘
         │
         │ (4) packet leaves node toward pod
         ▼
┌──────────────────────────────────────────┐
│ Calico (BGP-distributed routes)          │
│  - if pod is on same node: cali* veth pair, direct
│  - if pod is on remote node: route to that node's IP,
│                              VXLAN-encap iff cross-subnet
│                              (same-subnet: plain L3 forward)
└──────────────────────────────────────────┘
```

Why ingress goes through NodePort 30080: there's no
istio-ingressgateway external IP yet (no MetalLB). HAProxy on lb1 maps
80/443 → 30080/30443 on workers to bridge the gap.

---

## Request flow: kubectl from workstation

```
┌────────────────────────────────────────┐
│ workstation:  ~/.kube/config           │
│   context homelab → server: https://192.168.1.50:6443
└────────────┬───────────────────────────┘
             │ kubectl get nodes (mTLS)
             ▼
┌────────────────────────────────────────┐
│ lb1: keepalived VIP 192.168.1.50       │
│   HAProxy frontend k8s_api :6443       │
│   backend k8s_masters (roundrobin)     │
└────────────┬───────────────────────────┘
             │
   ┌─────────┼──────────┐
   ▼         ▼          ▼
┌─────────┐ ┌─────────┐ ┌─────────┐
│kmaster1 │ │kmaster2 │ │kmaster3 │
│apisrvr  │ │apisrvr  │ │apisrvr  │
│  ↕      │ │  ↕      │ │  ↕      │
│  etcd ──┼─┼─ etcd ──┼─┼─ etcd   │  Raft over :2380
│         │ │         │ │         │
└─────────┘ └─────────┘ └─────────┘
       Quorum = 2/3 (tolerates 1 master loss)
```

Same path for any `kubectl` action and for `kubeadm join` from new nodes.

---

## DNS resolution (myhomelab.com vs everything else)

Every VM (and workstation) is configured (via nmcli in `dns.yml`) to
use `192.168.1.188` (lb1) as primary resolver, with `myhomelab.com` as
search domain:

```
┌──────────────────┐
│ Any host         │
│ /etc/resolv.conf │
│ nameserver 192.168.1.188
│ search myhomelab.com
└────────┬─────────┘
         │ A? foo.myhomelab.com  OR  A? google.com
         ▼
┌─────────────────────────────────────────────────────┐
│ lb1:53  dnsmasq                                     │
│ ┌─────────────────────────────────────────────────┐ │
│ │ authoritative for myhomelab.com                 │ │
│ │  - forward zone from /etc/dnsmasq.hosts.d/      │ │
│ │  - auto-PTR (--reverse-records)                 │ │
│ └────────────────────┬────────────────────────────┘ │
│                      │ (everything else)            │
│                      ▼                              │
│ ┌─────────────────────────────────────────────────┐ │
│ │ upstream: 8.8.8.8 / 8.8.4.4                     │ │
│ └─────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
```

Inside the cluster, pods use CoreDNS (`10.96.0.10`, kube-dns Service)
for cluster-internal names (`*.svc.cluster.local`); CoreDNS forwards
everything else upstream — typically also to lb1.

---

## Firewall port matrix

Every k8s node (master + worker) runs firewalld in zone `public`. Calico
requires pod CIDR traffic to bypass firewalld entirely, hence the
`zone=trusted source=10.0.0.0/16` rule on each k8s node.

| Port / Protocol | Direction | Opened on | Why |
|-----------------|-----------|-----------|-----|
| 22/tcp | inbound | all VMs | ssh |
| 6443/tcp | inbound | k8s_masters, lb1 | kube-apiserver |
| 2379-2380/tcp | inbound | k8s_masters | etcd client + peer |
| 10250/tcp | inbound | k8s_masters, k8s_workers | kubelet API |
| 10251/tcp | inbound | k8s_masters | kube-scheduler |
| 10252/tcp | inbound | k8s_masters | kube-controller-manager |
| 30000-32767/tcp | inbound | k8s_workers | NodePort range |
| 179/tcp | inbound | k8s_masters, k8s_workers | Calico BGP |
| 5473/tcp | inbound | k8s_masters, k8s_workers | Calico Typha |
| 4789/udp | inbound | k8s_masters, k8s_workers | Calico VXLAN (cross-subnet) |
| 80/tcp, 443/tcp | inbound | lb1, lb2 | HAProxy HTTP/HTTPS ingress |
| 8404/tcp | inbound | lb1, lb2 | HAProxy stats |
| VRRP (proto 112) | inbound | lb1, lb2 | keepalived MASTER/BACKUP advertisements |
| 53/udp+tcp | inbound | lb1, lb2 | dnsmasq (`myhomelab.com`), answered by VIP holder |
| **pod CIDR 10.0.0.0/16** | **any** | **k8s_masters, k8s_workers (zone trusted)** | **Pod-to-pod across nodes** |

---

## Component dependency chain (powerup order)

```
[ ESXi host 192.168.1.174 ]
        │
        │  vault-server: not in k8s, must be up so its disk image is
        │  available if any clone wants to be re-created via vmkfstools.
        ▼
[ vault-server (192.168.1.202) ]
        │
        ▼
[ lb1 (.188) MASTER ◄──── VRRP 51 ────► lb2 (.185) BACKUP ]
   ├─ keepalived → VIP 192.168.1.50 (MASTER owns it)
   ├─ haproxy    → :6443/:80/:443 (both run; LB on VIP-holder serves traffic)
   └─ dnsmasq    → 'myhomelab.com' (bind-dynamic; answers on VIP when held)
        │
        ▼
[ kmaster1/2/3 (192.168.1.186/189/187) ]
   ├─ kubelet + containerd + kubeadm
   ├─ etcd, kube-apiserver, controller-manager, scheduler
   ├─ calico-node (host-network)
   └─ via control-plane-endpoint 192.168.1.50:6443
        │
        ▼
[ kworker1/2/3 (192.168.1.182/183/184) ]
   ├─ kubelet + containerd
   ├─ calico-node (host-network)
   └─ workload pods → Calico IPAM out of 10.0.0.0/16
        │
        ▼
[ Calico ] Tigera operator → IPPool default-ipv4-ippool 10.0.0.0/16
[ Istio  ] istiod + istio-ingressgateway (`default` profile)
```

`cluster_powerup.yml` enforces this order via `throttle: 1` over the
list `lb1 → lb2 → kmaster1/2/3 → kworker1/2/3`, then waits for SSH on
each IP before declaring success. vault-server is handled separately
by `all_powerup.yml` (which imports cluster_powerup.yml).

---

## Software stack (full version pin matrix)

| Layer | Component | Version | Where it's pinned |
|-------|-----------|---------|-------------------|
| Hypervisor | ESXi | 6.7.0 build-8169922 | (fixed; host firmware) |
| Guest OS | Rocky Linux | 9.7 (Blue Onyx) | source: vault-server template |
| Kernel | Linux | 5.14.0-611.x el9_7 | dnf update during `base.yml` |
| Container runtime | containerd | 2.2.3 | docker-ce repo + `containerd config default` |
| k8s | kubeadm/kubelet/kubectl | 1.36.1 | `k8s_version: "1.36"` in group_vars; channel `pkgs.k8s.io/.../v1.36` |
| CNI | Calico (Tigera operator) | v3.30.4 | `calico_version` in `cni_calico.yml` |
| Service mesh | Istio | 1.27.2 | `istio_version` in `istio.yml`, profile `default` |
| Load balancer | HAProxy | rocky-9 default | `loadbalancer.yml` |
| VRRP | keepalived | rocky-9 default | `loadbalancer.yml`, standalone MASTER |
| DNS | dnsmasq | rocky-9 default | `dns.yml`, served from lb1 |

Bumping any version: edit the file in the right-hand column. CIDR /
ports / VIP all live in `ansible/group_vars/all/vars.yml`.

---

## Provisioning state (where the build is today, 2026-05-17)

- Cluster fully up: 6 nodes Ready, Calico installed and BGP-converged,
  Istio control plane Ready.
- Kubeconfig pulled to workstation at `~/.kube/config` (context `homelab`,
  alongside existing `k3os-local` for local image builds). See
  `scripts/fetch-kubeconfig.sh` and [operations.md](operations.md).
- Open: ingress gateway external IP is `<pending>` (no MetalLB / cloud
  LB), persistent storage class not provisioned, etcd snapshot strategy
  not in place.

---

## Failure-mode summary (links to per-component docs)

| If this breaks... | See |
|-------------------|-----|
| k8s nodes won't join, kubeadm preflight, CRI | [k8s-cluster.md](k8s-cluster.md) |
| Calico BGP stuck, ippools degraded, firewalld | [calico.md](calico.md) |
| vault-server clone fails, vmkfstools issues | [vault-server.md](vault-server.md) |
| HAProxy won't start, SELinux, keepalived | [haproxy.md](haproxy.md) |
| DNS not resolving, dnsmasq fails to start | [dns.md](dns.md) |
| Ansible playbook errors, group_vars, vault | [ansible.md](ansible.md) |
| ESXi quirks, MAC errors, /tmp full, scp | [esxi-host.md](esxi-host.md) |
| Day-to-day shutdown / powerup / reset | [operations.md](operations.md) |
| Packer rabbit hole (abandoned) | [packer.md](packer.md) |
