# AGENTS.md

This file provides orientation for anyone (human or AI agent) working with code in this repository.

## Resume here — current state (last verified 2026-05-18)

A new session should start by reading this section, then `docs/infra-implementation-notes.md`
(the single-file build-from-scratch runbook). Everything below is the result of recent work;
treat dates and tag/SHA references as accurate at the time stamped.

### Verified working (smoke-tested end-to-end)
- **Homelab k8s cluster**: all 6 nodes Ready (3 masters + 3 workers, v1.36.1). Calico v3.30.4 healthy, APIService `v3.projectcalico.org` True. k8s API via VIP `192.168.1.50:6443` responding.
- **HA LB pair** (lb1 MASTER prio 101, lb2 BACKUP prio 100): keepalived VIP `192.168.1.50` plus dnsmasq for `myhomelab.com`. Failover ~3 s.
- **Local k3s on gdragon** (192.168.1.181): monitoring stack + ArgoCD + Vault all up. cross-cluster `remote_write` from homelab Prometheus into local Prometheus :30320, Promtail DaemonSets on both clusters pushing to local Loki :30310.
- **Vault**: `vault-0` is the Raft leader (initialized, unsealed). `vault-2` raft-joined. **`vault-1` is CrashLoopBackOff** (Calico IPPool overlap blocks its pod IP — known limitation, not a regression).
- **Edge nginx proxy on .203** at `quay.io/bpraisa/nginx:homelab-proxy-1.4`. All six paths return 2xx through `http://192.168.1.203/`:
  - `/` (landing), `/grafana/`, `/prometheus/`, `/loki/ready`, `/argocd/`, `/ui/` (Vault — root-mounted because the SPA has no sub-path mode).

### Open items
- **Vault-1 raft-join** — blocked by Calico IPPool `192.168.0.0/16` overlapping with home LAN `192.168.1.0/24` on the local k3s. Workaround `k3s-pod-masq.service` (systemd) is already running. Proper fix is a destructive IPPool migration; see `vault/README.md`.
- **Istio ingressgateway externally exposed** — `LoadBalancer` Service pending; no MetalLB on the homelab cluster yet.
- **ESXi NTP / clock drift** — host clock drifts; VMs absorb it on boot. `all_powerup.yml` runs `chronyc makestep` to recover; the host itself still needs proper NTP setup.
- **etcd snapshot strategy** — none yet.
- **Persistent storage class on homelab cluster** — no PV provisioner yet (local-path or NFS).
- **`~/.vault/init.json` on disk** — should move to a password manager. Currently chmod 600 on gdragon.
- **Rename ESXi VM directory** — lb2's display name is `lb2` but the on-disk path is still `datastore1/dns1/` (cosmetic).

### Recent significant changes (commit refs on `main`)
- `b7a13f7` — move `infra-implementation-notes.md` into `docs/`, fix self-reference.
- `b3cc76c` — add the 25-phase build-from-scratch runbook.
- `b881b50` — new `full_shutdown.yml` / `full_powerup.yml` orchestrators across all three physical hosts; ESXi maintenance-mode pre-check added to powerup playbooks; new `edge_*.yml` + `vault_unseal.yml` building blocks.
- `542b4d9` — rename `CLAUDE.md` → `AGENTS.md`; scrub agent-tool naming throughout history. Full author rewrite to `bstha <bidur.devsecops@gmail.com>` (no other contributors).
- Earlier in the same session: Vault liveness probe `sealedcode=204` fix, edge-proxy nginx 1.0 → 1.4 progression with sub-path mode end-to-end, `quay.io/bpraisa/{nginx,vault}` registry repos established.

### First commands a new session should run (sanity check)
```bash
cd /apps/git-code/git-vsphere

# Cluster reachable?
kubectl --context homelab get nodes
kubectl --context k3os-local get pods -A | grep -v Running | grep -v Completed

# Proxy URLs answering?
for p in / /grafana/ /prometheus/ /loki/ready /ui/ /argocd/; do
  printf "%-22s %s\n" "$p" "$(curl -sSL -o /dev/null -w '%{http_code}' http://192.168.1.203$p)"
done

# Vault leader still unsealed?
kubectl --context k3os-local -n vault exec vault-0 -- vault status | grep -E "Sealed|HA Mode"
```

If anything fails: `docs/operations.md` has the recovery playbooks (incl. ESXi maintenance-mode and Vault unseal). For a totally cold rebuild: `docs/infra-implementation-notes.md`.

---

## What this repo is

Infrastructure-as-code for a 9-VM home-lab Kubernetes cluster running on a single ESXi 6.7 host (`192.168.1.174`, 60 GB RAM). The end state: 3 k8s masters + 3 workers + an HA load-balancer pair (lb1 MASTER + lb2 BACKUP, both running HAProxy + keepalived + dnsmasq) + a `vault-server` source VM, all Rocky 9.7. Full layout, network topology, and CIDRs live in `docs/architecture.md`.

## Build pipeline (current — read before changing anything)

The repo went through two abandoned approaches before landing on the current one. **Both abandoned approaches still have code in the tree.** Don't extend them.

```
vault-server (Rocky 9.7, hand-built, kept LIVE as clone source)
        │  bootstrap: ansible user + key + ipv6 off + GUI strip already baked in
        ▼
terraform/clone-from-vault.sh    ← THIS IS THE BUILD STEP. Bash + ESXi vim-cmd + vmkfstools.
   - ssh to ESXi, run a POSIX sh script that:
   - power off vault-server, vmkfstools -i thin × 9 in parallel,
   - emit per-VM VMX with new UUID/MAC, vim-cmd solo/registervm, power back on
        │
        ▼
ansible/playbooks/bootstrap-users.yml   (bstha user + key on all 9 hosts)
        │
        ▼
ansible/playbooks/site.yml = base → dns → loadbalancer → k8s_master → k8s_worker → cni_calico → istio
```

Abandoned (kept only for `packer/TROUBLESHOOTING.md` context):
- `packer/` — Packer Rocky 9 template (anaconda kept landing in TUI; ~12 iterations failed).
- `terraform/main.tf` + `providers.tf` — josenk/esxi provider with ovftool. `ovftool` consistently hit `vim.fault.TaskInProgress` on vault-server. `terraform apply` is **not** run; only `clone-from-vault.sh` is.

## Common commands

All ansible commands must be run from the `ansible/` directory — the vault password path in `ansible.cfg` is relative to that file (see `docs/ansible.md` A2).

`kubectl` on the workstation has two contexts (`~/.kube/config` merged):
- **`homelab`** — this repo's vsphere cluster (server `https://192.168.1.50:6443`).
- **`k3os-local`** — the workstation's local k3s cluster on `gdragon` (192.168.1.181). Hosts the cross-cluster monitoring stack (Grafana / Prometheus / Loki) — see `monitoring/README.md`. Don't delete the namespaces `argocd`, `monitoring`, `calico-system`, `calico-apiserver`, `tigera-operator`, or `kube-system` on this cluster.

Switch with `kubectl config use-context <name>` or use `--context <name>` per command. Refresh / re-fetch the homelab kubeconfig with `scripts/fetch-kubeconfig.sh homelab 192.168.1.186` (the script is generic: `fetch-kubeconfig.sh <ctx> <host> [user] [key] [path]`).

Cross-cluster monitoring: Grafana at `http://192.168.1.181:30300` (admin / `changeme-home-lab`). homelab Prometheus remote_writes to local Prometheus (`:30320`); Promtail DaemonSets on both clusters push to local Loki (`:30310`). Both data sources are tagged with `cluster=homelab` or `cluster=k3os-local`. Full architecture, install commands, and gotchas in `monitoring/README.md`.

## Three physical machines (not just one ESXi host)

Beyond the ESXi host, the home lab has expanded to two more boxes:

- **`gdragon`** (workstation, 192.168.1.181, Rocky 9) — runs `k3s` (single-node), the cross-cluster monitoring stack, **HashiCorp Vault** (3-replica HA shape, `vault-0` is currently the active leader), ArgoCD, and is where ansible runs from. Local `/var` was grown to 128 GiB after a hot-added 100 GiB disk to fit the Vault + monitoring PVCs.
- **`gdragon-ubuntu`** (192.168.1.203, Ubuntu 24.04) — edge / reverse proxy host. Runs **2 podman-rootless nginx containers** from `quay.io/bpraisa/nginx:homelab-proxy-1.4` (the custom image we build from `nginx-proxy/Dockerfile`); HA via two host-port bindings (`:80` and `:8080`) + `--restart=always`. Path-based routing to k3s/homelab services (`/grafana/`, `/prometheus/`, `/loki/`, `/vault/`, `/argocd/`). See `nginx-proxy/README.md`.
- **ESXi 6.7** (192.168.1.174) — the original hypervisor; runs the 9 homelab VMs.

Cross-machine deploy: `bash nginx-proxy/install.sh 192.168.1.203` (re-pulls + restarts the HA pair); `bash nginx-proxy/build-and-push.sh quay.io/bpraisa/nginx:homelab-proxy-1.4` (rebuild + push image — uses the robot creds in ansible-vault; bootstrap the login with `ansible-playbook ... playbooks/quay-login.yml`).

## Image registry — `quay.io/bpraisa/`

Two repos in active use:

- **`quay.io/bpraisa/nginx`** — custom edge reverse proxy image (path-based routing). Current production tag: `homelab-proxy-1.4`. Built from `nginx-proxy/{Dockerfile,nginx.conf}`. Build/push procedure in `docs/operations.md` "Edge nginx-proxy on .203 — rebuild + redeploy".
- **`quay.io/bpraisa/vault`** — mirror of `hashicorp/vault:1.20.4` + `:latest`, pushed for future helm-chart cutover. The chart currently still pulls from dockerhub.

Auth: ansible-vault encrypted robot creds in `ansible/group_vars/all/vault.yml` (`vault_quay_username`, `vault_quay_password`). Bootstrap the persistent `auth.json` on the edge host with `ansible-playbook playbooks/quay-login.yml`. **Per-repo permission gotcha**: a new quay repo doesn't grant the existing robot anything by default; symptom is `unauthorized: access to the requested resource is not authorized` on push. Fix at `https://quay.io/repository/bpraisa/<repo>/?tab=settings`.

## Two load-balancer layers (different jobs)

1. **Homelab API LB pair** — `lb1` MASTER + `lb2` BACKUP on the ESXi side. keepalived VIP `192.168.1.50` fronting HAProxy. Used by the k8s control plane (kubeadm `--control-plane-endpoint=192.168.1.50:6443`), HTTP/HTTPS NodePort backends (kworker*:30080/30443), and the homelab DNS zone `myhomelab.com` via dnsmasq HA. Configured in `ansible/playbooks/loadbalancer.yml` + `dns.yml`. Failover ~3 s.
2. **Edge user-facing nginx proxy** — `gdragon-ubuntu` 192.168.1.203 with 2 podman containers; path-based routing to the k3s NodePort services. NOT in the homelab k8s API path — it's a separate user-facing layer that fronts Grafana / Prometheus / Loki / Vault / ArgoCD.

## App catalog (where each thing lives)

| App | Cluster | NodePort | URL via nginx | Role |
|---|---|---|---|---|
| Grafana ("search head") | k3os-local | 30300 | `/grafana/` | UI; queries Prometheus + Loki |
| Prometheus | k3os-local | 30320 | `/prometheus/` | central TSDB; receives remote_write from homelab |
| Loki | k3os-local | 30310 | `/loki/` | log store; receives Promtail pushes from both clusters |
| Vault | k3os-local | 31326 (vault-active, leader-only) | `/vault/` ✅ (API) | secrets (KV-v2 + AppRole); 3-replica HA — vault-0 leader, vault-2 joined, vault-1 still CrashLoopBackOff (Calico IPPool blocks its pod IP). API works via proxy; SPA UI needs direct NodePort. |
| ArgoCD | k3os-local | 30401 (http) / 30400 (https) | `/argocd/` | GitOps; deploys Vault via `argocd/vault.yaml` |
| k8s API (homelab) | homelab | (VIP :6443) | n/a | control plane via HAProxy |
| DNS (homelab) | homelab | (VIP :53) | n/a | `myhomelab.com` |
| Promtail | both | DaemonSet | n/a | ships logs to local Loki, tagged `cluster=homelab` or `cluster=k3os-local` |
| Prometheus (homelab) | homelab | ClusterIP | n/a | scrapes local + remote_writes to gdragon:30320 |

**Sub-path mode status (verified 2026-05-18 with image `homelab-proxy-1.4`):** all paths below return 200 through the edge nginx at `http://192.168.1.203/`:
- `/` → landing page
- `/grafana/` → `/grafana/login` (helm: `grafana.ini server.root_url=/grafana/` + `serve_from_sub_path=true`)
- `/prometheus/` → `/prometheus/query` (helm: `externalUrl=http://192.168.1.203/prometheus` + `routePrefix=/prometheus`)
- `/loki/ready` (no UI; nginx strips `/loki/` since Loki's endpoints live at root)
- `/argocd/` (`argocd-cmd-params-cm` → `server.rootpath: /argocd`)
- `/ui/` (Vault SPA — Vault has no sub-path mode and its Ember app hard-codes `rootURL=/ui/`, so the UI is **root-mounted** at nginx and `/vault/` 302-redirects to `/ui/`. Assets at `/ui/assets/...` and API calls at `/v1/...` all forward to the `vault-active` upstream NodePort.)
- `/v1/sys/...` (Vault API at root, same upstream as `/ui/`)

This works because no other app in the lab uses `/ui/` or `/v1/` at the root; everything else is sub-path-mounted.

## Vault on local k3s (production-shape HA, ArgoCD-managed)

3-replica Vault StatefulSet, integrated Raft storage, helm chart `hashicorp/vault 0.31.0` (image `1.20.4`). Deployed via ArgoCD Application at `argocd/vault.yaml`; values mirror at `vault/values.yaml`. UI: `http://192.168.1.181:30200/ui/`. Unseal keys + root token kept at `~/.vault/init.json` on gdragon (chmod 600) — should be moved to a password manager and removed from disk.

Current state (2026-05-18, after fix): `vault-0` is Raft leader, unsealed, active. Liveness probe was the crash-loop trigger — default helm path `/v1/sys/health?standbyok=true` returns 503 when sealed and the kubelet killed the pod before it could be unsealed. Fixed in `argocd/vault.yaml` + `vault/values.yaml`: probe path now `?standbyok=true&sealedcode=204&uninitcode=204`. After applying, vault-0 stayed up, manual unseal with `~/.vault/init.json` keys completed cleanly. `vault-2` also recovered into the raft cluster. `vault-1` still CrashLoopBackOff (Calico IPPool overlap `192.168.0.0/16` ∩ home `192.168.1.0/24` blocks the raft-join path for this pod's allocated IP). The `vault-active` Service has only the leader (`NodePort 31326`); the generic `vault` Service (`30200`) load-balances across all pods including sealed ones — nginx upstream is therefore pointed at `:31326`. Unseal keys + root token at `~/.vault/init.json` on gdragon (chmod 600). See `vault/README.md`.

```bash
cd ansible/

# Full provision after cloning VMs
ansible-playbook -i inventory/hosts.ini --vault-password-file=.vault_pass playbooks/site.yml

# Tagged stages (re-runnable individually)
ansible-playbook ... playbooks/site.yml --tags base
ansible-playbook ... playbooks/site.yml --tags dns
ansible-playbook ... playbooks/site.yml --tags lb
ansible-playbook ... playbooks/site.yml --tags k8s,calico,istio
ansible-playbook ... playbooks/site.yml --skip-tags update   # skips slow `dnf update`

# Power: cluster_*.yml leaves vault-server alone; all_*.yml includes it
ansible-playbook ... playbooks/cluster_shutdown.yml
ansible-playbook ... playbooks/cluster_powerup.yml
ansible-playbook ... playbooks/all_shutdown.yml
ansible-playbook ... playbooks/all_powerup.yml

# Wipe the k8s cluster (keep VMs) — use when changing pod CIDR
ansible-playbook ... playbooks/k8s_reset.yml

# Add bstha SSH access to a fresh / re-cloned host
ansible-playbook ... playbooks/bootstrap-users.yml --limit <host>

# Re-clone all 9 VMs from vault-server (destructive: powers off vault briefly)
bash terraform/clone-from-vault.sh

# kubectl from the workstation (no kubeconfig fetched yet — go via kmaster1)
ssh -i /apps/git-code/keys/ansible-key ansible@192.168.1.186 \
  'sudo KUBECONFIG=/root/.kube/config kubectl get nodes'
```

For full reference docs: `docs/deployment.md` is the end-to-end "zero
to running cluster" runbook (with verification checklist);
`docs/operations.md` is the day-2 ops cheatsheet (shutdown/powerup, LB
failover test, planned VIP switchover, kubeconfig refresh, single-host
recovery, change pod CIDR).

## Inventory groups (used by `hosts:` in playbooks)

Playbooks use **exact** group names. Renaming inventory groups silently runs the play against 0 hosts (see `docs/ansible.md` A3).

| Group | Members | Used by |
|-------|---------|---------|
| `k8s_masters` | kmaster1/2/3 | `k8s_master.yml` |
| `k8s_workers` | kworker1/2/3 | `k8s_worker.yml` |
| `loadbalancers` | lb1 (MASTER 101), lb2 (BACKUP 100) | `loadbalancer.yml`, `dns.yml` |
| `vault` | vault-server | `bootstrap-users.yml` (via `everyone`) |
| `cluster` (children) | k8s_masters + k8s_workers + loadbalancers | most cluster plays — **excludes vault-server** |
| `everyone` (children) | cluster + vault | `bootstrap-users.yml`, NM resolver play in `dns.yml` |

Notes that aren't obvious from the inventory file:
- **HA LB pair.** lb1 (MASTER prio 101) and lb2 (BACKUP prio 100) share keepalived VIP `192.168.1.50`. Both run HAProxy + dnsmasq; only the VIP holder serves traffic. Inventory carries the per-host `keepalived_state` / `keepalived_priority` vars.
- **DNS is on the LB pair (not on a separate VM).** dnsmasq uses `bind-dynamic` so it answers on the VIP whenever this LB owns it. All cluster hosts resolve via `192.168.1.50`.
- **lb2 was originally the `dns1` VM** (re-purposed 2026-05-17 after the GUI strip freed memory). At the ESXi level the VM's display name is now `lb2` but the disk path is still `datastore1/dns1/`.

## Variables

- `ansible/group_vars/all/vars.yml` — non-secret defaults. Currently sets `pod_network_cidr: 10.0.0.0/16`, `vip: 192.168.1.50`, `k8s_version: "1.36"`.
- `ansible/group_vars/all/vault.yml` — ansible-vault encrypted (e.g. `keepalived_password`). `.vault_pass` is gitignored.
- **`ansible/inventory/group_vars`** is a symlink to `../group_vars` — required for ansible to auto-load vars (see `docs/ansible.md` A1). If it's missing on a fresh checkout, recreate with `ln -sfn ../group_vars ansible/inventory/group_vars`.

## Pod CIDR coupling (don't break this)

Three places must agree, or Tigera operator rejects the install:

1. `ansible/group_vars/all/vars.yml` → `pod_network_cidr`
2. `ansible/playbooks/cni_calico.yml` → `pod_cidr` var
3. `kubeadm init --pod-network-cidr=...` (driven by #1 in `k8s_master.yml`)

Changing the CIDR requires `k8s_reset.yml` then `site.yml --tags k8s,calico,istio` — it can't be changed in place (the value is baked into kube-controller-manager's `--cluster-cidr` flag at init time).

## Calico + firewalld gotcha (read before touching k8s firewall rules)

After a host reboot, firewalld on each k8s node blocks Calico's BGP (TCP/179) and pod-to-pod traffic — `calico-node` pods come up 0/1, BIRD reports "BGP not established", and `v3.projectcalico.org` APIService flips to `FailedDiscoveryCheck`. Knock-on: Istio sidecars can't reach `istiod.istio-system.svc`.

The fix is in `k8s_master.yml` / `k8s_worker.yml`: open 179/tcp, 5473/tcp, 4789/udp **and** add `source={{ pod_network_cidr }}` to firewalld zone `trusted` on every k8s node. If you ever shrink or restructure these plays, keep both pieces — the zone-trusted source for pod CIDR is what actually lets pod-to-pod packets through.

If after a fix the `tigerastatus/ippools` stays `Degraded`, that's a stale-status quirk in tigera-operator's cached discovery client — restart `deployment/tigera-operator` AFTER `v3.projectcalico.org` shows `AVAILABLE=True`. Details in `docs/calico.md`.

## ESXi 6.7 quirks that bite scripts

These show up any time a script touches the host at `192.168.1.174`:

- **No bash on ESXi.** Use `ssh root@esxi 'sh -s' <<'EOF' ... EOF` and POSIX-only constructs (no `declare`, no `<<<`, no `mapfile`). `terraform/clone-from-vault.sh` is the canonical example.
- **scp/sftp is buggy.** Use `cat file | ssh root@host "cat > /path"` instead.
- **`cmd | while ... & done; wait` doesn't wait** — the bg procs belong to the pipe's subshell. Use a `for x in $LIST; do ... & done` loop instead.
- **`00:0c:29:xx:xx:xx` is VMware's reserved OUI** and can't be set as a static MAC (vmkfstools script regenerates a fresh MAC anyway).
- **`/tmp` is a ramdisk** — don't write large logs there; it fills and blocks subsequent scp.
- **VMX edits need `vim-cmd vmsvc/reload <vmid>` before power.on** (hostd caches VMX in memory).
- **`vim-cmd vmsvc/power.on` silently fails ("Power on failed" + hostd.log "State Transition not allowed for this Vm") when the host is in maintenance mode.** Always check first: `ssh root@192.168.1.174 'vim-cmd hostsvc/runtimeinfo | grep -i maintenance'`. Exit with `vim-cmd hostsvc/maintenance_mode_exit`. ESXi sometimes boots into maintenance mode after a dirty shutdown — bit us 2026-05-18 (cluster_powerup looked successful but all VMs stayed off).

Full failure-mode catalogs are in `packer/TROUBLESHOOTING.md` and `docs/esxi-host.md`.

## Workflow defaults

- **Don't edit Packer files** (`packer/*.pkr.hcl`, `packer/http/`, `packer/build.sh`) for new work — that approach is abandoned. Bug fixes to the kickstart are a waste of time. Same for `terraform/main.tf`/`providers.tf` (josenk/esxi provider not used).
- New base-image tweaks go onto **vault-server itself** (it's the live template) and propagate to clones on the next `clone-from-vault.sh` run.
- Per-host configuration goes into the relevant `ansible/playbooks/*.yml` and runs via `site.yml` or `--tags`.
- Playbooks are written to be idempotent; re-running `site.yml` should be safe.
