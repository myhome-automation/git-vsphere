# gitops/ — ArgoCD app-of-apps platform

Declarative source of truth for the platform. ArgoCD is bootstrapped once
(imperatively), then the root app reconciles everything else by sync-wave.
Design rationale: [`../docs/platform-architecture.md`](../docs/platform-architecture.md);
resume anchor: [`../arch.md`](../arch.md).

## Layout

```
bootstrap/
  project.yaml        AppProject "platform" (allowed repos + cluster resources)
  argocd-values.yaml  Helm values for ArgoCD itself (installed by Ansible)
  root-app.yaml       app-of-apps → apps/
apps/                 one ArgoCD Application per component (sync-wave annotated)
values/               Helm values referenced by the Applications ($values ref)
manifests/
  cert-manager/       ClusterIssuers + biplextech.com Certificate
```

## Multi-source pattern

Each Application pulls the upstream **Helm chart** from its vendor repo and the
**values file from this git repo** via ArgoCD's `$values` ref — so chart and
config are both version-controlled without vendoring the chart.

## Sync-wave order

| Wave | Component | Namespace | Chart ver |
|---|---|---|---|
| 0 | Longhorn (storage, default SC) | longhorn-system | 1.12.0 |
| 1 | cert-manager | cert-manager | v1.20.2 |
| 1 | ingress-nginx (cluster ingress) | ingress-nginx | 4.15.1 |
| 2 | cert-manager issuers + biplextech cert | cert-manager / ingress-nginx | — |
| 3 | Vault (HA Raft) | vault | 0.33.0 |
| 4 | Vault Secrets Operator | vault-secrets-operator | 1.4.0 |
| 5 | Consul (Connect mesh) | consul | 2.0.0 |
| 6 | OPA Gatekeeper (audit mode) | gatekeeper-system | 3.22.2 |
| 7 | kube-prometheus-stack | monitoring | 87.0.0 |
| 8 | Jenkins | jenkins | 5.9.28 |

## Edge & path map (single host `https://biplextech.com`)

TLS terminates at the **lb1/lb2 nginx gateway** (keepalived VIP `192.168.1.50`)
with a cert signed by the `biplextech.com` internal CA, then forwards path-based
to the **ingress-nginx** NodePort (`32080`). Ingress host-routes `biplextech.com`
by path:

```
/argocd     → argocd-server         (server.rootpath /argocd)
/grafana    → grafana               (serve_from_sub_path)
/prometheus → prometheus            (routePrefix /prometheus)
/alertmanager → alertmanager        (routePrefix /alertmanager)
/jenkins    → jenkins               (jenkinsUriPrefix /jenkins)
/longhorn   → longhorn-frontend     (ingress rewrite — no native sub-path)
/vault      → vault                 (ingress rewrite — UI hard-codes /ui)
/consul     → consul-ui             (ingress rewrite)
```

## Bootstrap procedure

```bash
# 0. Prereqs on all nodes (open-iscsi for Longhorn) + install ArgoCD
cd ansible
ANSIBLE_CONFIG=$PWD/ansible.cfg ansible-playbook playbooks/longhorn_prereqs.yml
ANSIBLE_CONFIG=$PWD/ansible.cfg ansible-playbook playbooks/argocd_bootstrap.yml
#    (installs ArgoCD with gitops/bootstrap/argocd-values.yaml, applies
#     project.yaml + root-app.yaml)

# 1. Register this private repo with ArgoCD (once)
argocd repo add https://github.com/myhome-automation/git-vsphere.git \
  --username <user> --password <token>

# 2. Watch the waves reconcile
kubectl -n argocd get applications -w
```

Wave 0 (Longhorn StorageClass) must be `Healthy` before waves 3+ (which need PVCs).

## Post-sync manual steps

- **Vault** comes up sealed + uninitialized. Init on `vault-0`, save the unseal
  keys/root token OFF-cluster (password manager — never commit), unseal all 3,
  confirm Raft peers. Mirrors the old k3s procedure in `../docs` but in the new
  `vault` namespace. Then create a `VaultAuth` + `VaultConnection` for VSO.
- **Gatekeeper** ships no constraints. Author `ConstraintTemplate`s +
  `Constraint`s with `enforcementAction: dryrun`, review audit, then flip to `deny`.
- **Grafana / Jenkins** admin passwords are bootstrap placeholders
  (`changeme-biplextech`) — rotate via Vault + VSO.

## Notes

- Chart versions pinned above were latest-stable on 2026-06-22. Bump deliberately;
  re-check sub-path value keys after a major chart bump.
- `external-secrets` is intentionally **not** deployed — Vault Secrets Operator
  covers secret delivery. Add later if a non-Vault backend is needed.
