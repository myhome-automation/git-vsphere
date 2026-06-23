# arch.md — Platform Buildout: master plan & resume anchor

> **Purpose:** single page to resume the production-grade platform buildout from
> wherever it was left, consistently, across sessions. Deep design rationale is in
> [`docs/platform-architecture.md`](docs/platform-architecture.md). Operational
> day-2 runbook is `docs/operations.md`.
>
> **How to use:** read §0 (Resume here) first, do the next unchecked task in §4,
> then update §0 + the checkbox and commit. Keep this file truthful — it is the
> contract for the next session.

---

## 0. Resume here — current state (update every session)

**Last updated:** 2026-06-22 (DNS applied)

**Cluster:** kubeadm v1.36.1, 3 masters + 3 workers, Calico v3.30.4, all Ready.
Context `homelab`. **No StorageClass yet. No LB controller (by design — external).**

**Phase progress:**

- [x] Decisions locked (§2) + design doc written (`docs/platform-architecture.md`)
- [x] `arch.md` resume anchor created + pushed
- [x] **GitOps tree authored** (`gitops/`): bootstrap (project + root-app +
      argocd values), 10 app-of-apps Applications waves 0–8, path-based values,
      cert-manager issuers + biplextech cert. Pinned chart versions. **Not yet
      applied** — needs ArgoCD bootstrap on the live cluster.
- [x] **DNS applied & verified** — `vault-server` .202 authoritative for
      `biplextech.com` via dnsmasq; apex `biplextech.com → .50` (path-based, no
      wildcard), node A records, upstream forwarding. All 9 VMs flipped to .202
      (primary) + 8.8.8.8 (secondary) via NetworkManager. Verify:
      `dig @192.168.1.202 biplextech.com +short` → `192.168.1.50`.
- [ ] **NEXT →** Remove Istio (`istio_remove.yml`)
- [ ] Apply kubeadm hardening + fix kube-bench tag + run audit
- [ ] `longhorn_prereqs.yml` + `argocd_bootstrap.yml` → reconcile waves 0–8
- [ ] Edge gateway: lb1/lb2 nginx (TLS + path routing) + VIP → ingress-nginx
      (`edge_gateway.yml`); distribute biplextech.com CA cert
- [ ] Wave 0–8 apps reconciled & verified (Longhorn → Jenkins); Vault init/unseal

**Known blockers to clear before any stateful app:**
1. No storage → Longhorn (wave 0) must be `Healthy` first.
2. No north-south path → external HAProxy/nginx VIP must front NodePorts.

**Uncommitted WIP in tree:** `ansible/playbooks/k8s_{harden,audit}.yml`,
`ansible/files/k8s_harden/`, `docs/k8s-hardening.md` — hardening, validated but
**not applied** to live cluster; `k8s_audit.yml` still references a bad kube-bench
tag (`v0.11.4` — use a real one, e.g. `v0.15.6`).

---

## 0.1 Scope — everything inside ESXi

All platform components run **inside the ESXi host** (the 9 homelab VMs). The edge
gateway is **lb1/lb2 (ESXi VMs)** + keepalived VIP `.50`. The external **Ubuntu
edge box (`gdragon-edge` 192.168.1.203)** and the **gdragon workstation/k3s** are
**out of scope** and not used by this build — no GitOps app or new playbook targets
them. (`edge_gateway.yml` targets the `loadbalancers` inventory group, not
`edge_proxy`.) The old k3s-era `monitoring/`, root `argocd/`, `vault/`, and
`nginx-proxy/` dirs are legacy and will be retired once the in-cluster equivalents
are verified.

## 1. What we are building

A bare kubeadm cluster → a **GitOps-managed internal platform**:

| Capability | Component | Notes |
|---|---|---|
| GitOps control plane | **ArgoCD** | Bootstrapped once, then self-manages + app-of-apps |
| Storage | **Longhorn** | Replicated block storage, StorageClass for all PVCs |
| TLS / certs | **cert-manager** | Internal CA ClusterIssuer |
| Secrets | **Vault** (HA Raft, in-cluster) + **Vault Secrets Operator** | Replaces the standalone vault-server VM role |
| Service mesh + discovery + KV | **Consul (Connect)** | **Istio is removed** |
| Policy-as-code | **OPA Gatekeeper** | Audit mode first, then enforce |
| Observability | **kube-prometheus-stack** | Prometheus + Grafana + Alertmanager |
| CI | **Jenkins** | Controller + ephemeral k8s agents |
| Internal DNS | **BIND/dnsmasq on .202** | Authoritative for `biplextech.com` |
| North-south | **HAProxy + 2× nginx + keepalived VIP** (external) | Fronts NodePorts; no MetalLB |

## 2. Decisions (locked 2026-06-22)

- **Storage = Longhorn** (replicated, prod-grade; ~1 GB RAM/node).
- **Mesh = Consul Connect; remove Istio** (consolidate mesh+discovery+KV).
- **Vault in-cluster HA (Raft, 3 replicas)**, PVCs on Longhorn.
- **`vault-server` VM (.202) repurposed → authoritative DNS** for `biplextech.com`.
- **Workers stay at 8 GB** (no resize) — budget enforced via requests/limits.
- **Edge = lb1/lb2 nginx + HAProxy + keepalived VIP `.50`**, TLS-terminating
  (cert from the `biplextech.com` internal CA), **path-based** on a single host
  `https://biplextech.com/<app>`, forwarding to the in-cluster **ingress-nginx**
  (NodePort 32080). No MetalLB.
- **ArgoCD first; everything else through ArgoCD** by sync-wave.

## 3. Topology

```
client → https://biplextech.com/<app>
   │  DNS (authoritative) on 192.168.1.202  →  biplextech.com A 192.168.1.50
   ▼
keepalived VIP 192.168.1.50   (lb1 MASTER / lb2 BACKUP)
   │  nginx API gateway: TLS terminate (biplextech.com CA cert) + path route
   ▼
ingress-nginx NodePort 32080 (kworker1-3)  →  Ingress host-route by path
   ▼
ClusterIP service (sub-path configured)  →  pods

Path map (single host https://biplextech.com):
  /argocd /grafana /prometheus /alertmanager /jenkins  (native sub-path)
  /longhorn /vault /consul                             (ingress rewrite)

Inventory:
  masters   kmaster1-3   .186/.189/.187   4 GB
  workers   kworker1-3   .182/.183/.184   8 GB
  lb pair   lb1/lb2      .188/.185        VIP .50, HAProxy+keepalived+dnsmasq
  dns       .202 (ex vault-server)        biplextech.com authoritative
```

## 4. Execution plan (do in order — each step is independently verifiable)

### Step A — DNS: `biplextech.com` on .202  ✅ DONE
- `ansible/playbooks/dns_biplextech.yml`: installs dnsmasq on .202, apex
  `biplextech.com → 192.168.1.50` (path-based single host — **no wildcard**),
  node A records, forwards upstream. `.202` is in the `[dns]` inventory group.
  Second play flips every host's resolver to .202 (primary) + upstream (secondary).
- Flipped `group_vars/all/vars.yml` `domain: biplextech.com` (+ `dns_server`,
  ingress NodePorts for Step F).
- **Verify:** `dig @192.168.1.202 biplextech.com +short` → `192.168.1.50`.

### Step B — Remove Istio
- `ansible/playbooks/istio_remove.yml`: `istioctl uninstall --purge -y`, delete
  `istio-system`, strip `istio-injection` labels.
- **Verify:** `kubectl get ns | grep -v istio`; no istio pods, no mutating webhook.

### Step C — kubeadm hardening
- Fix kube-bench image in `k8s_audit.yml` → `docker.io/aquasec/kube-bench:v0.15.6`.
- `ansible-playbook playbooks/k8s_harden.yml` (secrets encryption-at-rest, audit
  log, kubelet hardening, PodSecurity). Then `k8s_audit.yml`.
- **Verify:** apiserver has `--encryption-provider-config`, `--audit-policy-file`;
  kube-bench report in `ansible/kube-bench-reports/`. Commit the WIP.
- ⚠ `ANSIBLE_CONFIG=$PWD/ansible.cfg` (repo dir is group-writable → cfg ignored).

### Step D — ArgoCD + GitOps tree
- `longhorn_prereqs.yml`: `open-iscsi` + `nfs-utils` + enable `iscsid` on all nodes.
- `argocd_bootstrap.yml`: Helm-install ArgoCD (non-HA), apply `gitops/bootstrap/root-app.yaml`.
- Build `gitops/apps/*.yaml` (Applications, sync-waves 0–9) + `gitops/values/*.yaml`.
- **Verify:** `kubectl -n argocd get applications` → all `Synced/Healthy` wave by wave.
  Longhorn StorageClass present before Vault/Consul/Prometheus/Jenkins sync.

### Step E — External ingress
- Extend lb1/lb2 HAProxy + nginx with vhosts → platform NodePorts; keepalived VIP.
- **Verify:** `curl -H 'Host: argocd.biplextech.com' http://192.168.1.50/` → ArgoCD.

## 5. GitOps sync-wave order (ArgoCD app-of-apps)

```
0 Longhorn   1 cert-manager   2 external-secrets   3 Vault(HA Raft)
4 Vault Secrets Operator   5 Consul(Connect)   6 OPA Gatekeeper(audit)
7 kube-prometheus-stack   8 Jenkins   9 app workloads
```

## 6. Resource budget (60 GB ESXi host — the hard limit)

masters 3×4 + workers 3×8 + lb 3 + dns 2 ≈ **41 GB**. ~24 GB worker pool holds the
whole platform → **tight**. Enforced: small Prom retention, single-replica Grafana/
AM/ArgoCD-controllers, ephemeral Jenkins agents, explicit requests/limits on every
app. Escape hatch: Vault→1 replica, or revisit 12 GB workers if pressure is chronic.

## 7. Conventions / gotchas (carry forward)

- Commits: **no `Co-Authored-By` trailer** in this repo.
- Ansible: export `ANSIBLE_CONFIG=$PWD/ansible.cfg` from `ansible/` (group-writable dir).
- Pod CIDR `10.0.0.0/16`; firewalld must allow Calico (already fixed in playbooks).
- ESXi 6.7: busybox sh, buggy scp (`cat | ssh 'cat >'`), maintenance-mode traps.
- Legacy to retire after in-cluster Vault verified: root `argocd/vault.yaml`,
  `vault/values.yaml`, `monitoring/` (old k3s stack).
