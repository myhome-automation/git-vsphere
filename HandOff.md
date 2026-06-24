# HandOff.md — lessons, current state, resume anchor

> **Purpose:** persist what was learned (mistakes + fixes), the current state, and
> exactly where to resume — so the next session continues cleanly and does NOT
> repeat past mistakes. Keep this updated every session, alongside the memory
> files and `arch.md`.
>
> **Read order on resume:** (1) `arch.md` §0 → (2) **this file** → (3)
> `gdragon/awx/BUILD_PROGRESS.md` (live build log) → (4) `docs/architecture.md`
> (## CURRENT PLATFORM ARCHITECTURE) → (5) `docs/cold-boot-resilience.md`.

---

## Current state (2026-06-24, end of session — POWERED OFF for the day)

- **ESXi cluster:** 6/6 Ready, kubeadm 1.36.1, CIS-hardened. Built **AWX-first**.
- **⚠ CONTROL PLANE WAS CRASHLOOPING — root cause CLOCK SKEW** (kmaster1 was
  **703 s slow** of NTP; ESXi host clock drift). etcd `context deadline exceeded`
  → all 3 apiservers CrashLoopBackOff → intermittent `Forbidden`. **FIXED** with
  `chronyc makestep` on all nodes; apiservers stable (restarts frozen), 6/6 Ready.
  **This WILL recur on every boot** until ESXi host clock / VMware-Tools time sync
  is fixed — see lessons. `platform-startup.sh` now makesteps early.
- **Exposure chain UP (no NodePort):** Cloudflare → HAProxy (VIP **.50**) →
  MetalLB **.51** (ingress-nginx) → ingress-nginx. VIP `:443` serves the
  `*.biplextech.com` wildcard (cert-manager `biplextech-ca`), CA-verified.
- **Storage:** Longhorn default StorageClass `longhorn`; all stateful PVCs Bound.
- **Vault:** vault-0 **unsealed, Raft leader**. vault-1/2 **JOINED the raft**
  (3 peers: vault-0 leader, vault-1/2 followers) **but still SEALED** — unseal
  didn't complete; redo unseal next session. Keys:
  `~/.vault/biplextech-init.json` on gdragon (chmod 600, **NEVER commit**).
  `retry_join` is in git (`gitops/values/vault.yaml`) but **NOT yet in the live
  ConfigMap** (ArgoCD hadn't synced it) — confirm it syncs so vault-1/2 rejoin
  after reboot.
- **AWX + OpenVAS:** `https://awx.biplextech.com` / `https://openvas.biplextech.com`
  (via .203 nginx → .181 Traefik), admin / `Nepal!@3`.
- **TLS CA** trusted on all hosts; browser CA at `~/biplextech-ca.crt`.
- **DNS:** `.202` dnsmasq DOWN → `*.biplextech.com` doesn't resolve LAN-wide; use
  `/etc/hosts` meanwhile (platform→.50, awx/openvas→.203).

## Resume here — next steps (in order)
0. **After boot: FIRST `chronyc makestep` on all nodes** (or run
   `scripts/platform-startup.sh`) — else etcd/apiserver crashloop (clock skew).
   Verify 6/6 Ready + apiserver restarts not climbing before anything else.
1. **Finish Vault HA:** unseal vault-1/2 (3 keys each) → all 3 unsealed; confirm
   `retry_join` is in the live `vault-config` ConfigMap (ArgoCD synced) for
   reboot-safe auto-rejoin. Then init KV/auth as needed for VSO (wave 4).
2. **DNS:** bring **.202 dnsmasq** back so `*.biplextech.com` resolves; then
   per-app Ingress hostnames → apps reachable by URL.
3. Verify Consul / kube-prometheus / Gatekeeper / VSO / Jenkins converge.
4. **Durable clock fix** (critical for "reboots often"): disable VMware-Tools
   time sync on the VMs and/or fix the ESXi host clock/NTP.

---

## LESSONS — mistakes made & how they were fixed (do NOT repeat)

### AWX / Ansible execution-environment
- **AWX moved off NodePort → API is `https://awx.biplextech.com` (Traefik), NOT
  `:30080`.** Repeatedly hit dead `:30080` after the switch. Use the Host-header
  endpoint: `curl -H 'Host: awx.biplextech.com' http://192.168.1.181/api/...`.
- **AWX EE has no `sudo`** → playbooks with `hosts: localhost` must run with the
  Job Template `become_enabled: FALSE` (power-on JT failed `sudo: not found`).
  Per-play `become: true` on VM-targeting plays is fine.
- **AWX EE has no `helm`/`kubectl`** → `argocd_bootstrap.yml` (localhost) fails in
  AWX. Use `argocd_bootstrap_awx.yml` which runs on **kmaster1** via `admin.conf`
  and installs helm there.
- **AWX uses its OWN inventory** → the repo's `inventory/group_vars` symlink does
  NOT auto-load. Supply non-secret `vars.yml` as AWX **inventory variables**, and
  load the vaulted `vault.yml` via `vars_files` in the playbook (loadbalancer.yml)
  so the Vault credential decrypts it at runtime (don't put secrets in inventory).

### Host / infra
- **`sudo` secure_path excludes `/usr/local/bin`** → call k3s as
  `sudo /usr/local/bin/k3s kubectl ...` (full path). Same for **`crictl`** on the
  ESXi masters — `sudo crictl ...` returns "command not found", so a
  `crictl ps | grep -c apiserver` reads **0** and looks like the apiserver is
  down (FALSE ALARM). Use the full path / verify via `kubectl get` instead.
- **Transient `Forbidden` for `kubernetes-admin` (system:masters) is usually a
  restarting apiserver behind the VIP**, NOT a real RBAC break. With 3 apiservers
  behind keepalived/HAProxy, while one is restarting (e.g. hardening/encryption
  roll) ~1/3 of requests hit it and get 403 until its RBAC authorizer syncs.
  Don't panic-edit RBAC — re-test (`kubectl auth can-i ...`); it clears itself.
- **★ CLOCK SKEW = the #1 cluster killer here.** The ESXi host clock drifts (a
  known long-standing issue); VMware-Tools then syncs the VMs to that wrong time
  on boot. A ~12-min skew made etcd return `context deadline exceeded` on KV
  reads → apiserver `storage readiness` timeout → all 3 apiservers CrashLoopBackOff
  → intermittent cluster-wide `Forbidden`. Symptom looked like RBAC/apiserver
  death but was TIME. **Fix:** `sudo chronyc makestep` on every node (steps the
  clock immediately; `chronyc tracking` showed "703 s slow"). **Durable fix
  (TODO):** disable VMware-Tools time sync on the VMs and fix the ESXi host NTP,
  or this recurs every boot. ALWAYS makestep first after a cold boot.
- **ESXi maintenance mode = silent power-on killer.** Always
  `vim-cmd hostsvc/maintenance_mode_exit` before powering VMs.
- **"No route to host" on the SAME subnet = ARP failure = the target VM is
  POWERED OFF** — not a firewall issue. (The pod→LAN "UNREACHABLE" was just the
  VMs being off; gdragon firewalld already trusts the k3s pod/svc CIDR.)

### Kubernetes platform (the big cold-boot deadlocks)
- **Consul connect-injector mutating webhook (`failurePolicy: Fail`) + dead
  backend = cluster-wide pod-creation DEADLOCK.** Fixed: `connectInject.
  failurePolicy: Ignore`. Generalised in `docs/cold-boot-resilience.md`.
- **Longhorn `longhorn-pre-upgrade` PreSync hook needs a SA the MAIN sync
  creates → deadlocks on fresh ArgoCD install** (0 pods, ArgoCD frozen "waiting
  for hook"). Fixed: `preUpgradeChecker.jobEnabled: false` (the chart's OWN
  documented ArgoCD fix). ArgoCD stays frozen in the stale op → had to remove the
  app finalizer, delete + re-apply the Longhorn Application.
- **CIS hardening sets PodSecurity `restricted` cluster-wide → privileged infra
  pods are REJECTED** (MetalLB speaker hostNetwork/NET_RAW; Longhorn; Vault
  IPC_LOCK; kube-bench hostPID). Fix per-namespace: PSA `privileged` via ArgoCD
  `managedNamespaceMetadata` (and live label for immediate effect). Done for
  metallb-system, longhorn-system, vault; kube-bench ns labeled in k8s_audit.yml.
- **ArgoCD AppProject must list every helm repo** or the app errors "repo … not
  permitted in project". The AWX bootstrap re-run did NOT update the live
  AppProject → had to `kubectl apply gitops/bootstrap/project.yaml` directly.
- **Vault HA Raft needs `retry_join`** in the raft config, or vault-1/2 never
  join AND won't rejoin after a reboot. Manual `vault operator raft join` over
  slow SSH was flaky (`EOF`). Added retry_join (durable, reboot-safe).
- **Vault unseal via `| while read`** silently didn't apply; an explicit
  `for key in $(jq ... [:3][])` loop works.

### Edge / TLS / nginx
- **nginx on Ubuntu 24.04 (1.24)** wants `listen 443 ssl http2;` — the new
  `http2 on;` directive is unknown (1.25.1+ only).
- **Re-applying `gdragon/openvas/openvas.yaml` reset the admin Secret to the
  placeholder.** After any manifest apply, re-patch the live OpenVAS password.
- **kubectl secret with a dotted key:** `jsonpath='{.data.tls\.crt}'` escaping
  breaks through SSH — use `-o go-template='{{index .data "tls.crt"}}'`.
- **`/etc/hosts` is `IP hostname`** (IP first). User had it reversed → no resolve.

### Tooling
- **JSON `kubectl patch -p '{...}'` over SSH** breaks on quoting — pipe a script
  via `ssh '... bash -s'` or use `--patch-file=/dev/stdin`.
- SSH to the cluster is sometimes slow → wrap remote calls in `timeout` and keep
  long waits/polls in background commands.

---

## Conventions
- **No `Co-Authored-By` trailer** in commits.
- **Never commit secrets** — placeholders in git; real values set live.
- **Keep this file + `gdragon/awx/BUILD_PROGRESS.md` + `arch.md` §0 updated each
  session** (and the memory index).
