1# HandOff.md — lessons, current state, resume anchor

> **Purpose:** persist what was learned (mistakes + fixes), the current state, and
> exactly where to resume — so the next session continues cleanly and does NOT
> repeat past mistakes. Keep this updated every session, alongside the memory
> files and `arch.md`.
>
> **Read order on resume:** (1) `arch.md` §0 → (2) **this file** → (3)
> `gdragon/awx/BUILD_PROGRESS.md` (live build log) → (4) `docs/architecture.md`
> (## CURRENT PLATFORM ARCHITECTURE) → (5) `docs/cold-boot-resilience.md`.

---

## Current state (2026-06-24 — cluster STABLE after master RAM boost)

- **Cold-boot brought the cluster back 2026-06-24:** powered off the retired
  `.202` vault-server VM, powered on the 8 cluster VMs (`cluster_powerup.yml`),
  `chronyc makestep` all nodes. **THREE boot-killers found + fixed durably:**
  (1) kubelet `protectKernelDefaults` sysctls not persisted → kubelet crashloop
  (`k8s_harden.yml` Play 3.9 + `platform-startup.sh` 5c). (2) **Clock skew RECURS**
  — VMware-Tools periodic sync pulled VMs back to the drifted ESXi host clock
  (~370 s) minutes after makestep → DURABLE FIX: `vmware-toolbox-cmd timesync
  disable` on all VMs (now in `base.yml`, TODO confirm committed) + makestep at
  boot. (3) Vault sealed-pod crashloop (tight liveness probe) → tolerant probes
  in `gitops/values/vault.yaml`. Force-deleted ~72 stale `Unknown` pods.
- **★★ FIXED — master flapping was RAM-STARVED CONTROL PLANE (4 GB).** The
  CIS-hardened control plane (etcd+apiserver+controllers+calico) didn't fit in
  4 GB → under GitOps load etcd/apiserver got evicted, kubelets stopped posting
  status → masters flapped `NotReady` → transient cluster-wide `Forbidden`.
  **DONE 2026-06-24: boosted all 3 masters 4 GB → 8 GB** (ESXi: power off VM →
  `sed memSize="8192"` in the .vmx → `vim-cmd vmsvc/reload` → power on, ONE master
  at a time keeping etcd quorum; used the freed `.202` headroom). RESULT: **6/6
  Ready, apiserver restart counts FROZEN (verified stable over 100 s)** — flapping
  gone. Each reboot came back clean (persisted sysctl + VMware-timesync-disable
  held: clock 0.000 s, kubelet OK). Masters are 8 GB; workers still 7.5 GB.
- **PodSecurity `restricted` (CIS, cluster-wide) blocked Jenkins + VSO** — their
  chart pods/hooks don't set `drop:[ALL]`/seccomp → jenkins-0 `FailedCreate`, VSO
  `upgrade-crds` hook stuck 21 h. **FIX: set those namespaces to PSA `baseline`**
  via ArgoCD `managedNamespaceMetadata` (`gitops/apps/jenkins.yaml`,
  `vault-secrets-operator.yaml`) — baseline blocks privileged/host access but
  permits the CI/operator pods (harden to restricted later via per-container
  securityContext). Both now Synced/Healthy.
- **Post-reboot kworker2/3 pod→ClusterIP (10.96.0.1) was broken** (ArgoCD
  controller + vault-1/2 exec hung there) — fixed by restarting kube-proxy +
  calico-node on those nodes. Don't over-restart ArgoCD on this small cluster.
- **★ Vault AUTO-UNSEAL IMPLEMENTED (2026-06-25).** A single-node transit
  "unseal" Vault runs on the always-on gdragon k3s (`gdragon/vault-transit/`,
  servicelb `192.168.1.181:8200`, unsealed once; keys `~/.vault/transit-init.json`
  chmod 600 NEVER commit). The cluster Vault has a `seal "transit"` stanza
  (`gitops/values/vault.yaml`) with the token via `VAULT_TOKEN` env from secret
  `vault-transit-token` (NOT git). Migrated shamir→transit on vault-0 with
  `vault operator unseal -migrate` (shamir keys are now RECOVERY keys). VERIFIED:
  **vault-0 auto-unseals on restart with NO manual keys**; data intact
  (agent-registry engine), root token valid, HA Mode active. vault-1/2 HA replicas
  currently BLOCKED by **Longhorn** (fresh PVCs came up `faulted` after rapid
  churn on the constrained workers) — not a seal issue; let Longhorn settle / fix
  the volumes, then they auto-unseal via transit + retry_join. Vault is
  operational on vault-0.
- **Consul ACLs ENABLED (2026-06-25):** `global.acls.manageSystemACLs=true`;
  bootstrap/admin token in secret `consul-bootstrap-acl-token` (retrieve:
  `kubectl get secret consul-bootstrap-acl-token -n consul -o jsonpath='{.data.token}'|base64 -d`).
  Consul UI login = that token (Consul uses token auth, no user/pass). NOT in git.
- **Host-based ingress for Vault + Consul** (their UIs redirect to `/ui` so
  path-routing 404'd): `vault.biplextech.com` / `consul.biplextech.com` → .50
  (verified 200). DNS records on `.203` dnsmasq (`dns_biplextech.yml`).
- **GitOps app status (2026-06-24 end, cluster STABLE):** Synced/Healthy =
  cert-manager(+issuers), **gatekeeper(OPA)**, ingress-nginx, longhorn,
  metallb(+config), **vault**, **jenkins** (2/2), **vault-secrets-operator** (2/2).
  consul = Healthy (OutOfSync drift). **kube-prometheus-stack FIXED 2026-06-24:**
  there were TWO helm releases (`kps` + `kube-prometheus-stack`) → TWO prometheus
  operators fighting over the CRs → churn. Deleted the old `kps` release entirely
  (deploys/sts/ds/Prometheus CR/helm-secret) → single operator, Grafana+Prometheus
  +Alertmanager all Running. Grafana also needed `initChownData.enabled:false`
  (its root chown init violated `restricted` PSA). platform-root OutOfSync (clears
  as children settle). **Consul service mesh control plane UP:** 3 servers +
  connect-injector.
- **URLs (path-based on `biplextech.com`, VIP .50 → ingress .51, wildcard TLS).
  ALL verified responding (2026-06-24):** `/argocd`(200) `/grafana`(302) `/prometheus`(302)
  `/alertmanager`(200) `/consul`(301) `/vault`(307) `/longhorn`(200) `/jenkins`(403=login).
  **Login = `admin` / `<admin-pw>` (stored in K8s Secret, NOT git — see below)** on ArgoCD, Grafana, Jenkins (verified 200).
  Consul/Prometheus/Alertmanager/Longhorn = open UI. Vault = token (root token in
  `~/.vault/biplextech-init.json`). **Loki + OpenSearch/search NOT deployed**
  (a `promtail` DaemonSet exists with no Loki backend — orphan).
- **★ "can't browse / 404 except jenkins" = client resolves `biplextech.com` to the
  WRONG IP.** It MUST resolve to **.50** (platform VIP). The `.203` edge nginx only
  knows awx/openvas vhosts → returns 404 for `/argocd` etc. Fix the browsing client:
  point its DNS at **.203** (LAN dnsmasq returns `biplextech.com`→.50) OR add
  `/etc/hosts: 192.168.1.50 biplextech.com`, AND trust the CA (`~/biplextech-ca.crt`).
  On the `.203` box itself this needed a systemd-resolved drop-in routing
  `~biplextech.com`→127.0.0.1 (its own dnsmasq), else resolved sent it upstream.
- **Credentials are CONSISTENT (`admin`/`<admin-pw>` (stored in K8s Secret, NOT git — see below)) and NOT in git:** ArgoCD
  (live bcrypt patch of `argocd-secret`), Grafana + Jenkins via **`existingSecret`**
  (out-of-band Secrets `grafana-admin-credentials` / `jenkins-admin-credentials`;
  only the secret NAME is in git). Grafana existing-admin pw set via
  `grafana cli admin reset-admin-password` (env doesn't reset an existing user).
- **Longhorn FIXED (2026-06-25):** vault-1/2 volumes were `faulted` /
  `ReplicaSchedulingFailure: insufficient storage` — disks reserve 30% + the SUM
  of REQUESTED replica sizes hit the 100% over-provision cap (~1.6 Gi schedulable)
  though ~50 Gi was actually free. Fix: `storageOverProvisioningPercentage: 200`
  (live + `gitops/values/longhorn.yaml`) → volumes schedule healthy (0 faulted).
  Also Longhorn UI → **host-based `longhorn.biplextech.com`** (path `/longhorn`
  rendered blank — UI has no sub-path). vault-1/2 now schedule + run + reach the
  cluster.
- **★★ Vault 3-node HA AUTO-UNSEAL WORKING (2026-06-25).** REAL root cause (NOT a
  version bug — earlier notes were wrong): the raft listener was `cluster_address
  = "[::]:8201"` (IPv6 wildcard), but **IPv6 is disabled cluster-wide (CIS)** →
  follower cluster listener failed `listen tcp [::]:8201: address family not
  supported by protocol` → port 8201 never started → leader couldn't replicate →
  followers never got the transit-unseal keys (`stored unseal keys none found`).
  vault-0 worked only because a single node needs no 8201 replication. **FIX:
  bind `0.0.0.0` (IPv4) in `gitops/values/vault.yaml`.** Result: all 3 unseal via
  transit, all 3 raft **voters**, autopilot Healthy; verified a follower restart
  → **auto-unseals + rejoins**. Image: `openbao/openbao:2.1.1`. New root/recovery
  keys in `~/.vault/biplextech-init.json` (NEVER commit). Also raised Longhorn
  `storageOverProvisioningPercentage:200` + cleaned 20 orphaned Longhorn volumes
  (Retain reclaim left them after the rebuild churn, filling disks).
- _(superseded)_ earlier OpenBao-version theory:
  Followers DO `retry_join` and join vault-0's raft membership (seen in peer list),
  but the join never delivers/stores the transit-unseal keys → autoseal loops
  `stored unseal keys ... none found`; leader then can't replicate because a SEALED
  follower doesn't open cluster port 8201 (`connection refused` on appendEntries)
  → follower stuck at raft Last Index 0. **Reproduced identically on OpenBao 2.0.2
  AND 2.0.3, even on a FRESH 3-node rebuild** — so it's a 2.0.x line bug, not the
  migration/config. Image now pinned `openbao/openbao:2.0.3` in
  `gitops/values/vault.yaml` (was a retagged `hashicorp/vault:2.0.2`).
  **vault-0 is fully operational on 2.0.3: active + transit auto-unseal verified
  (restart → unsealed, no manual keys).** New root token after the fresh re-init is
  in `~/.vault/biplextech-init.json` (recovery keys too; NEVER commit).
  **To get 3-node HA, move to OpenBao 2.1.x** (confirmed pullable `openbao/openbao:2.1.1`;
  the 2.1 line fixes the follower auto-unseal path) — was tested-ready but user
  chose 2.0.3. Alternative: real `hashicorp/vault:1.18.x` (BUSL). Single-node
  vault-0 is the current working state.
- **STILL TODO (next session):** (2) GitHub App pipeline in
  Jenkins (net-new; app repo is separate). (3) VSO secret-sync
  (VaultConnection/VaultAuth/VaultStaticSecret CRs) — migrate the live admin
  Secrets into Vault and sync them out. (4) Consul service-mesh demo wiring.
  (5) optional: layer TLS on the gdragon transit Vault.
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
  (via .203 nginx → .181 Traefik), admin / `<admin-pw>` (stored in K8s Secret, NOT git — see below). **Both verified loginable
  2026-06-24 (next session):** AWX token POST → 201; OpenVAS admin pw re-set on the
  live gvmd (`gvmd --user=admin --new-password`) and verified via `gvm-cli ...
  socket <get_version/>` → status 200. (Initial blocker was DNS, not creds.)
  **AWX browser login then 403'd on CSRF** (Origin not trusted behind the proxy) —
  fixed via AWX CR `extra_settings: CSRF_TRUSTED_ORIGINS=['https://awx.biplextech.com']`
  + awx-web restart; verified web login → 302 + sessionid. See lessons.
- **TLS CA** trusted on all hosts; browser CA at `~/biplextech-ca.crt`.
- **DNS MOVED to the always-on edge box `.203` (2026-06-24); `.202` retired.**
  Rationale: `.202` was a VM on the often-rebooted, clock-skewing ESXi cluster —
  fragile for LAN name resolution. `.203` (Ubuntu edge nginx) boots first and
  independently of ESXi, and already fronts AWX/OpenVAS. **In-cluster CoreDNS
  stays cluster-internal ONLY** (making the cluster the LAN resolver = circular
  cold-boot dependency). Live: dnsmasq on `.203` authoritative for
  `biplextech.com` (apex→.50, node A records, `awx`/`openvas`→.203, `dns`→.203),
  enabled+active; coexists with systemd-resolved (binds 127.0.0.1 + .203 only,
  NOT 127.0.0.53) via **bind-dynamic**. `.202` dnsmasq stopped+disabled (VM now
  has no role — can be powered off). gdragon resolver → **.203** primary + .254
  fallback. gdragon `/etc/hosts` awx/openvas→.203 entries KEPT as a harmless
  local fallback. Durable in IaC: `dns_biplextech.yml` (OS-portable: apt/ufw +
  conf-dir enable for Ubuntu, dnf/firewalld for Rocky), `[dns]`→`gdragon-edge`
  in `inventory/hosts.ini`, `dns_server: 192.168.1.203` in `group_vars`,
  startup-script DNS note. Verify: `dig @192.168.1.203 awx.biplextech.com`→.203.

## Resume here — next steps (in order)
0. **After boot: FIRST `chronyc makestep` on all nodes** (or run
   `scripts/platform-startup.sh`) — else etcd/apiserver crashloop (clock skew).
   Verify 6/6 Ready + apiserver restarts not climbing before anything else.
1. **Finish Vault HA:** unseal vault-1/2 (3 keys each) → all 3 unsealed; confirm
   `retry_join` is in the live `vault-config` ConfigMap (ArgoCD synced) for
   reboot-safe auto-rejoin. Then init KV/auth as needed for VSO (wave 4).
2. ✅ **DONE — DNS:** `.202` dnsmasq back up + awx/openvas records + gdragon
   resolver pointed at .202. Remaining: add **per-platform-app** Ingress hostnames
   under biplextech.com → .50 records (argocd, grafana, vault, …) once those apps
   are exposed; the zone has no wildcard so each needs an explicit record.
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
  clock immediately; `chronyc tracking` showed "703 s slow"). **Durable fix DONE
  (2026-06-24):** VMware-Tools PERIODIC sync was re-skewing the VMs ~370 s minutes
  after each makestep → disabled it on all VMs (`vmware-toolbox-cmd timesync
  disable`, persists in tools.conf) so chrony/NTP is the SOLE time source; baked
  into `ansible/playbooks/base.yml`. Still `makestep` at boot (start.sh) to clear
  any boot-time sync. ESXi host NTP itself still drifts but no longer affects VMs.
- **★ kubelet `protectKernelDefaults` sysctls NOT persisted = #2 cold-boot
  killer (found 2026-06-24).** `k8s_harden.yml` sets `protectKernelDefaults:
  true`, which makes kubelet **assert** host sysctls and **refuse to start** if
  they differ (it does NOT set them). They were only set at runtime and never
  persisted, so every REBOOT reverted them to kernel defaults and kubelet
  crashlooped: `Failed to start ContainerManager ... invalid kernel flag:
  vm/overcommit_memory expected 1 actual 0, kernel/panic expected 10 actual 0`
  → no static pods → no apiserver → whole cluster down (looked like clock skew,
  was NOT). **Fix (durable, done):** persist them in `/etc/sysctl.d/99-kubelet.conf`
  (`vm.overcommit_memory=1`, `kernel.panic=10`, `kernel.panic_on_oops=1`) — added
  to `k8s_harden.yml` Play 3.9 (coupled with protectKernelDefaults) AND re-asserted
  by `platform-startup.sh` step 5c as a safety net. Check on a stuck boot:
  `journalctl -u kubelet | grep ContainerManager`; kubelet shows `activating`.
- **After an ungraceful/cold reboot, ~dozens of pods stick in `Unknown`** (their
  node went down hard; controllers can't replace them until the dead pod object
  is gone). Recover: force-delete them so Deployments/DaemonSets/StatefulSets
  recreate fresh —
  `kubectl get po -A | awk '$4=="Unknown"{print $1,$2}' | while read ns p; do kubectl delete po -n $ns $p --force --grace-period=0; done`.
  StatefulSets (vault/consul/etcd) re-attach the same PVC; Vault comes back sealed.
- **Post-reboot: pod→ClusterIP (10.96.0.1) can break on SOME nodes** (saw
  kworker2/kworker3): pods there hang on API-service access (ArgoCD controller
  CrashLoop/NotReady; `kubectl exec` into pods on those nodes hangs). Host-level
  firewalld/calico-fwd looked fine; fix = restart `kube-proxy` + `calico-node`
  on the affected node (`kubectl delete pod -l k8s-app=kube-proxy --field-selector
  spec.nodeName=<n>`). Diagnose: exec a pod on a GOOD node vs BAD node:
  `wget -qO- https://10.96.0.1:443/healthz --no-check-certificate`.
- **Don't over-restart ArgoCD on this small cluster.** Restarting
  controller+repo-server+redis to clear a manifest cache spiked load and helped
  push masters to NotReady. To pick up a new git commit, prefer a hard refresh
  (`kubectl annotate app … argocd.argoproj.io/refresh=hard`) and patience; only
  restart repo-server if a stale manifest truly persists.
- **TWO vault init files on gdragon — use the RIGHT one.** `~/.vault/init.json`
  is the OLD/retired k3s-era vault (stale token `hvs.ZN2…`, INVALID on the current
  cluster). The CURRENT ESXi-cluster vault token is in
  **`~/.vault/biplextech-init.json`** (`hvs.6uRV…`). Docs that said `init.json`
  caused "unable to get vault token" — fixed the active-platform docs/playbook to
  `biplextech-init.json` (2026-06-25). (`~/.vault/transit-init.json` = the gdragon
  auto-unseal transit vault.)
- **Vault UI 503 after OpenBao image pin:** the chart's `vault-active` Service
  selects `vault-active=true`, but OpenBao labels the leader `openbao-active=true`
  -> 0 endpoints -> 503. Fix: `server.ingress.activeService: false` (ingress -> the
  `vault` Service, all pods; standbys forward to the leader over 8201). 2026-06-25.
- **Platform UIs are HOST-based now** (path routing 404'd): `vault.biplextech.com`,
  `consul.biplextech.com`, `longhorn.biplextech.com`, `grafana`/`prometheus` too.
  A browsing CLIENT must resolve `*.biplextech.com -> .50` (point DNS at .203 OR
  add /etc/hosts) AND trust `~/biplextech-ca.crt`. Verified all 200 from .203.
- **Vault = REAL HashiCorp Vault `hashicorp/vault:2.0.3`** (product "Vault", UI
  built-in). User wanted actual HashiCorp Vault, not OpenBao. NB: Vault 2.x is a
  real release line (post-2026). OpenBao 2.0.x/2.1.x images had NO UI; switched to
  hashicorp/vault:2.0.3. HA (3 voters, transit auto-unseal) + UI both verified 200.
- **Longhorn UI white screen on host-based ingress:** a leftover
  `nginx.ingress.kubernetes.io/rewrite-target: /$2` (from the old /longhorn path)
  mangled the UI's RELATIVE asset URLs -> 404 -> blank. Removed it (pathType
  Prefix, no rewrite). Assets 200 now.
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
- **AWX browser (session) login → 403 CSRF behind the reverse proxy** while the
  API token (`POST /api/v2/tokens/`, basic auth) returns 201. awx-web log:
  `Forbidden (Origin checking failed - https://awx.biplextech.com does not match
  any trusted origins)`. Fix = trust the public origin. **Two gotchas:**
  (1) Setting `CSRF_TRUSTED_ORIGINS` via the runtime settings API
  (`PATCH /api/v2/settings/system/`) is NOT enough — Django's `CsrfViewMiddleware`
  caches the allowed origins as a per-worker `cached_property` at startup, so the
  live workers keep the old (empty) list until **restarted**. (2) Durable fix is
  the **AWX CR `extra_settings`** (`gdragon/awx/awx.yaml`): renders
  `CSRF_TRUSTED_ORIGINS = ['https://awx.biplextech.com']` into the Django settings
  configmap at boot — survives pod restart AND fresh rebuild. Verify login:
  GET `/api/login/` → take csrftoken cookie → POST with `Origin` + `X-CSRFToken`;
  success = **302 + sessionid cookie**.
- **Re-applying `gdragon/openvas/openvas.yaml` reset the admin Secret to the
  placeholder.** After any manifest apply, re-patch the live OpenVAS password.
  Also: the `openvas-admin` Secret (envFrom, keys **USERNAME/PASSWORD**) only sets
  the gvmd admin password on **first DB init** — after that the live gvmd password
  is independent. To (re)set it authoritatively: `gvmd --user=admin
  --new-password='…'` **run as the `gvm` user** (`su -s /bin/bash gvm -c …`); as
  root it fails `semaphore_op: Permission denied`. The user is `gvm`, NOT `gvmd`.
- **Verifying OpenVAS creds via curl is misleading:** raw `POST /gmp cmd=login`
  returns 401 `<gsad_response>Token missing or bad` even with correct creds —
  GSA's React SPA does a CSRF-token login flow curl doesn't replicate. Verify
  creds the real way: `gvm-cli --gmp-username admin --gmp-password '…' socket
  --socketpath /run/gvmd/gvmd.sock --xml '<get_version/>'` → `status="200"`.
- **kubectl secret with a dotted key:** `jsonpath='{.data.tls\.crt}'` escaping
  breaks through SSH — use `-o go-template='{{index .data "tls.crt"}}'`.
- **`/etc/hosts` is `IP hostname`** (IP first). User had it reversed → no resolve.
- **DNS now lives on the always-on `.203` edge box, not the ESXi `.202` VM** (see
  Current state). dnsmasq cold-boot gotchas seen along the way:
  - **`failed to create listening socket ...: Cannot assign requested address`** —
    dnsmasq started before the NIC had its IP. Fix = `bind-dynamic` (not
    `bind-interfaces`); on Rocky also comment `bind-interfaces` out of the default
    `/etc/dnsmasq.conf` (else `cannot set --bind-interfaces and --bind-dynamic`).
  - **Ubuntu ships only `dnsmasq-base`** (no service/conf-dir). Need the full
    `dnsmasq` pkg, AND `/etc/dnsmasq.conf` has every `conf-dir=` line commented →
    `/etc/dnsmasq.d/*.conf` is ignored until you uncomment
    `conf-dir=/etc/dnsmasq.d/,*.conf`.
  - **systemd-resolved coexistence:** resolved owns `127.0.0.53:53` (loopback
    only), so dnsmasq must `listen-address=127.0.0.1,<LANIP>` (never .53) — the
    LAN IP:53 is free. Leave resolved running (the box uses it for its own
    lookups). Don't try to bind `0.0.0.0:53`.
  All handled in `dns_biplextech.yml`. Manual restart if needed:
  `ssh bstha@192.168.1.203 sudo systemctl restart dnsmasq`.
- **The `biplextech.com` zone has NO wildcard** (`local=/biplextech.com/` →
  unlisted names NXDOMAIN, not forwarded). Every app hostname needs an explicit
  record in `dns_biplextech.yml` (awx/openvas → .203 added; platform apps → .50
  TODO when exposed).

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
