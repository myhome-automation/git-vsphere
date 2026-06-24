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
- [ ] **STEP 0 (power-on) is MISSING from the workflow.** VMs are off; the
      ansible playbooks need them up. Power playbooks (`cluster_powerup.yml`,
      `all_powerup.yml`) run on localhost and `ssh root@192.168.1.174` (vim-cmd)
      using a key root@ESXi trusts. AWX EE needs that ESXi SSH key as a
      credential, OR power on from gdragon directly first. Need .202 up too
      (it's the DNS server). → add an ESXi power-on JT as node 0 of workflow.
- [ ] Verify AWX EE pod → LAN egress works once a VM is up (test pod→.174).
- [ ] Launch workflow 14; stream + verify each stage.
- [ ] Wave 0–9 ArgoCD reconcile (Longhorn first; needs longhorn_prereqs done).

## How to resume
1. `sudo /usr/local/bin/k3s kubectl -n awx get pods` (AWX up?).
2. AWX UI http://192.168.1.181:30080 (admin). Check workflow 14 / last jobs.
3. Re-run AWX setup script if objects missing:
   `/tmp/.../scratchpad/awx_setup.sh` (idempotent get-or-create) — or rebuild
   from the ids table above.
4. Continue from the first unchecked TODO.
