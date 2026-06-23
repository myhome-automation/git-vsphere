# Kubernetes hardening

This is the **phase 1** production-grade hardening applied to the homelab
cluster on top of the stock kubeadm install. It covers the items that
need no new components — only configuration changes — so the blast
radius is small and the rollback path is clean.

| # | Item | Where it lives | Who restarts |
|---|---|---|---|
| 1 | Secrets encryption at rest (aescbc) | `/etc/kubernetes/enc/encryption.yaml` on every master | kube-apiserver static pod (auto) |
| 2 | Audit logging | `/etc/kubernetes/audit/policy.yaml` + `/var/log/kubernetes/audit/` on every master | kube-apiserver static pod (auto) |
| 3 | kubelet hardening | `/var/lib/kubelet/config.yaml` on every node | `systemctl restart kubelet` |
| 4 | PodSecurity admission | `/etc/kubernetes/admission/admission.yaml` on every master + namespace labels | kube-apiserver static pod (auto) |
| 7 | kube-bench CIS audit | one-off Job in `kube-bench` namespace | n/a (read-only) |

Apply with:

```bash
cd ansible/
ansible-playbook -i inventory/hosts.ini --vault-password-file=.vault_pass \
  playbooks/k8s_harden.yml
# then audit:
ansible-playbook -i inventory/hosts.ini --vault-password-file=.vault_pass \
  playbooks/k8s_audit.yml
```

The playbook is idempotent and safe to re-run. Control-plane changes
roll `serial: 1` with a `/livez` health gate between each master, so the
cluster never loses quorum mid-flight.

## How the kubeadm-config ConfigMap fits in

`kubeadm` stores the cluster's `ClusterConfiguration` as a key in the
`kube-system/kubeadm-config` ConfigMap. The hardening playbook:

1. Pulls that key down on `kmaster1`,
2. Merges in the new `apiServer.extraArgs` + `apiServer.extraVolumes`
   via `files/k8s_harden/merge_cluster_config.py`,
3. Writes the merged config **back** to the ConfigMap so future
   `kubeadm upgrade` / `init phase` operations preserve the hardening,
4. Distributes it to each master,
5. Runs `kubeadm init phase control-plane apiserver --config=…` per
   master — that's the kubeadm-blessed way to regenerate the
   `kube-apiserver` static-pod manifest.

This is why we don't edit
`/etc/kubernetes/manifests/kube-apiserver.yaml` directly: anything we
wrote there by hand would be blown away on the next `kubeadm upgrade`.

## Item 1 — Secrets encryption at rest

**Why:** without this, every Secret object is stored in etcd as
base64-encoded plaintext. Anyone with read access to etcd snapshots
(including future *you* if a snapshot leaks) can read every Secret,
including ServiceAccount tokens.

**What we do:** add an `EncryptionConfiguration` with an `aescbc`
provider whose key is 32 random bytes, base64-encoded. The
`identity: {}` fallback means already-written secrets stay readable
until we rewrite them — Play 5 of the harden playbook does that with
`kubectl get secrets -A -o json | kubectl replace -f -`.

**Verify** (on kmaster1, as root):

```bash
sa=$(kubectl get sa default -o jsonpath='{.secrets[0].name}')
ETCDCTL_API=3 etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/default/$sa | hexdump -C | head
```

You should see `k8s:enc:aescbc:v1:key1:` at the start of the value
bytes. Before the hardening it would start with `k8s\n` followed by
plaintext.

### Key safety

The key file `/etc/kubernetes/enc/encryption.yaml` is **catastrophic to
lose**. If you lose it after secrets have been written with it:

- Every encrypted Secret in etcd becomes unreadable.
- The cluster will still start but every workload that mounts a Secret
  will fail.

Mitigations:

- The file is `0600 root:root` on all three masters, so losing one
  master is fine — you can copy from the other two.
- Back the file up out-of-band (password manager, or to the
  vault-server box) **after** running the playbook the first time:

  ```bash
  ssh ansible@kmaster1 'sudo cat /etc/kubernetes/enc/encryption.yaml' \
    | ssh ansible@vault-server 'sudo tee /root/encryption.yaml.bak >/dev/null \
        && sudo chmod 600 /root/encryption.yaml.bak'
  ```

### Key rotation

Out of scope for this playbook. Procedure summary if you ever need it:

1. Add a new `key2:` block **above** `key1:` (still encrypts with the
   first key listed; decrypts with any).
2. Re-roll apiserver via `kubeadm init phase control-plane apiserver`
   on each master.
3. `kubectl get secrets -A -o json | kubectl replace -f -` — now all
   secrets are written with `key2`.
4. Remove `key1:` from the config; re-roll apiserver again.

## Item 2 — Audit logging

Policy (`audit-policy.yaml`):

- **None** for `events` (very noisy, low value).
- **RequestResponse** for `secrets`, `configmaps`, and RBAC mutations
  — full request and response bodies are logged.
- **Metadata** for everything else — who, when, what verb, which
  object, but no payloads.

Rotation: `--audit-log-maxsize=100` MiB per file,
`--audit-log-maxbackup=10` files, `--audit-log-maxage=30` days. With
the default policy this is ~1 GiB worst-case per master.

**Tail it:**

```bash
ssh ansible@kmaster1 'sudo tail -f /var/log/kubernetes/audit/audit.log' | jq .
```

## Item 3 — kubelet hardening

Edits applied by `patch_kubelet_config.py` on every node:

| Field | Value | Why |
|---|---|---|
| `readOnlyPort` | `0` | Disables the unauthenticated `:10255` endpoint that leaks pod info |
| `protectKernelDefaults` | `true` | kubelet refuses to start if host sysctls don't match its expectations — surfaces drift |
| `eventRecordQPS` | `5` | Caps event-spam from a runaway pod (default is unbounded) |
| `tlsCipherSuites` | safe modern list | Drops CBC + SHA1 + RSA-key-exchange ciphers from the kubelet TLS handshake |

Restart is `systemctl restart kubelet`, rolled `serial: 1`, masters
first then workers. Pods on a restarting node stay running — kubelet
restart only briefly pauses status reporting.

## Item 4 — PodSecurity admission

`/etc/kubernetes/admission/admission.yaml` enables the `PodSecurity`
admission plugin **cluster-wide** with `enforce: restricted` as the
default. Restricted profile blocks:

- privileged containers
- host networking / IPC / PID
- writable hostPath mounts
- non-root containers running as UID 0
- capabilities beyond a small allowlist
- unconfined seccomp / AppArmor

The following namespaces are **exempted** because their workloads
legitimately need privilege (host networking, hostPath, etc.):

- `kube-system` — kube-proxy, coredns
- `calico-system`, `calico-apiserver`, `tigera-operator` — Calico CNI
- `istio-system` — Istio sidecar injector + ingress gateway

Existing workload namespaces get explicit labels too so
`kubectl get ns -L pod-security.kubernetes.io/enforce` reads cleanly.

**To add a new exempt namespace:** edit
`ansible/files/k8s_harden/admission.yaml`, add the namespace under
`exemptions.namespaces:`, and re-run `playbooks/k8s_harden.yml`.

## Item 7 — kube-bench CIS scan

`playbooks/k8s_audit.yml` runs `aquasec/kube-bench` as two Jobs (one
master, one node), collects the reports, and saves them under
`ansible/kube-bench-reports/`. It's read-only — no cluster mutations
beyond a transient `kube-bench` namespace that's deleted at the end.

Skim the report for `[FAIL]` lines. Common remaining gaps after this
phase:

- Anything in `5.x` (Policies) — typically NetworkPolicy / RBAC gaps
  that are out of scope for the host hardening done here.
- `1.2.x` warning about `--token-auth-file` and similar — only
  applicable if you've enabled those flags, which we haven't.

## Rollback

### Item 1 (encryption)

```bash
# WARN: you must rewrite secrets BEFORE removing the encryption config,
# or every Secret in etcd becomes unreadable.

# 1. Comment out --encryption-provider-config in the merged
#    ClusterConfiguration on each master and re-run kubeadm init phase.
# 2. kubectl get secrets -A -o json | kubectl replace -f -
# 3. Remove /etc/kubernetes/enc/ on each master.
```

### Item 2 (audit)

Remove the `audit-*` entries from `apiServer.extraArgs` in the merged
ClusterConfiguration, re-run `kubeadm init phase control-plane
apiserver` per master.

### Item 3 (kubelet)

Edit `/var/lib/kubelet/config.yaml` to remove the four fields,
`systemctl restart kubelet`.

### Item 4 (PSA)

```bash
# remove the admission config
kubectl edit cm kubeadm-config -n kube-system   # delete admission-control-config-file extraArg + k8s-admission extraVolume
# regenerate apiserver per master
# remove namespace labels:
for ns in $(kubectl get ns -o name); do
  kubectl label "$ns" \
    pod-security.kubernetes.io/enforce- \
    pod-security.kubernetes.io/audit- \
    pod-security.kubernetes.io/warn-   || true
done
```

## What this phase does NOT do

These are deliberately deferred to later phases (see the original plan
in chat 2026-06-19):

- **#5 NetworkPolicy default-deny** — needs per-workload egress
  allowlists; bigger time investment than a single playbook.
- **#6 etcd snapshot schedule** — short, but needs a target host
  decision (push to vault-server? to .181?).
- **#8 MetalLB** — adds a new component; deserves its own playbook +
  docs page.
- **#9 Velero** — adds a backup target (MinIO somewhere); separate
  scope.
- **#10 PDBs + ResourceQuota + LimitRange** — per-workload, not
  cluster-wide.
