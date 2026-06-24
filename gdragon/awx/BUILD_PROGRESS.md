# AWX-driven Platform Build — Progress / Resume Anchor

> Live progress log for the AWX-orchestrated build of the ESXi `homelab`
> platform. Updated after each step so the work can resume after any
> interruption/shutdown. Companion to repo-root `arch.md`. **No secrets here.**

**Last updated:** 2026-06-23

## Decisions (locked with user)
- **Orchestrate in place** — power on + configure the EXISTING VMs; NO wipe/re-clone.
- **AWX is the orchestrator**, then ArgoCD takes over platform apps (waves 0–9).
- **Org = `biplextech`**. Repo is **public** → ArgoCD/AWX need no SCM credential.
- Creds set live, never committed ([[never-commit-creds]]). AWX admin pw = the
  one set on the gdragon AWX (`awx-admin-password` secret / set live).

## Environment facts
- gdragon (192.168.1.181): k3s single-node, runs AWX (`awx` ns, NodePort 30080)
  + OpenVAS. `k3s` binary = `/usr/local/bin/k3s` (sudo secure_path excludes
  /usr/local/bin → use full path). firewalld trusted zone already has k3s
  pod+svc CIDR (10.42.0.0/16, 10.43.0.0/16).
- ESXi host 192.168.1.174: **UP** (ping/22/443 OK).
- **All 9 cluster VMs were POWERED OFF** at build start (.186/.189/.187/.182/
  .183/.184/.188/.185/.202 all down) → power-on is step 0.

## AWX objects created (ids)
| Object | Name | id |
|---|---|---|
| Organization | biplextech | 2 |
| Credential (Machine) | biplextech-ansible-ssh (ansible user + key, sudo) | 3 |
| Credential (Vault) | biplextech-ansible-vault | 4 |
| Project | biplextech-platform (git, main, update-on-launch) | 8 |
| Inventory | biplextech-homelab | 2 |
| Inv groups | k8s_masters=1 k8s_workers=2 loadbalancers=3 vault=4 dns=5 cluster=6 everyone=7 | |
| Job template | biplextech \| 1. LoadBalancer | 9 |
| Job template | biplextech \| 2. Longhorn node prereqs | 10 |
| Job template | biplextech \| 3. K8s hardening (CIS) | 11 |
| Job template | biplextech \| 4. K8s audit (kube-bench) | 12 |
| Job template | biplextech \| 5. ArgoCD bootstrap (GitOps) | 13 |
| Workflow | biplextech \| Build & Configure Platform | 14 |

Workflow chain: JT9 → JT10 → JT11 → JT12 → JT13 (on success).

## Playbook fixes committed (69dd41d)
- `k8s_audit.yml`: kube-bench tag v0.11.4 → **v0.15.6**.
- `argocd_bootstrap_awx.yml`: NEW — runs on kmaster1 via admin.conf + installs
  helm there (AWX EE has no helm/kubectl). Applies app-of-apps.

## TODO / next steps
- [x] AWX EE pod → LAN egress works (pod→.174:443 OK). Earlier UNREACHABLE was
      only because VMs were off — NOT a firewall issue. firewalld already trusts
      pod/svc CIDR.
- [x] root@ESXi SSH key = **/apps/git-code/keys/ansible-key** (already AWX cred 3)
      — so power-on JT reuses cred 3; no separate ESXi credential needed.
- [x] ESXi **maintenance mode exited** (was true — the silent killer).
- [x] **Power-on JT added** = JT id **15** (`all_powerup.yml`), prepended as
      workflow node 6 → LB(node1). Workflow now: 15→9→10→11→12→13.
- [ ] Launch workflow 14; stream + verify each stage.
- [ ] Wave 0–9 ArgoCD reconcile (Longhorn first; needs longhorn_prereqs done).

Workflow run ids (update as launched): see below.

## How to resume
1. `sudo /usr/local/bin/k3s kubectl -n awx get pods` (AWX up?).
2. AWX UI http://192.168.1.181:30080 (admin). Check workflow 14 / last jobs.
3. Re-run AWX setup script if objects missing:
   `/tmp/.../scratchpad/awx_setup.sh` (idempotent get-or-create) — or rebuild
   from the ids table above.
4. Continue from the first unchecked TODO.

- Workflow run **3** launched 2026-06-23 (node order 15→9→10→11→12→13).
- Workflow run **6** relaunched 2026-06-23 after fixing JT15 become_enabled=false (EE has no sudo for localhost plays).
- Workflow run **11** relaunched after LB vars fix (inventory vars + vault.yml vars_files).
- Workflow run **22** relaunched after audit PSA fix + workflow rewire (argocd no longer gated by audit).

## ✅ Build complete — workflow run 22 SUCCESSFUL (2026-06-23 20:14)
All stages green: power-on(JT15) → LoadBalancer(JT9) → Longhorn prereqs(JT10)
→ K8s hardening CIS(JT11) → K8s audit kube-bench(JT12) → ArgoCD bootstrap(JT13).
ArgoCD installed + root app-of-apps applied → waves 0–9 reconciling async.

## NEW DIRECTIVE (2026-06-23): NO NodePort — all URLs via the load balancer
- gdragon AWX/OpenVAS: switch NodePort → k3s Traefik Ingress (klipper hostPort).
- ESXi platform: ingress-nginx currently NodePort 32080/32443 → change to
  no-NodePort path (hostNetwork ingress vs MetalLB — pending user clarification).
- Reverses arch.md locked "No MetalLB / LB→NodePort" decision. Update gitops
  values/ingress-nginx.yaml + edge_gateway.yml + per-app Ingress hosts.

## No-NodePort exposure (2026-06-23, evening)
- DECISION: Cloudflare -> HAProxy(VIP .50) -> MetalLB IP .51 -> ingress-nginx -> app.
  Reverses old "no MetalLB". gdragon AWX/OpenVAS handled SEPARATELY (not ESXi LB).
- ESXi platform (committed 36837a4): MetalLB app (wave -2) + pool .51-.60 (wave -1)
  + ingress-nginx Service -> LoadBalancer pinned .51; HAProxy -> .51 (ingress_lb_ip).
  GOTCHA: AWX bootstrap re-run did NOT update the live AppProject; metallb app hit
  "repo not permitted". FIX: applied gitops/bootstrap/project.yaml directly. Now
  permitted; ArgoCD syncing metallb -> pool -> ingress LB IP.
  TODO: once ingress-nginx EXTERNAL-IP=.51, re-run loadbalancer JT9 (HAProxy->.51).
- gdragon tools (committed 9c57087): AWX+OpenVAS off NodePort -> ClusterIP+Traefik
  Ingress on .181; system nginx on .203 reverse-proxies awx/openvas.biplextech.com
  -> .181 Traefik. Verified 200 end-to-end through .203. NO NodePort on gdragon.
  OpenVAS secret repatched to live pw after manifest apply reset it to placeholder.

## 2026-06-23 late — deadlock hardening + AWX endpoint change
- AWX endpoint CHANGED: NodePort :30080 removed (AWX now ClusterIP+Traefik).
  Drive AWX via: curl -H 'Host: awx.biplextech.com' http://192.168.1.181/api/...
- Cold-boot deadlock fixes (committed): consul connectInject failurePolicy=Ignore
  (was wedging ALL pod creation), ingress-nginx admission failurePolicy=Ignore,
  longhorn preUpgradeChecker.jobEnabled=false, PSA privileged on metallb-system
  + longhorn-system. Doc: docs/cold-boot-resilience.md. ArgoCD has no PVC.
- RECOVERY: deleted live consul webhook -> pods unjammed -> MetalLB Running ->
  ingress-nginx got MetalLB IP 192.168.1.51 ✅. LB JT9 relaunched (job 36) to
  point HAProxy -> .51. Longhorn still settling (pre-upgrade hook fix).

## 2026-06-23 — HTTPS across apps with custom biplextech.com cert
- cert-manager PKI verified: selfsigned root -> biplextech-ca ClusterIssuer ->
  wildcard *.biplextech.com (secret biplextech-tls, Ready).
- ingress-nginx: default-ssl-certificate=ingress-nginx/biplextech-tls + force
  HTTPS. VERIFIED: VIP .50:443 serves CN=biplextech.com (issuer "biplextech.com
  internal CA"), CA-verified, 404 (no app ingress yet = chain OK).
- AWX/OpenVAS: .203 nginx terminates HTTPS with the wildcard cert (200, 80->443
  redirect). cert+key deployed out-of-band to /etc/nginx/ssl (NOT in git).
- CA trust distributed (tls_distribute_ca.yml) to all 9 VMs + gdragon + .203.
  CA cert exported for browser: /home/bstha/biplextech-ca.crt.
- Edge chain confirmed up: VIP .50 -> HAProxy -> MetalLB .51 -> ingress-nginx.
- STILL PENDING (not TLS): Longhorn StorageClass (stateful apps Pending);
  per-app Ingress hosts + *.biplextech.com DNS (.202 dnsmasq was down).

## 2026-06-23 — Longhorn storage FIXED
- Root cause: ArgoCD<->Longhorn pre-upgrade hook deadlock. The pre-upgrade Job
  is a PreSync hook needing longhorn-service-account, which only the MAIN sync
  creates (after PreSync) -> 0 pods, Job never completes, ArgoCD stuck forever
  "waiting for completion of hook longhorn-pre-upgrade".
- Fix: preUpgradeChecker.jobEnabled=false (the chart's OWN documented ArgoCD
  fix; verified renders 0 hooks). ArgoCD was frozen in the old op, so: removed
  app finalizer, deleted the longhorn Application + force-deleted stuck job,
  re-applied fresh -> clean install.
- RESULT: longhorn Synced/Healthy, 21 pods Running, **StorageClass `longhorn`
  (default)** + longhorn-static. All stateful PVCs now BOUND: vault (data+audit),
  consul (3 servers), monitoring (prometheus 15Gi, grafana 5Gi, alertmanager).
- Downstream now progressing: vault (Progressing, will be SEALED -> unseal),
  consul/kube-prometheus settling as pods start on bound PVCs.

## 2026-06-24 END OF SESSION (powered off for the day)
- ★ ROOT CAUSE of flakiness = CLOCK SKEW. ESXi host clock drift -> VMware-Tools
  synced VMs to wrong time -> kmaster1 703s slow -> etcd deadline exceeded ->
  all 3 apiservers CrashLoopBackOff -> cluster-wide intermittent Forbidden.
  FIXED: chronyc makestep on all nodes; control plane stable (6/6 Ready).
  platform-startup.sh updated to makestep BEFORE waiting on k8s. Durable fix TODO:
  disable VMware-Tools time sync + fix ESXi NTP (recurs every boot).
- Vault: vault-0 unsealed leader; vault-1/2 raft-joined (3 peers) but SEALED
  (redo unseal next time). retry_join in git, not yet in live ConfigMap.
- RESUME: arch.md §0 -> HandOff.md -> this file. After boot, makestep FIRST.
