# Architecture — Home Lab Kubernetes on ESXi

State as of 2026-05-17. Spans **three physical machines** plus 9 VMs:

| Tier | Hardware | Hosts |
|---|---|---|
| **ESXi hypervisor** | HP Z620, 192.168.1.174, ESXi 6.7 | 9 homelab VMs (k8s + LBs + vault-server) |
| **Workstation (k3s + monitoring + Vault + ArgoCD)** | `gdragon`, 192.168.1.181, Rocky 9 | local k3s, kube-prometheus-stack, Loki, Vault (HA shape) |
| **Edge / reverse proxy** | `gdragon-ubuntu`, 192.168.1.203, Ubuntu 24.04 | 2 podman nginx containers — path-based proxy for everything above |

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

┌─────────────────────────────────────────────────────────────────────────┐
│  gdragon (192.168.1.181)  — workstation, runs k3s + ansible             │
│  Rocky 9, LVM /var grew from 28G → 128G (added /dev/sdb 100G)           │
│  k3s 1.34.3 (single-node), Calico CNI (IPPool 192.168.0.0/16 ⚠ overlap) │
│   workloads in argocd + monitoring + vault + calico-system namespaces   │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│  gdragon-ubuntu (192.168.1.203) — Ubuntu 24.04 LTS, edge proxy host     │
│  podman 4.9 rootless, 2 nginx containers (:80 nginx-1, :8080 nginx-2)   │
│  Custom image: quay.io/bpraisa/nginx:homelab-proxy-1.4                  │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Full deployment topology (network + load-balancers + apps)

The complete picture from a user's browser to a pod, across all three
physical machines, plus the external image registry and git remote.

```
   ┌──────────────────────────┐       ┌─────────────────────────────────────┐
   │  External (internet)     │       │  EXTERNAL DEPENDENCIES (read-only)  │
   │   - github.com           │       │   - quay.io/bpraisa/nginx           │
   │   - quay.io              │◄──────│      :homelab-proxy-1.4 (edge img)  │
   │   - dockerhub            │       │   - quay.io/bpraisa/vault           │
   │   - helm chart repos     │       │      :1.20.4 (mirror; helm currently│
   └──────────────────────────┘       │      still pulls from dockerhub)    │
                ▲                     │   - github.com/myhome-automation    │
                │ image pulls,        │      /git-vsphere (this repo)       │
                │ git pulls           └─────────────────────────────────────┘
                │
   ┌────────────┴────────────────────────────────────────────────────────────┐
   │                       LAN  192.168.1.0/24                               │
   │                       Router: 192.168.1.1 (DHCP)                        │
   └─────────────────┬──────────────────────────────────┬────────────────────┘
                     │ user browser                     │ cluster-internal
                     ▼                                  ▼
   ╔═════════════════════════════════════╗   ╔═══════════════════════════════╗
   ║  gdragon-ubuntu  (192.168.1.203)    ║   ║  ESXi 6.7   (192.168.1.174)   ║
   ║  Ubuntu 24.04 — EDGE / REVERSE PROXY║   ║  HP Z620, 60 GB RAM           ║
   ║                                     ║   ║                               ║
   ║  podman rootless                    ║   ║  9 VMs (homelab cluster):     ║
   ║  image: quay.io/bpraisa/nginx       ║   ║                               ║
   ║         :homelab-proxy-1.4          ║   ║  vault-server  .202 (source) ║
   ║                                     ║   ║  ╔═══════════════════════════╗║
   ║   ┌─ nginx-1 :80 ┐  ┌─ nginx-2:8080│   ║  ║  HA LB pair (homelab)     ║║
   ║   │  HA via 2nd  │  │  port if 80   │   ║  ║  lb1 .188  MASTER  prio101║║
   ║   │  restart=    │  │  is wedged    │   ║  ║  lb2 .185  BACKUP  prio100║║
   ║   │  always      │  │               │   ║  ║   ├─ keepalived → VIP .50 ║║
   ║   └──────┬───────┘  └──────┬────────┘   ║  ║   ├─ HAProxy   :6443      ║║
   ║          │                 │            ║  ║   │            :80/:443   ║║
   ║          ▼ path-based reverse proxy ▼   ║  ║   └─ dnsmasq   :53        ║║
   ║   /grafana/    → gdragon:30300          ║  ║                            ║║
   ║   /prometheus/ → gdragon:30320          ║  ║   k8s 1.36 control plane: ║║
   ║   /loki/       → gdragon:30310          ║  ║   kmaster1 .186           ║║
   ║   /ui/  /v1/   → gdragon:31326          ║  ║   kmaster2 .189           ║║
   ║      (Vault, root-mounted; no sub-path) ║  ║   kmaster3 .187           ║║
   ║   /vault/ → 302 → /ui/                  ║  ║                            ║║
   ║   /argocd/     → gdragon:30401          ║  ║   k8s 1.36 workers:       ║║
   ║   /            → static landing page    ║  ║   kworker1 .182           ║║
   ╚═══════════════════════════╤═════════════╝  ║   kworker2 .183           ║║
                               │                ║   kworker3 .184           ║║
                               ▼                ║                            ║║
   ╔══════════════════════════════════════════╗ ╚════════════╤══════════════╝║
   ║  gdragon  (192.168.1.181)                ║              │                ║
   ║  Rocky 9 — WORKSTATION + LOCAL K3S       ║              │                ║
   ║                                          ║              │ monitoring:    ║
   ║  k3s 1.34 (single-node, Calico CNI)      ║◄─────────────┘ Prometheus     ║
   ║                                          ║                remote_write   ║
   ║  monitoring namespace:                   ║                Promtail push  ║
   ║   ┌─────────────────────────────────────┐║   (cluster=homelab label)     ║
   ║   │ Grafana (the "search head")  :30300 │║                               ║
   ║   │ Prometheus     :30320 (RW receiver) │║                               ║
   ║   │ Loki           :30310 (push API)    │║                               ║
   ║   │ Alertmanager                        │║                               ║
   ║   │ kube-state-metrics                  │║                               ║
   ║   │ node-exporter (DaemonSet)           │║                               ║
   ║   │ promtail      (DaemonSet, local)    │║                               ║
   ║   └─────────────────────────────────────┘║                               ║
   ║                                          ║                               ║
   ║  vault namespace (HA shape, ArgoCD):     ║                               ║
   ║   ┌─────────────────────────────────────┐║                               ║
   ║   │ vault-0  Running, unsealed (LEADER) │║                               ║
   ║   │ vault-2  Running, raft-joined       │║                               ║
   ║   │ vault-1  CrashLoopBackOff (IPPool)  │║                               ║
   ║   │ Services:                           │║                               ║
   ║   │  vault         :30200 (all pods)    │║                               ║
   ║   │  vault-active  :31326 (leader-only) │║◄─ nginx /ui/ + /v1/ point here║
   ║   │  vault-standby :32012               │║                               ║
   ║   │ KV-v2 at `secret/`                  │║                               ║
   ║   │ AppRole auth enabled                │║                               ║
   ║   │ Token method: hvs.* root from       │║                               ║
   ║   │   ~/.vault/init.json on gdragon     │║                               ║
   ║   └─────────────────────────────────────┘║                               ║
   ║                                          ║                               ║
   ║  argocd namespace (GitOps):              ║                               ║
   ║   ┌─────────────────────────────────────┐║                               ║
   ║   │ argocd-server  :30401 (http)        │║──┐                            ║
   ║   │                :30400 (https)       │║  │ git pull → reconcile        ║
   ║   │ application-controller, repo-server,│║  │ vault Application (and      ║
   ║   │ dex, redis, notifier,               │║  │ future workloads)           ║
   ║   │ applicationset-controller (fixed)   │║  │                             ║
   ║   │ rootpath=/argocd                    │║  ▼                             ║
   ║   └─────────────────────────────────────┘║   github.com/myhome-automation ║
   ║                                          ║   /git-vsphere (this repo)     ║
   ║  Other namespaces:                       ║                               ║
   ║   calico-system, calico-apiserver,       ║                               ║
   ║   tigera-operator, kube-system           ║                               ║
   ║                                          ║                               ║
   ║  100 GiB hot-added disk → /var (128 GiB) ║                               ║
   ║  hosts all monitoring + vault PVCs        ║                               ║
   ╚══════════════════════════════════════════╝                               ║
```

---

## Application catalog (verified working 2026-05-18)

All apps are reachable both via the edge nginx proxy at `192.168.1.203` and via direct NodePort. Credentials live in different places per app — see "Credentials" column.

| App | Cluster | Namespace | URL via nginx proxy | Direct NodePort | Credentials |
|---|---|---|---|---|---|
| **Grafana** ("search head") | k3os-local | monitoring | http://192.168.1.203/grafana/ | http://192.168.1.181:30300 | `admin` / `changeme-home-lab` (in `monitoring/local-k3s/kube-prometheus-stack-values.yaml`) |
| **Prometheus** | k3os-local | monitoring | http://192.168.1.203/prometheus/ | http://192.168.1.181:30320 | none |
| **Loki** | k3os-local | monitoring | http://192.168.1.203/loki/ready | http://192.168.1.181:30310/ready | none (no UI; query via Grafana) |
| **Alertmanager** | k3os-local | monitoring | (not exposed) | ClusterIP 9093 | none; no notifier configured |
| **Vault UI** | k3os-local | vault | http://192.168.1.203/ui/ (also `/vault/` → 302 → `/ui/`) | http://192.168.1.181:31326/ui/ (vault-active, leader-only) | Method = **Token**; root token: `jq -r .root_token ~/.vault/init.json` on gdragon |
| **Vault API** | k3os-local | vault | http://192.168.1.203/v1/... | http://192.168.1.181:31326/v1/... | same root token (or any AppRole / KV-v2 token) |
| **ArgoCD server** | k3os-local | argocd | http://192.168.1.203/argocd/ | http://192.168.1.181:30401 (http) / :30400 (https) | `admin` / `kubectl --context k3os-local -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` |
| **Landing page** | k3os-local | (nginx) | http://192.168.1.203/ | n/a | none |
| **Promtail (local)** | k3os-local | monitoring | n/a | DaemonSet | n/a — pushes k3s logs to Loki with `cluster=k3os-local` |
| **Prometheus (homelab)** | homelab | monitoring | n/a | ClusterIP | n/a — remote_writes to gdragon:30320 with `cluster=homelab` |
| **Promtail (homelab)** | homelab | monitoring | n/a | DaemonSet (6 nodes) | n/a — pushes to gdragon:30310 with `cluster=homelab` |
| **k8s API (homelab)** | homelab | kube-system | not exposed | VIP 192.168.1.50:6443 | kubeconfig at `~/.kube/config` context `homelab` |
| **DNS (homelab)** | homelab | (on LBs) | n/a | VIP 192.168.1.50:53 | dnsmasq HA on lb1+lb2; `*.myhomelab.com` |
| **Istio (homelab)** | homelab | istio-system | not externally exposed | (ingressgateway pending LB-type Service) | n/a; sidecar injection on `default` namespace |

**How sub-path mode is configured per app:**
- **Grafana** — helm values `grafana.grafana.ini.server.{root_url, serve_from_sub_path}` in `monitoring/local-k3s/kube-prometheus-stack-values.yaml`.
- **Prometheus** — helm values `prometheus.prometheusSpec.{externalUrl, routePrefix}` in same file.
- **Loki** — nginx strips `/loki/` (Loki has no path-prefix awareness; its endpoints already live at `/ready`, `/metrics`, `/loki/api/v1/*`).
- **ArgoCD** — `argocd-cmd-params-cm` `server.rootpath: /argocd` (set in-cluster, not in this repo yet).
- **Vault** — none. Vault has no equivalent of `serve_from_sub_path`. Solution: nginx mounts Vault at the **root** paths it natively uses (`/ui/`, `/v1/`) and 302-redirects `/vault/*` → `/ui/`. Safe because no other app in the lab uses `/ui/` or `/v1/` at root.

---

## Image registry — quay.io

External (read for pulls, write for our own pushes). Two repos under `quay.io/bpraisa/`:

| Repo | Tags | Used for | Built / Mirrored from |
|---|---|---|---|
| `quay.io/bpraisa/nginx` | `homelab-proxy-1.0` … `homelab-proxy-1.4` | edge reverse proxy (containers nginx-1, nginx-2 on .203) | local build from `nginx-proxy/{Dockerfile,nginx.conf}` |
| `quay.io/bpraisa/vault` | `1.20.4`, `latest` | reserved for future helm-chart pulls (currently chart still pulls from `hashicorp/vault` on dockerhub) | `podman pull docker.io/hashicorp/vault:1.20.4` then retag + push |

**Auth model.** quay.io robot account (write-scoped to specific repos). Username + token stored ansible-vault encrypted in `ansible/group_vars/all/vault.yml` as `vault_quay_username` + `vault_quay_password`. `ansible/playbooks/quay-login.yml` runs `podman login` on the edge_proxy host and persists the credentials at `~/.config/containers/auth.json` for later non-interactive pushes.

**Gotcha — per-repo robot permissions.** Robot accounts on quay.io are scoped per-repo, not org-wide. A newly created repo needs the robot added under `Settings → User and Robot Permissions` with `Write` access. Symptom of missing permission: `unauthorized: access to the requested resource is not authorized` on `podman push`. Bit us 2026-05-18 when creating `quay.io/bpraisa/vault`.

**Push procedure** (nginx-proxy rebuild example):

```bash
# 1. Edit nginx-proxy/nginx.conf
# 2. Build on .203 (rootless podman):
scp nginx-proxy/{Dockerfile,nginx.conf} bstha@192.168.1.203:/tmp/
ssh bstha@192.168.1.203 \
  'cd /tmp && podman build -t quay.io/bpraisa/nginx:homelab-proxy-X.Y .'

# 3. Push (uses persistent authfile from quay-login.yml):
ssh bstha@192.168.1.203 \
  'podman push --authfile ~/.config/containers/auth.json quay.io/bpraisa/nginx:homelab-proxy-X.Y'

# 4. Bump the tag in nginx-proxy/install.sh and rerun it.
bash nginx-proxy/install.sh 192.168.1.203
```

---

## Load-balancer summary (both layers)

There are TWO independent load-balancer layers in this lab:

### Layer 1 — homelab API LB (HAProxy + keepalived HA pair)

| | |
|---|---|
| Hosts | lb1 (192.168.1.188, MASTER prio 101), lb2 (192.168.1.185, BACKUP prio 100) |
| Purpose | k8s API endpoint (TCP 6443) + HTTP/HTTPS ingress to worker NodePorts |
| VIP | 192.168.1.50 (keepalived VRRP, advert_int=1s, GARP on takeover) |
| Failover time | ~3 s on `systemctl stop keepalived` |
| Also serves | dnsmasq `myhomelab.com` (bind-dynamic, same VIP) |
| Backends | TCP roundrobin to kmaster1/2/3:6443, HTTP roundrobin to kworker*:30080/30443 |
| Stats | `http://<lb-ip>:8404/stats` on either |
| Driven by | `ansible/playbooks/loadbalancer.yml` |

### Layer 2 — edge user-facing proxy (nginx HA on gdragon-ubuntu)

| | |
|---|---|
| Host | gdragon-ubuntu (192.168.1.203, Ubuntu 24.04) |
| Purpose | Path-based reverse proxy to k3s and homelab user-facing apps |
| Containers | 2× `quay.io/bpraisa/nginx:homelab-proxy-1.4` (rootless podman) |
| Ports | nginx-1 → host :80, nginx-2 → host :8080 |
| HA model | Both run continuously, `--restart=always`; if `:80` is wedged, users fall back to `:8080`. True single-VIP failover would need keepalived in front. |
| Config | baked into the image — no host volume mount; rebuild + push to bump |
| Build/push | `nginx-proxy/build-and-push.sh` (uses ansible-vault robot creds; see `ansible/playbooks/quay-login.yml`) |

---

## Network flow — per cluster and per request type

### 1. User browser → app UI (via edge proxy)

```
Browser → 192.168.1.203:80 (nginx-1, podman rootless)
            │
            ├── location /grafana/    → 192.168.1.181:30300 (k3s NodePort)
            │                         → Service kps-grafana
            │                         → Pod kps-grafana-*  (Grafana 11.x)
            │
            ├── location /prometheus/ → 192.168.1.181:30320
            │                         → Service kps-prometheus → Pod prometheus-kps-prometheus-0
            │
            ├── location /loki/       → 192.168.1.181:30310
            │                         → Service loki → Pod loki-0
            │
            ├── location /ui/, /v1/   → 192.168.1.181:31326 (vault-active NodePort, leader-only)
            │                         → Service vault-active → Pod vault-0 (only the raft leader)
            │
            ├── location /argocd/     → 192.168.1.181:30401
            │                         → Service argocd-server → Pod argocd-server-*
            │
            └── location /            → static landing HTML (no upstream)
```

### 2. kubectl from workstation → homelab cluster

```
kubectl --context homelab ...
   │
   ▼
https://192.168.1.50:6443     (keepalived VIP)
   │
   ▼
lb1 (192.168.1.188, MASTER)   or lb2 (.185) if lb1 is down
   │  HAProxy tcp-mode, balance roundrobin
   ▼
kmaster1 .186 :6443  /  kmaster2 .189 :6443  /  kmaster3 .187 :6443
   │
   ▼
kube-apiserver → etcd quorum → response
```

### 3. Homelab cluster → local-k3s monitoring (cross-cluster data plane)

Two streams from homelab into local-k3s on .181:

```
Homelab Prometheus (in-cluster, ClusterIP)
   │
   │ remote_write (external label: cluster=homelab)
   ▼
192.168.1.181:30320     (k3s NodePort Service kps-prometheus)
   │
   ▼
Pod prometheus-kps-prometheus-0  (enableRemoteWriteReceiver=true)
   │
   └─→ stored alongside local scrapes (external label: cluster=k3os-local)


Homelab Promtail DaemonSet (on every k8s node)
   │
   │ HTTP push (cluster=homelab)
   ▼
192.168.1.181:30310     (k3s NodePort Service loki)
   │
   ▼
Pod loki-0
```

### 4. ArgoCD reconciliation flow

```
ArgoCD application-controller (on local-k3s)
   │  every ~3 min
   ▼
github.com/myhome-automation/git-vsphere  (HTTPS, anonymous read)
   │
   ▼
Diff desired (manifests in argocd/) vs live cluster state
   │
   ▼
Apply: kubectl apply (via in-cluster Service Account)
   - vault Application → helm chart pulled from helm.releases.hashicorp.com
   - future Applications similarly
```

### 5. Image pulls (where every container actually comes from)

```
nginx-proxy on .203          ← quay.io/bpraisa/nginx:homelab-proxy-1.4
                                (built by us; pushed from .203)

Vault pods on local-k3s      ← docker.io/hashicorp/vault:1.20.4
                                (chart default; mirror also at
                                 quay.io/bpraisa/vault:1.20.4 for
                                 future cutover)

Grafana / Prometheus / Loki  ← docker.io / ghcr.io (helm chart defaults)
                                via kube-prometheus-stack and loki-stack

ArgoCD                       ← quay.io/argoproj/argocd
                                (Argo project's official quay images)

Calico, kube-system, etc.    ← docker.io / quay.io (k3s/Calico defaults)
```

### 6. DNS resolution for cluster hosts

```
Cluster VM resolves myhomelab.com names
   │
   ▼
192.168.1.50:53  (VIP held by whichever LB is MASTER)
   │
   ▼ dnsmasq (bind-dynamic) on lb1 or lb2
   │
   ├── *.myhomelab.com   → answered from /etc/dnsmasq.hosts.d/myhomelab.hosts
   └── anything else     → forwarded upstream to 192.168.1.1 (home router)
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

## Edge / reverse proxy on .203 (added 2026-05-17)

```
  LAN ──► :80   ┌──────────────────────────────────────┐
       ──► :8080│  gdragon-ubuntu (192.168.1.203)      │
                │  podman rootless                     │
                │  ┌─ nginx-1 :80   ─┐  ┌─ nginx-2 :8080 ─┐
                │  │ same image:    │  │ same image:    │
                │  │ quay.io/.../   │  │ quay.io/.../   │
                │  │  nginx-homelab-proxy:1.0           │
                │  └────────┬──────┘  └────────┬───────┘
                │           │ path-based      │
                └───────────┼─────────────────┼────────┘
                            ▼                 ▼
       /grafana/    →  192.168.1.181:30300  (Grafana)
       /prometheus/ →  192.168.1.181:30320  (Prometheus)
       /loki/       →  192.168.1.181:30310  (Loki API)
       /vault/      →  192.168.1.181:30200  (Vault UI/API)
       /argocd/     →  192.168.1.181:30401  (ArgoCD)
       /           landing page
```

Both nginx containers run the **same baked-in image** and the same
config. HA model: if `nginx-1` (host `:80`) is wedged, users reach
`:8080`. Restart policy `always` recovers from container-level crashes.
True single-VIP failover would need keepalived between the two ports
— not needed for current scale.

Build/push: `bash nginx-proxy/build-and-push.sh quay.io/myhome-automation/nginx-homelab-proxy:1.0`.

App sub-path mode (each app must know it's behind a sub-path) status:
| App | Sub-path mode | Works through proxy? |
|---|---|---|
| Landing page (/) | n/a | ✅ |
| Loki API | n/a (no UI) | ✅ |
| Vault | partial | ✅ via `/vault/ui/` |
| Grafana | not set | ❌ — set `grafana.ini` `root_url` + `serve_from_sub_path` |
| Prometheus | not set | ❌ — set `--web.external-url=...prometheus/` `--web.route-prefix=/` |
| ArgoCD | not set | ❌ — set `--rootpath=/argocd` in `argocd-cmd-params-cm` |

---

## Cross-cluster Vault (added 2026-05-17)

Production-shape Vault on the local k3s. 3-replica StatefulSet with
integrated Raft storage. Deployed via ArgoCD (`argocd/vault.yaml`).

```
   ┌─ vault-0 (Raft leader, initialized, unsealed) ◄── KV-v2 + AppRole
   │
   ├─ vault-1 (pod up, sealed, NOT yet raft-joined)  ◄── Calico IPPool
   │                                                     overlap blocks
   └─ vault-2 (pod up, sealed, NOT yet raft-joined)      pod-to-pod
```

Reachable at `http://192.168.1.181:30200/ui/`. Unseal keys + root
token saved at `~/.vault/init.json` (chmod 600) on gdragon — move
to password manager and remove from disk.

---

## What's NOT in this cluster (yet)

- ingress controller inside homelab (istio-ingressgateway not exposed externally;
  nginx on .203 serves that role for user-facing access)
- persistent storage on homelab cluster (no SC, no PV provisioner — only emptyDir)
- backup / etcd snapshot strategy
- vSphere vCenter (single ESXi host only)
- Calico IPPool migration on local k3s (current 192.168.0.0/16 overlaps the
  home network; workstation-level MASQUERADE rule unsticks pod→external but
  pod-to-pod between Vault replicas still broken)
- Per-app sub-path config so Grafana/Prometheus/ArgoCD work through the
  nginx proxy (see "Edge / reverse proxy" table above)
- Vault auto-unseal (manual key entry today)

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

## LB pair failover sequence

Both lb1 and lb2 run **the same three services** at all times
(`haproxy`, `keepalived`, `dnsmasq`). Failover is just VIP movement —
no service-start delay.

```
                 ╔═══════════════════════╗      ╔═══════════════════════╗
   STEADY STATE  ║   lb1 (192.168.1.188) ║      ║   lb2 (192.168.1.185) ║
   (lb1 owns VIP)║   keepalived = MASTER ║◄═══►║   keepalived = BACKUP ║
                 ║   priority = 101      ║ VRRP ║   priority = 100      ║
                 ║   ───────────────────  ║  proto ║   ───────────────────  ║
                 ║   haproxy   :active   ║ 112  ║   haproxy   :active   ║
                 ║   dnsmasq   :active   ║      ║   dnsmasq   :active   ║
                 ║   listens on:         ║      ║   listens on:         ║
                 ║    127.0.0.1, .188,   ║      ║    127.0.0.1, .185    ║
                 ║    192.168.1.50 (VIP) ║      ║    (no VIP yet)       ║
                 ╚═══════════════════════╝      ╚═══════════════════════╝
                                  ▲
                                  │ clients hit VIP .50 → only lb1 answers
                                  │
                          ┌───────┴───────┐
                          │  workloads,   │
                          │  kubectl,     │
                          │  dig @.50     │
                          └───────────────┘

                                    │
                                    ▼  lb1 loses keepalived (crash, network drop, sysadmin stop)

                 ╔═══════════════════════╗      ╔═══════════════════════╗
   FAILOVER      ║   lb1 (192.168.1.188) ║      ║   lb2 (192.168.1.185) ║
   (~3 sec)      ║   keepalived = DOWN   ║      ║   keepalived = MASTER ║
                 ║   ───────────────────  ║      ║   priority = 100      ║
                 ║   haproxy still up    ║      ║   ───────────────────  ║
                 ║   dnsmasq still up    ║      ║   GARP for 192.168.1.50║
                 ║   (no traffic — VIP   ║      ║   bind-dynamic picks   ║
                 ║    gone, ARP flushed) ║      ║   up VIP on ens192     ║
                 ║                       ║      ║   dnsmasq now also     ║
                 ║                       ║      ║   listening on .50     ║
                 ╚═══════════════════════╝      ╚═══════════════════════╝
                                                          ▲
                                                          │ traffic to .50
                                                          │ resumes here
                                                  ┌───────┴───────┐
                                                  │  workloads    │
                                                  │  kubectl      │
                                                  │  dig @.50     │
                                                  └───────────────┘
```

Failure modes the pair covers:
- Power-off of lb1 VM → lb2 takes over.
- `systemctl stop keepalived` on lb1 → lb2 takes over.
- Kernel hang on lb1 → VRRP advert miss for 3 × `advert_int=1s` → lb2 takes over.

What it does *not* cover (single ESXi host):
- ESXi host crash → both LBs (and the rest of the cluster) gone together.
- DNS data drift between lb1 and lb2: `dns.yml` writes the same
  `myhomelab.hosts` to both, so they can't drift unless someone edits
  one host by hand.

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
