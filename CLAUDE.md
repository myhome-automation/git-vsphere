# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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
- **`gdragon-ubuntu`** (192.168.1.203, Ubuntu 24.04) — edge / reverse proxy host. Runs **2 podman-rootless nginx containers** from `quay.io/bpraisa/nginx:homelab-proxy-1.0` (the custom image we build from `nginx-proxy/Dockerfile`); HA via two host-port bindings (`:80` and `:8080`) + `--restart=always`. Path-based routing to k3s/homelab services (`/grafana/`, `/prometheus/`, `/loki/`, `/vault/`, `/argocd/`). See `nginx-proxy/README.md`.
- **ESXi 6.7** (192.168.1.174) — the original hypervisor; runs the 9 homelab VMs.

Cross-machine deploy: `bash nginx-proxy/install.sh 192.168.1.203` (re-pulls + restarts the HA pair); `bash nginx-proxy/build-and-push.sh quay.io/bpraisa/nginx:homelab-proxy-1.0` (rebuild + push image — needs persistent `podman login quay.io` first; `/run/user/$UID/containers/auth.json` is *transient*, prefer `--authfile ~/.config/containers/auth.json`).

## Vault on local k3s (production-shape HA, ArgoCD-managed)

3-replica Vault StatefulSet, integrated Raft storage, helm chart `hashicorp/vault 0.31.0` (image `1.20.4`). Deployed via ArgoCD Application at `argocd/vault.yaml`; values mirror at `vault/values.yaml`. UI: `http://192.168.1.181:30200/ui/`. Unseal keys + root token kept at `~/.vault/init.json` on gdragon (chmod 600) — should be moved to a password manager and removed from disk.

Current state: `vault-0` is leader (init'd, unsealed, KV-v2 at `secret/`, AppRole auth enabled). `vault-1`/`vault-2` pods up but **not yet raft-joined** — blocked by Calico IPPool overlap on k3s (`192.168.0.0/16` IPPool ∩ home network `192.168.1.0/24`), which prevents pod-to-pod from `vault-1` → `vault-0`. A workstation-level `systemd` unit (`k3s-pod-masq.service`) masquerades pod → external traffic but doesn't fix pod-to-pod within the affected pool. Proper fix: migrate IPPool to a non-overlapping CIDR (destructive — rebuilds all pods). See `vault/README.md`.

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

Full failure-mode catalogs are in `packer/TROUBLESHOOTING.md` and `docs/esxi-host.md`.

## Workflow defaults

- **Don't edit Packer files** (`packer/*.pkr.hcl`, `packer/http/`, `packer/build.sh`) for new work — that approach is abandoned. Bug fixes to the kickstart are a waste of time. Same for `terraform/main.tf`/`providers.tf` (josenk/esxi provider not used).
- New base-image tweaks go onto **vault-server itself** (it's the live template) and propagate to clones on the next `clone-from-vault.sh` run.
- Per-host configuration goes into the relevant `ansible/playbooks/*.yml` and runs via `site.yml` or `--tags`.
- Playbooks are written to be idempotent; re-running `site.yml` should be safe.
