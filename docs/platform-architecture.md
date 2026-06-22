# Platform Architecture — production-grade homelab on ESXi

Status: **active build** (started 2026-06-22). This is the source-of-truth design
doc for the platform buildout. Operational runbooks live in `docs/operations.md`;
the from-scratch infra build is in `docs/infra-implementation-notes.md`.

---

## 1. Goals

Turn the 6-node kubeadm cluster from a bare cluster (k8s + CNI only) into a
**production-shaped internal platform**, GitOps-managed end to end:

- **GitOps** as the single source of truth (ArgoCD, app-of-apps, sync-waves).
- **Secrets** centralized in **Vault** (in-cluster HA, Raft), surfaced to workloads
  by the **Vault Secrets Operator** ("vault controller").
- **Policy-as-code** with **OPA Gatekeeper** (audit first, then enforce).
- **Service mesh + service discovery** via **Consul** (Connect). Istio is removed.
- **Observability** via **kube-prometheus-stack** (Prometheus + Grafana + Alertmanager).
- **CI** via **Jenkins** in-cluster.
- **TLS everywhere** via **cert-manager** (internal CA issuer).
- **Persistent storage** via **Longhorn** (replicated block storage).
- Internal DNS zone **`biplextech.com`** on a dedicated server.
- North-south traffic via an **external HAProxy + nginx + keepalived VIP** fronting
  cluster NodePorts. No in-cluster cloud LB / MetalLB.

## 2. Decisions (locked 2026-06-22)

| Area | Decision | Rationale / consequence |
|---|---|---|
| Storage | **Longhorn** | Replicated, snapshots, prod-grade on bare metal. ~1 GB RAM/node overhead. |
| Service mesh | **Consul Connect**, **remove Istio** | Single mesh; consolidates mesh + service discovery + KV. Requires clean Istio uninstall. |
| Vault | **In-cluster HA (Raft, 3 replicas)** | Retires the standalone `vault-server` VM as a Vault host. PVCs on Longhorn. |
| `vault-server` VM (.202) | **Repurposed → authoritative DNS** for `biplextech.com` | Frees its Vault role; becomes the zone server. |
| Workers | **Stay at 8 GB** | No VM resize. Tight budget — enforced via requests/limits + replica counts. |
| Ingress / LB | **External HAProxy + 2× nginx + keepalived VIP → NodePorts** | Reuses the lb1/lb2 pattern. No MetalLB. |
| Secrets delivery | **Vault Secrets Operator** + (optional) External Secrets | Native CRD sync of Vault → k8s Secrets. |
| GitOps | **ArgoCD first, everything else through it** | Bootstrap ArgoCD once; app-of-apps drives the rest by sync-wave. |

## 3. Why ArgoCD-first (the ordering question)

Only **host-level / cluster-foundational** pieces are installed imperatively
(Ansible/Helm) because ArgoCD itself depends on them or they predate it:

```
BOOTSTRAP (imperative — Ansible/Helm, outside GitOps)
  1. Calico CNI ........................... done
  2. kubeadm hardening .................... ansible/playbooks/k8s_harden.yml
  3. Remove Istio ......................... ansible/playbooks/istio_remove.yml
  4. Longhorn node prereqs (open-iscsi) ... ansible/playbooks/longhorn_prereqs.yml
  5. ArgoCD ............................... ansible/playbooks/argocd_bootstrap.yml
     └─ then ArgoCD manages itself + all of the below
```

After ArgoCD is up, **nothing else is kubectl-applied by hand.** The root
app-of-apps reconciles every component, ordered by `argocd.argoproj.io/sync-wave`:

```
GITOPS (ArgoCD app-of-apps — gitops/)
  wave 0   Longhorn                      (StorageClass for everyone below)
  wave 1   cert-manager                  (TLS + webhooks dependency)
  wave 2   external-secrets (optional)   (CRDs before consumers)
  wave 3   Vault (HA Raft)               (needs Longhorn PVCs)
  wave 4   Vault Secrets Operator        (needs Vault reachable)
  wave 5   Consul (Connect mesh)         (KV + mesh + service discovery)
  wave 6   OPA Gatekeeper (audit mode)   (policies non-blocking first)
  wave 7   kube-prometheus-stack         (monitoring)
  wave 8   Jenkins                       (CI)
  wave 9   app workloads / biplextech routes
```

**Why not install Vault/Consul/Jenkins by hand "before Argo":** you lose the
single source of truth, drift detection, automated reconciliation, and the audit
trail — i.e. everything that makes the build prod-grade. The cost of bootstrapping
ArgoCD first is one Helm install; the payoff is every subsequent component is
declarative and reviewable.

## 4. Network & DNS

```
client → biplextech.com / *.biplextech.com
          │  (DNS A/wildcard served by 192.168.1.202)
          ▼
   keepalived VIP 192.168.1.50         (HAProxy on lb1/lb2, MASTER/BACKUP)
          │  L7 vhost routing + 2× nginx
          ▼
   cluster NodePorts (kworker1-3 :3xxxx)
          ▼
   ClusterIP services → pods
```

- **DNS server:** `192.168.1.202` (ex-`vault-server`), authoritative for
  `biplextech.com`. Wildcard `*.biplextech.com → 192.168.1.50`. Forwards
  everything else upstream (`8.8.8.8`). lb1/lb2 dnsmasq stays for the lab/DHCP
  role; the `biplextech.com` zone is delegated to .202.
- **VIP `192.168.1.50`:** keepalived MASTER on lb1 (prio 101), BACKUP on lb2 (100).
- **HAProxy/nginx vhosts** (initial): `argocd`, `grafana`, `prometheus`,
  `alertmanager`, `vault`, `consul`, `jenkins` `.biplextech.com` → respective
  NodePorts.

## 5. Resource budget (the hard constraint)

ESXi host = **60 GB physical**. Current allocation (post Istio removal,
vault-server now DNS not Vault):

| Group | Count | RAM each | Subtotal |
|---|---|---|---|
| masters | 3 | 4 GB | 12 GB |
| workers | 3 | 8 GB | 24 GB |
| lb1/lb2 | 2 | 2/1 GB | 3 GB |
| dns (.202) | 1 | 2 GB | 2 GB |
| **total** | | | **~41 GB** |

~24 GB of worker RAM must hold: Longhorn, Vault×3, Consul (servers+clients),
Gatekeeper, cert-manager, ArgoCD, Prometheus+Grafana+AM, Jenkins. **This is tight.**
Mitigations baked into the GitOps values:

- Prometheus retention small (e.g. 7d), Grafana 1 replica, Alertmanager 1 replica.
- Consul servers = 3 but client agents lightweight; Vault = 3 replicas (HA quorum).
- Gatekeeper 1–2 replicas; ArgoCD non-HA (single replica controllers).
- Jenkins 1 controller, ephemeral k8s agents (no idle executors).
- Every Application sets explicit `resources.requests/limits`.
- If it doesn't fit: drop Vault to a single replica (dev HA) or move Jenkins to
  on-demand. Revisit worker resize (12 GB) if pressure is chronic.

## 6. Repo layout (new + changed)

```
gitops/
  bootstrap/
    argocd/                 # ArgoCD install values (Helm) — applied by Ansible once
    root-app.yaml           # app-of-apps Application → gitops/apps/
  apps/                     # one ArgoCD Application per component (sync-waves)
    longhorn.yaml
    cert-manager.yaml
    vault.yaml
    vault-secrets-operator.yaml
    consul.yaml
    gatekeeper.yaml
    kube-prometheus-stack.yaml
    jenkins.yaml
  values/                   # Helm values referenced by the Applications
    *.yaml
ansible/playbooks/
  dns_biplextech.yml        # repurpose .202 as biplextech.com DNS
  istio_remove.yml          # clean Istio uninstall
  longhorn_prereqs.yml      # open-iscsi + nfs-utils on all nodes
  argocd_bootstrap.yml      # one-time ArgoCD install + root app
```

`argocd/vault.yaml` and `vault/values.yaml` at the repo root are **legacy** (old
k3s Vault) and will be superseded by `gitops/apps/vault.yaml` +
`gitops/values/vault.yaml`. Kept until the in-cluster Vault is verified, then removed.

## 7. Execution order (tasks)

1. Design doc (this file).
2. `dns_biplextech.yml` — stand up `biplextech.com` on .202; flip `domain` var.
3. `istio_remove.yml` — uninstall Istio.
4. Apply kubeadm hardening + fix kube-bench tag; run audit.
5. `longhorn_prereqs.yml` + `argocd_bootstrap.yml` + GitOps app-of-apps tree.
6. External HAProxy/nginx vhosts + VIP for `*.biplextech.com`.

Each step is independently verifiable; waves 3+ only proceed once wave 0
(Longhorn StorageClass) is `Healthy`.
