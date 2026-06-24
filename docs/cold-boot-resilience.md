# Cold-boot resilience — no circular dependencies / deadlocks

This is a home-lab cluster that gets **powered off often**, so the platform must
converge on its own after a cold boot with no manual step that can deadlock.
This doc records the dependency design and the guards against boot deadlocks.

## The deadlock class we care about

A **boot deadlock** = component A can't start until B is up, and B can't start
until A is up (a cycle), OR a single failing component blocks the whole cluster
from making progress. The most dangerous instance in Kubernetes is an
**admission webhook** with `failurePolicy: Fail` whose backend pod is down: it
rejects the very pod creations needed to bring its backend up → the cluster
wedges. We hit exactly this with Consul's connect-injector.

## Rules enforced in this repo

1. **Admission webhooks that intercept general pods MUST be fail-open**
   (`failurePolicy: Ignore`). A not-ready backend can then never block unrelated
   pods from starting.
   - `consul` connectInject `failurePolicy: Ignore` (`gitops/values/consul.yaml`).
   - `ingress-nginx` admission `failurePolicy: Ignore` (`gitops/values/ingress-nginx.yaml`).
   - Webhooks that are `Fail` but scoped to their **own CRDs** (cert-manager,
     metallb, gatekeeper validation, consul CRD validators) are acceptable: a
     down backend only blocks writes to that component's own CRDs and ArgoCD
     retries — it cannot wedge general pod scheduling.

2. **ArgoCD has no storage dependency.** It runs with no PVC, so it always boots
   (even with Longhorn down) and reconciles everything else. ArgoCD is the
   bootstrapper; nothing it manages is a prerequisite for ArgoCD itself.

3. **Longhorn (storage) needs no StorageClass.** It uses hostPath
   `/var/lib/longhorn`, so the storage provider has no storage cycle. Everything
   stateful depends on Longhorn, never the reverse.

4. **PodSecurity:** the cluster default is `restricted` (CIS hardening). Infra
   namespaces that need hostNetwork/privileged are exempted per-namespace
   (`pod-security.kubernetes.io/enforce: privileged` via ArgoCD
   `managedNamespaceMetadata`) — never by weakening the cluster default.

## Boot order (acyclic — top needs nothing below it)

```
kubelet/containerd → etcd/apiserver (static pods)         [no deps]
  → Calico CNI                                            [no deps]
  → CoreDNS                                               [CNI]
  → ArgoCD                                                [no storage/webhook deps]
      └─ reconciles app-of-apps by sync-wave:
         -2 MetalLB            (hostNetwork; no storage/webhook deps)
         -1 MetalLB pool       (needs MetalLB controller)
          0 Longhorn           (hostPath; no StorageClass dep)  → StorageClass
          1 cert-manager, ingress-nginx (LB IP from MetalLB)
          2 cert-manager issuers
          3 Vault              (PVC ← Longhorn)            ← SEALED on boot, see below
          4 Vault Secrets Operator
          5 Consul             (PVC ← Longhorn; webhook fail-open)
          6 OPA Gatekeeper
          7 kube-prometheus    (PVC ← Longhorn)
          8 Jenkins            (PVC ← Longhorn)
```

No arrow points upward → no cycle. A later wave failing (e.g. Consul) cannot
block earlier waves because its webhooks are fail-open.

## The one operational dependency: Vault is SEALED after every boot

This is **not a cycle** (app → VSO → Vault is linear and recoverable), but it is
a manual step on every cold boot: Vault boots sealed, so VSO can't sync secrets
and pods that mount those secrets stay `ContainerCreating` until Vault is
unsealed. They recover automatically once it is — nothing deadlocks, it just
waits.

Options (pick one), in order of preference for an offline home lab:
- **Auto-unseal** via a Vault Transit unseal from a tiny always-up Vault, or a
  KMS — cleanest but heavier offline.
- **Unseal Job/CronJob** that reads keys from a k8s Secret and unseals on boot —
  convenient, but keys-at-rest in-cluster is a security trade-off.
- **Manual unseal** (current): run the unseal after boot. Keep apps tolerant
  (VSO retries; don't set hard init-container gates that crash-loop on a sealed
  Vault).

> Action item: decide Vault unseal strategy. Until then, unseal manually after
> each boot; everything else converges on its own.

## Verifying after a reboot

```
kubectl -n argocd get applications          # all should trend Synced/Healthy
kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations \
  -o json | jq -r '.items[].webhooks[] | "\(.failurePolicy)\t\(.name)"' | sort
# -> no 'Fail' webhook should match general pods (only own-CRD scopes)
kubectl get storageclass                    # longhorn present
kubectl -n vault exec vault-0 -- vault status   # unseal if Sealed=true
```
