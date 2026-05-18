# Infrastructure Implementation Notes

End-to-end "build the lab from scratch" runbook. Single file. Every
phase is procedural and copy-pasteable. If something here disagrees with
a per-component doc under `docs/`, **the per-component doc is the more
detailed reference and wins** — this file is the path through them.

> **Audience**: anyone with shell access to the three physical hosts and
> ansible + helm + kubectl + podman installed locally. Assumes basic
> familiarity with each tool; this is a procedure, not a tutorial.

---

## Table of contents

1. [Goal + outcome](#1-goal--outcome)
2. [Bill of materials (hardware)](#2-bill-of-materials-hardware)
3. [Network plan](#3-network-plan)
4. [Phase 1 — ESXi 6.7 host install](#phase-1--esxi-67-host-install)
5. [Phase 2 — vault-server template VM (Rocky 9.7)](#phase-2--vault-server-template-vm-rocky-97)
6. [Phase 3 — clone 8 cluster VMs](#phase-3--clone-8-cluster-vms)
7. [Phase 4 — workstation (gdragon, Rocky 9)](#phase-4--workstation-gdragon-rocky-9)
8. [Phase 5 — ansible bootstrap (`bstha` user on every host)](#phase-5--ansible-bootstrap-bstha-user-on-every-host)
9. [Phase 6 — base OS config (`base.yml`)](#phase-6--base-os-config-baseyml)
10. [Phase 7 — DNS (dnsmasq HA, `dns.yml`)](#phase-7--dns-dnsmasq-ha-dnsyml)
11. [Phase 8 — load balancer (HAProxy + keepalived, `loadbalancer.yml`)](#phase-8--load-balancer-haproxy--keepalived-loadbalanceryml)
12. [Phase 9 — k8s control plane (`k8s_master.yml`)](#phase-9--k8s-control-plane-k8s_masteryml)
13. [Phase 10 — k8s workers (`k8s_worker.yml`)](#phase-10--k8s-workers-k8s_workeryml)
14. [Phase 11 — Calico CNI (`cni_calico.yml`)](#phase-11--calico-cni-cni_calicoyml)
15. [Phase 12 — Istio (`istio.yml`)](#phase-12--istio-istioyml)
16. [Phase 13 — fetch kubeconfig](#phase-13--fetch-kubeconfig)
17. [Phase 14 — k3s on the workstation](#phase-14--k3s-on-the-workstation)
18. [Phase 15 — ArgoCD on k3s](#phase-15--argocd-on-k3s)
19. [Phase 16 — Vault on k3s (helm, HA shape)](#phase-16--vault-on-k3s-helm-ha-shape)
20. [Phase 17 — Vault init + unseal](#phase-17--vault-init--unseal)
21. [Phase 18 — monitoring stack (kube-prometheus-stack + Loki)](#phase-18--monitoring-stack-kube-prometheus-stack--loki)
22. [Phase 19 — cross-cluster monitoring (homelab → k3os-local)](#phase-19--cross-cluster-monitoring-homelab--k3os-local)
23. [Phase 20 — edge proxy host (Ubuntu 24.04, gdragon-ubuntu)](#phase-20--edge-proxy-host-ubuntu-2404-gdragon-ubuntu)
24. [Phase 21 — image registry on quay.io](#phase-21--image-registry-on-quayio)
25. [Phase 22 — build + push nginx-proxy image](#phase-22--build--push-nginx-proxy-image)
26. [Phase 23 — sub-path mode per app](#phase-23--sub-path-mode-per-app)
27. [Phase 24 — ArgoCD `rootpath=/argocd`](#phase-24--argocd-rootpathargocd)
28. [Phase 25 — day-2 power management](#phase-25--day-2-power-management)
29. [Verification end-to-end](#verification-end-to-end)
30. [Common failure modes & fixes](#common-failure-modes--fixes)
31. [Quick reference: where everything lives](#quick-reference-where-everything-lives)

---

## 1. Goal + outcome

A three-machine home lab that you control end-to-end:

- A **6-node Kubernetes 1.36 cluster** on ESXi (3 control plane + 3 workers)
  fronted by an HA load-balancer pair, with internal DNS.
- A **single-node k3s** on a workstation, hosting **monitoring** (Prometheus +
  Loki + Grafana), **Vault** (3-replica HA shape), and **ArgoCD**.
- An **edge nginx reverse proxy** on a small Ubuntu box that gives you a
  single hostname/port (`http://192.168.1.203/`) for all the user-facing
  apps via path-based routing.

End state (verified): all six proxy paths return 2xx, k8s API healthy
via VIP, monitoring sees both clusters' metrics + logs.

---

## 2. Bill of materials (hardware)

| Role | Box | Spec | OS | IP |
|---|---|---|---|---|
| ESXi hypervisor | HP Z620 (or similar dual-CPU x86 with ≥48 GB RAM) | Intel Xeon E5-2689 8c/16t, 60 GB RAM, ≥2 TB disk | ESXi 6.7.0 build-8169922 (free license) | 192.168.1.174 |
| Workstation | any 16-core, 32 GB RAM x86 box | with at least 128 GiB free `/var` | Rocky Linux 9 | 192.168.1.181 |
| Edge proxy | any small x86 box (Intel NUC class) | 8 GB RAM, 60 GB disk | Ubuntu 24.04 LTS | 192.168.1.203 |

Plus a home router/DHCP server at `192.168.1.1` and a wired switch.

---

## 3. Network plan

| What | Address |
|---|---|
| LAN | `192.168.1.0/24` |
| Router / DHCP / upstream DNS | `192.168.1.1` |
| ESXi management IP | `192.168.1.174` |
| Workstation | `192.168.1.181` |
| Edge proxy | `192.168.1.203` |
| **keepalived VIP (k8s API + internal DNS)** | `192.168.1.50` |
| vault-server (template VM) | `192.168.1.202` |
| kmaster1 / kmaster2 / kmaster3 | `192.168.1.186` / `192.168.1.189` / `192.168.1.187` |
| kworker1 / kworker2 / kworker3 | `192.168.1.182` / `192.168.1.183` / `192.168.1.184` |
| lb1 (MASTER, prio 101) | `192.168.1.188` |
| lb2 (BACKUP, prio 100) | `192.168.1.185` |
| Pod CIDR (homelab k8s) | `10.0.0.0/16` (avoid LAN; matches Calico IPPool) |
| Service CIDR (homelab k8s) | `10.96.0.0/12` (kubeadm default) |
| Internal DNS zone | `myhomelab.com` (served by dnsmasq on the VIP) |

---

## Phase 1 — ESXi 6.7 host install

1. Boot from the ESXi 6.7 ISO. Install to a local SSD; leave room for two
   data datastores on the remaining disks.
2. After first boot:
   - Set a strong root password.
   - Set static IP `192.168.1.174`, gateway `192.168.1.1`, DNS `192.168.1.1`.
   - Enable SSH (Direct Console UI → Troubleshooting Options → Enable SSH).
3. From the workstation, push your SSH public key to ESXi:
   ```bash
   ssh-copy-id -i ~/.ssh/id_ed25519.pub root@192.168.1.174
   ```
4. Create two VMFS-6 datastores via the host UI at `https://192.168.1.174/`:
   - `datastore1` on the first available disk (≥1 TB) — hosts control-plane VMs.
   - `datastore2` on the second disk (≥900 GB) — hosts workers + vault-server.
5. Confirm with:
   ```bash
   ssh root@192.168.1.174 'esxcli storage filesystem list'
   ```

**Gotcha checkpoint**: ESXi sometimes ends up in maintenance mode after
a dirty shutdown — VM power-on then silently fails. Always check:
```bash
ssh root@192.168.1.174 'vim-cmd hostsvc/runtimeinfo | grep -i maintenance'
ssh root@192.168.1.174 'vim-cmd hostsvc/maintenance_mode_exit'   # if needed
```

Reference: `docs/esxi-host.md`.

---

## Phase 2 — vault-server template VM (Rocky 9.7)

This VM is the **live source template** for cloning. It's never decommissioned.

1. Create a new VM through the ESXi host UI on `datastore2`:
   - 2 vCPU, 2 GB RAM, 30 GB thin-provisioned disk.
   - Guest OS: CentOS 7 / 64-bit (Rocky 9 reports the same family to ESXi 6.7).
   - Network: VM Network (default port group on vSwitch0).
2. Attach the **Rocky Linux 9.7 minimal** ISO; boot the VM and run the
   GUI installer. Pick **Server with GUI** (this is the only base where
   we then strip the GUI back out so other roles have plenty of RAM —
   see Phase 6's strip step).
3. During install:
   - Set hostname `vault-server`.
   - Configure the network: static `192.168.1.202/24`, gateway `192.168.1.1`,
     DNS `192.168.1.1`.
   - Create an `ansible` user with sudo, and set a root password.
4. After first boot, log in as `ansible` and lay down the bootstrap that
   every clone will inherit:
   ```bash
   sudo dnf install -y openssh-server qemu-guest-agent open-vm-tools
   sudo systemctl enable --now qemu-guest-agent open-vm-tools sshd

   # IPv6 off, both runtime and at boot — playbooks assume v4 only
   echo 'net.ipv6.conf.all.disable_ipv6 = 1'    | sudo tee /etc/sysctl.d/99-disable-ipv6.conf
   echo 'net.ipv6.conf.default.disable_ipv6 = 1' | sudo tee -a /etc/sysctl.d/99-disable-ipv6.conf
   sudo sysctl --system
   sudo grubby --update-kernel=ALL --args="ipv6.disable=1"

   # SSH key for the ansible controller user — replace with your own pubkey
   mkdir -p ~ansible/.ssh && chmod 700 ~ansible/.ssh
   cat /apps/git-code/keys/ansible-key.pub | sudo tee ~ansible/.ssh/authorized_keys
   sudo chown -R ansible:ansible ~ansible/.ssh && sudo chmod 600 ~ansible/.ssh/authorized_keys

   # Passwordless sudo for the ansible user
   echo 'ansible ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/99-ansible
   ```
5. Strip the GUI (frees ~700 MB RAM per clone):
   ```bash
   sudo systemctl set-default multi-user.target
   sudo dnf groupremove -y "Server with GUI" "GNOME"
   sudo dnf autoremove -y
   sudo reboot
   ```
6. Verify post-reboot:
   ```bash
   ssh -i /apps/git-code/keys/ansible-key ansible@192.168.1.202 'uname -a; cat /etc/redhat-release'
   ```

**The vault-server is the template.** Any base-image change goes here
first, then propagates on the next `clone-from-vault.sh` run.

Reference: `docs/vault-server.md`.

---

## Phase 3 — clone 8 cluster VMs

The clone path is **`terraform/clone-from-vault.sh`**. It is a bash
script that ssh's to ESXi and runs `vmkfstools` + `vim-cmd` directly
(no ovftool, no Packer — both were abandoned). It produces 8 thin
clones of the powered-off vault-server.

> **Why this approach**: Packer's anaconda kickstart kept landing in
> interactive TUI (~12 attempts). The josenk/esxi Terraform provider's
> ovftool consistently hit `vim.fault.TaskInProgress` on vault-server.
> `vmkfstools -i thin` on the live source VM (powered off briefly) is
> ~1–3 min per 20 GB disk and just works.

```bash
cd /apps/git-code/git-vsphere
bash terraform/clone-from-vault.sh
```

The script:
1. Powers off vault-server briefly.
2. For each target VM (`kmaster1/2/3, kworker1/2/3, lb1, lb2`):
   - `vmkfstools -i <src> -d thin <dst>` to copy the disk.
   - Writes a new `<vm>.vmx` with a fresh UUID, MAC, hostname, and IP.
   - `vim-cmd solo/registervm <vmx-path>` to register.
   - `vim-cmd vmsvc/power.on <vmid>`.
3. Powers vault-server back on.

After it finishes:
```bash
ssh root@192.168.1.174 'vim-cmd vmsvc/getallvms'
# expect 9 VMs total
```

**ESXi gotchas the script handles**:
- Use POSIX `sh` (busybox), not bash — no `declare`, no `<<<`, no `mapfile`.
- `cat file | ssh root@host "cat > /path"` instead of `scp` (scp is buggy on ESXi 6.7).
- Use a `for x in $LIST; do ... & done` loop instead of `cmd | while ... & done`
  for parallelism — pipe-subshells don't propagate to `wait`.
- `00:0c:29:*` is VMware's reserved OUI; you cannot set static MACs in that
  range. The script generates fresh `00:50:56:xx:xx:xx` MACs.
- `/tmp` on ESXi is a ramdisk — keep large logs elsewhere.
- After editing a VMX you must `vim-cmd vmsvc/reload <vmid>` before
  `power.on`, or unregister + re-register (hostd caches VMX in memory).

Reference: `docs/esxi-host.md`, `terraform/clone-from-vault.sh`.

---

## Phase 4 — workstation (gdragon, Rocky 9)

This is where ansible runs from and where you eventually install k3s + the
cluster of supporting apps. Set it up before bootstrapping the homelab VMs
because the workstation is the ansible controller.

```bash
# Static IP 192.168.1.181, hostname gdragon, Rocky 9 minimal install.
# Install the tooling:
sudo dnf install -y ansible-core git python3-jmespath python3-netaddr \
                    jq dig bind-utils ipcalc curl podman \
                    epel-release
sudo dnf install -y python3-pip
pip3 install --user passlib   # used by some ansible community plugins

# helm (for charts)
curl -fsSL https://get.helm.sh/helm-v3.16.0-linux-amd64.tar.gz | tar xz -C /tmp
sudo mv /tmp/linux-amd64/helm /usr/local/bin/

# kubectl
sudo curl -fsSL -o /usr/local/bin/kubectl \
  https://dl.k8s.io/release/v1.30.0/bin/linux/amd64/kubectl
sudo chmod +x /usr/local/bin/kubectl
```

Grow `/var` if it's tight (PVCs live there once k3s + helm releases are up):

```bash
# Add a second disk, e.g. /dev/sdb 100 GiB, then:
sudo pvcreate /dev/sdb
sudo vgextend <existing-vg> /dev/sdb
sudo lvextend -L +100G /dev/<vg>/var
sudo xfs_growfs /var
df -h /var   # should now be ~128 GiB
```

Clone the repo:
```bash
cd /apps/git-code
git clone git@github.com:myhome-automation/git-vsphere.git
cd git-vsphere
```

The `ansible/inventory/group_vars` symlink must exist for vars to auto-load:
```bash
ln -sfn ../group_vars ansible/inventory/group_vars   # if missing on fresh checkout
```

Set up the ansible-vault password file (gitignored):
```bash
echo 'your-vault-password-here' > ansible/.vault_pass
chmod 600 ansible/.vault_pass
```

---

## Phase 5 — ansible bootstrap (`bstha` user on every host)

The clones were laid down with the `ansible` user (Phase 2). All
ongoing playbooks run as `bstha` — a sudoers user with your normal
SSH key, kept separate from the cluster-build identity.

```bash
cd /apps/git-code/git-vsphere/ansible

# Add bstha + your SSH pubkey + NOPASSWD sudo on every host
ansible-playbook -i inventory/hosts.ini --vault-password-file=.vault_pass \
  playbooks/bootstrap-users.yml
```

What it does (per host in the `everyone` group, which is `cluster + vault`):
- Creates user `bstha` with primary group `bstha`.
- Drops an `authorized_keys` file with `/apps/git-code/keys/ansible-key.pub`
  (your controller pubkey).
- `bstha ALL=(ALL) NOPASSWD: ALL` in `/etc/sudoers.d/`.

Sanity check:
```bash
ansible -i inventory/hosts.ini --vault-password-file=.vault_pass everyone -m ping
# all hosts should return "pong"
```

Reference: `docs/ansible.md`.

---

## Phase 6 — base OS config (`base.yml`)

Idempotent baseline tweaks that every cluster host needs. Run as part of
`site.yml` or directly:

```bash
ansible-playbook -i inventory/hosts.ini --vault-password-file=.vault_pass \
  playbooks/site.yml --tags base

# or, skip the slow dnf update:
ansible-playbook ... playbooks/site.yml --tags base --skip-tags update
```

What `base.yml` does:
- `dnf update -y` (skippable with `--skip-tags update`).
- `timedatectl set-timezone {{ timezone }}` (`America/Chicago` by default).
- Install: `chrony`, `python3-firewall`, `tar`, `iproute-tc`, `iptables`,
  `nftables`, `vim`, `bash-completion`, `curl`, `jq`, `bind-utils`.
- `chronyd` running; NTP servers from upstream pool.
- `SELinux` set to permissive (Calico-plus-firewalld interactions are
  hard enough already — see Calico phase).
- `firewalld` enabled but with `zone=trusted` carve-outs added in
  later playbooks.

Reference: `ansible/playbooks/base.yml`.

---

## Phase 7 — DNS (dnsmasq HA, `dns.yml`)

DNS is served by `dnsmasq` running on **both** lb1 and lb2 in
`bind-dynamic` mode, so whichever node holds the keepalived VIP also
answers queries on `192.168.1.50:53`.

```bash
ansible-playbook ... playbooks/site.yml --tags dns
```

What `dns.yml` does:
- Installs `dnsmasq` on `loadbalancers` group.
- Drops `/etc/dnsmasq.d/myhomelab.conf` with:
  - `bind-dynamic` (so it can listen on the VIP only when held).
  - `local=/myhomelab.com/`
  - `addn-hosts=/etc/dnsmasq.hosts.d/myhomelab.hosts`
  - Upstream forwarders (`8.8.8.8`, `8.8.4.4`).
- Writes `/etc/dnsmasq.hosts.d/myhomelab.hosts` with the cluster A/PTR
  records (kmaster1.myhomelab.com etc.).
- Installs identical files on lb2.
- Configures NetworkManager on every cluster host (`everyone` group)
  to use `192.168.1.50` as resolver.

Smoke test:
```bash
dig @192.168.1.50 kmaster1.myhomelab.com +short    # → 192.168.1.186
dig @192.168.1.50 -x 192.168.1.186 +short          # → kmaster1.myhomelab.com.
```

Reference: `docs/dns.md`.

---

## Phase 8 — load balancer (HAProxy + keepalived, `loadbalancer.yml`)

Two LBs in active/backup. Failover ~3 s.

```bash
ansible-playbook ... playbooks/site.yml --tags lb
```

What `loadbalancer.yml` does on each of lb1/lb2:
- Installs `haproxy` + `keepalived`.
- **keepalived**:
  - `vrrp_instance VI_1` on `interface=ens192` (or whatever the LB
    nics are named — see the role's autodetect).
  - `state` and `priority` from inventory vars (`MASTER`/101 vs
    `BACKUP`/100).
  - `virtual_ipaddress 192.168.1.50`.
  - Authentication uses `vault_keepalived_password` (ansible-vault encrypted).
- **HAProxy** (`/etc/haproxy/haproxy.cfg`):
  - `frontend k8s-api :6443` → tcp roundrobin → kmaster1/2/3:6443.
  - `frontend http :80`  → roundrobin → kworker1/2/3:30080.
  - `frontend https :443` → roundrobin → kworker1/2/3:30443.
  - Stats page on `:8404`.

Test failover:
```bash
# VIP currently on lb1
ssh ansible@lb1 'sudo systemctl stop keepalived'
sleep 4
ssh ansible@lb2 'ip -4 addr show ens192 | grep 192.168.1.50'   # VIP migrated
ssh ansible@lb1 'sudo systemctl start keepalived'              # VIP returns
```

Reference: `docs/haproxy.md`.

---

## Phase 9 — k8s control plane (`k8s_master.yml`)

```bash
ansible-playbook ... playbooks/site.yml --tags k8s   # also runs k8s_worker
```

What `k8s_master.yml` does:
- Adds the Kubernetes 1.36 repo, installs `kubelet`, `kubeadm`, `kubectl`,
  `containerd.io`.
- **Regenerates** `/etc/containerd/config.toml` (the Rocky default
  ships with CRI plugin disabled — kubeadm init would fail with
  "unknown service runtime.v1.RuntimeService").
- `swapoff -a` + remove swap from `/etc/fstab`.
- Opens firewalld ports for the control plane:
  - `6443/tcp` (apiserver), `2379-2380/tcp` (etcd), `10250-10259/tcp`
    (kubelet/CM/sched), `179/tcp` (Calico BGP), `5473/tcp` (Calico
    Typha), `4789/udp` (VXLAN).
- Adds `source={{ pod_network_cidr }}` to firewalld zone `trusted` so
  pod-to-pod traffic isn't dropped (see "Calico + firewalld gotcha"
  below).
- On `kmaster1` only: `kubeadm init --control-plane-endpoint=192.168.1.50:6443
  --upload-certs --pod-network-cidr=10.0.0.0/16`.
- On `kmaster2`/`kmaster3`: `kubeadm join ... --control-plane`.
- Drops `/root/.kube/config` for root on each master.

Reference: `docs/k8s-cluster.md`.

---

## Phase 10 — k8s workers (`k8s_worker.yml`)

Same as the master tasks for containerd + repo + firewall, then:
- `kubeadm join 192.168.1.50:6443 --token <X> --discovery-token-ca-cert-hash <Y>`
- Open the same firewall ports + pod CIDR to `zone=trusted`.

After this, `kubectl get nodes` on kmaster1 should show 6 nodes; their
`READY` state stays `NotReady` until Calico is installed.

---

## Phase 11 — Calico CNI (`cni_calico.yml`)

```bash
ansible-playbook ... playbooks/site.yml --tags calico
```

What it does (on kmaster1):
- `kubectl apply -f` the **Tigera operator** manifests (v3.30.4).
- `kubectl apply` an `Installation` CR with `cidr: 10.0.0.0/16`,
  `encapsulation: VXLANCrossSubnet`, IP-in-IP off.
- Waits for the `tigerastatus` to go all `True`.

**Calico + firewalld gotcha (read this)**:
After a host reboot, firewalld blocks Calico's BGP and pod-to-pod
traffic. Symptom: `calico-node` pods come up `0/1`; BIRD reports "BGP
not established"; `v3.projectcalico.org` APIService flips to
`FailedDiscoveryCheck`; Istio sidecars later can't reach `istiod`.

The fix is **already baked into `k8s_master.yml`/`k8s_worker.yml`**:
- Open `179/tcp` (BGP), `5473/tcp` (Typha), `4789/udp` (VXLAN).
- Add `source={{ pod_network_cidr }}` to firewalld `zone=trusted` —
  this is what actually lets pod-to-pod packets through.

If `tigerastatus/ippools` stays `Degraded` even after BGP recovers,
tigera-operator is caching a poisoned discovery client:
```bash
kubectl --context homelab -n tigera-operator rollout restart deploy/tigera-operator
```

Reference: `docs/calico.md`.

---

## Phase 12 — Istio (`istio.yml`)

```bash
ansible-playbook ... playbooks/site.yml --tags istio
```

What it does:
- Downloads `istioctl 1.27.2` to `/opt/istio/istio-1.27.2/` on kmaster1.
- Runs `istioctl install --set profile=default -y`.
- Adds `istio-injection=enabled` label to the `default` namespace.
- `istio-ingressgateway` is created but has no external IP yet
  (no MetalLB / cloud LB on this lab — open item).

---

## Phase 13 — fetch kubeconfig

From the workstation:
```bash
cd /apps/git-code/git-vsphere
bash scripts/fetch-kubeconfig.sh homelab 192.168.1.186
# ssh → kmaster1, sudo-reads /etc/kubernetes/admin.conf, rewrites
# cluster/user/context to "homelab", merges into ~/.kube/config.
```

Confirm:
```bash
kubectl --context homelab get nodes        # 6 nodes Ready
kubectl --context homelab get pods -A | grep -v Running | grep -v Completed
# should be empty after a minute or two
```

---

## Phase 14 — k3s on the workstation

A separate **single-node k3s** cluster on gdragon (.181) hosts the
monitoring stack, Vault, and ArgoCD. Installed with Calico CNI for
NetworkPolicy support.

```bash
# Install k3s without its built-in flannel/traefik so we can drop in Calico
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.34.3+k3s1 \
  INSTALL_K3S_EXEC="server --flannel-backend=none --disable-network-policy --cluster-cidr=192.168.0.0/16 --service-cidr=10.43.0.0/16 --disable traefik" \
  sh -

# Wait for it to come up, then install Calico
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/k3s.yaml
sudo chown $(id -u):$(id -g) ~/.kube/k3s.yaml
sed -i 's/127.0.0.1/192.168.1.181/' ~/.kube/k3s.yaml
KUBECONFIG=~/.kube/k3s.yaml:~/.kube/config kubectl config view --flatten > ~/.kube/merged
mv ~/.kube/merged ~/.kube/config
kubectl config rename-context default k3os-local
kubectl config use-context k3os-local

# Calico (Tigera operator)
kubectl --context k3os-local apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.30.4/manifests/tigera-operator.yaml
kubectl --context k3os-local apply -f - <<'YAML'
apiVersion: operator.tigera.io/v1
kind: Installation
metadata: { name: default }
spec:
  calicoNetwork:
    ipPools:
      - blockSize: 26
        cidr: 192.168.0.0/16
        encapsulation: VXLANCrossSubnet
        natOutgoing: Enabled
        nodeSelector: all()
YAML
```

> **Known limitation — Calico IPPool overlap.**
> `192.168.0.0/16` overlaps with the home LAN `192.168.1.0/24`. Calico's
> `cali-nat-outgoing` deliberately skips MASQUERADE when the destination
> is inside any pool CIDR, so pods can't reach `192.168.1.x` natively.
> Workaround: a systemd unit `k3s-pod-masq.service` on the workstation
> inserts MASQUERADE rules at the top of nat POSTROUTING for
> `pod CIDR → home network` and `pod CIDR → everything-outside-the-pool`.
> Proper destructive fix (TODO): migrate the IPPool to a non-overlapping
> CIDR (e.g. `10.42.0.0/16`), which rebuilds every pod on k3s. See
> `vault/README.md`.

---

## Phase 15 — ArgoCD on k3s

```bash
kubectl --context k3os-local create namespace argocd
kubectl --context k3os-local -n argocd apply -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/v2.13.0/manifests/install.yaml

# NodePort expose
kubectl --context k3os-local -n argocd patch svc argocd-server --type merge -p '
{"spec":{"type":"NodePort","ports":[
  {"name":"http","port":80,"targetPort":8080,"nodePort":30401},
  {"name":"https","port":443,"targetPort":8080,"nodePort":30400}
]}}'

# Initial admin password
kubectl --context k3os-local -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d ; echo
```

---

## Phase 16 — Vault on k3s (helm, HA shape)

Managed declaratively by ArgoCD via `argocd/vault.yaml` in this repo.

```bash
kubectl --context k3os-local apply -f argocd/vault.yaml
```

The ArgoCD `Application` pulls `hashicorp/vault` helm chart `0.31.0`
with these key values (mirrored in `vault/values.yaml`):
- `server.image.tag: "1.20.4"`
- `server.ha.enabled: true`, `server.ha.replicas: 3`, raft storage
- `server.service.type: NodePort`, `nodePort: 30200`
- **Liveness probe path with `sealedcode=204`** (critical — see below)
- Readiness probe also uses `sealedcode=204&uninitcode=204`
- Audit + data storage on `local-path` PVCs (2 Gi + 5 Gi each)
- `podAntiAffinity` (best-effort) so pods spread across nodes — on
  single-node k3s this is a no-op but useful when scaling out

**Why `sealedcode=204` matters**: Vault always boots **sealed** (manual
unseal is part of the lifecycle). The chart's default liveness probe
hits `/v1/sys/health?standbyok=true`, which returns 503 when sealed.
The kubelet then kills the pod before you can unseal. Fix is in the
values: `path: "/v1/sys/health?standbyok=true&sealedcode=204&uninitcode=204"`.
This kept biting us until 2026-05-18.

---

## Phase 17 — Vault init + unseal

One-time init (vault-0 only):
```bash
mkdir -p ~/.vault
kubectl --context k3os-local -n vault exec vault-0 -- \
  vault operator init -key-shares=5 -key-threshold=3 -format=json \
  > ~/.vault/init.json
chmod 600 ~/.vault/init.json
```

Unseal each pod (3 keys reach the threshold):
```bash
for r in vault-0 vault-1 vault-2; do
  jq -r '.unseal_keys_b64[:3][]' ~/.vault/init.json | while read key; do
    kubectl --context k3os-local -n vault exec $r -- \
      vault operator unseal "$key" 2>/dev/null || true
  done
done
```

Enable KV-v2 + AppRole (root token from `~/.vault/init.json`):
```bash
ROOT=$(jq -r .root_token ~/.vault/init.json)
kubectl --context k3os-local -n vault exec vault-0 -- env VAULT_TOKEN="$ROOT" \
  vault secrets enable -path=secret kv-v2
kubectl --context k3os-local -n vault exec vault-0 -- env VAULT_TOKEN="$ROOT" \
  vault auth enable approle
```

**vault-1 may stay `CrashLoopBackOff`** because of the Calico IPPool
overlap (its pod IP can't reach vault-0:8201 for the raft join). vault-0
+ vault-2 forming a 2-node quorum is acceptable for a home lab. The
destructive fix is the IPPool migration above.

Service routing — what to point at:
- `vault-active` Service, NodePort `31326` → **leader-only** (use this).
- `vault` Service, NodePort `30200` → all pods including sealed ones; don't.
- `vault-standby` Service, NodePort `32012` → followers; rarely used.

Reference: `vault/README.md`.

---

## Phase 18 — monitoring stack (kube-prometheus-stack + Loki)

On **local k3s** (the "search head"):

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm --kube-context k3os-local upgrade --install kps \
  prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f monitoring/local-k3s/kube-prometheus-stack-values.yaml

helm --kube-context k3os-local upgrade --install loki \
  grafana/loki-stack \
  -n monitoring \
  -f monitoring/local-k3s/loki-stack-values.yaml
```

`monitoring/local-k3s/kube-prometheus-stack-values.yaml` already sets:
- `prometheus.prometheusSpec.enableRemoteWriteReceiver: true`
- `prometheus.prometheusSpec.externalUrl: http://192.168.1.203/prometheus`
- `prometheus.prometheusSpec.routePrefix: /prometheus`
- `prometheus.prometheusSpec.externalLabels: { cluster: k3os-local }`
- `prometheus.service.type: NodePort` / `nodePort: 30320`
- `grafana.adminPassword: changeme-home-lab`
- `grafana.grafana.ini.server.{root_url, serve_from_sub_path}` for `/grafana/` mode
- `grafana.service.type: NodePort` / `nodePort: 30300`
- All the k3s-collapsed jobs disabled: `kubeControllerManager`, `kubeScheduler`, `kubeProxy`, `kubeEtcd`.
- Right-sized resources for 5.8 GiB total RAM.

`monitoring/local-k3s/loki-stack-values.yaml`:
- `loki.service.type: NodePort` + `nodePort: 30310`
- Grafana subchart disabled (we use the one from kps)

After install:
```bash
kubectl --context k3os-local -n monitoring rollout status deploy/kps-grafana
kubectl --context k3os-local -n monitoring rollout status sts/prometheus-kps-prometheus
kubectl --context k3os-local -n monitoring rollout status sts/loki
```

---

## Phase 19 — cross-cluster monitoring (homelab → k3os-local)

On the **homelab** cluster, install Prometheus only (no Grafana / AM)
plus Promtail, both shipping data west to gdragon:30320/30310.

```bash
kubectl --context homelab create namespace monitoring

helm --kube-context homelab upgrade --install kps \
  prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f monitoring/homelab/kube-prometheus-stack-values.yaml

helm --kube-context homelab upgrade --install promtail \
  grafana/promtail \
  -n monitoring \
  -f monitoring/homelab/promtail-values.yaml
```

Key bits in `monitoring/homelab/kube-prometheus-stack-values.yaml`:
- `grafana.enabled: false`, `alertmanager.enabled: false`
- `prometheus.prometheusSpec.externalLabels: { cluster: homelab }`
- `prometheus.prometheusSpec.remoteWrite: [{ url: http://192.168.1.181:30320/api/v1/write }]`
- Scrape configs for kube-apiserver, kubelet, kube-state-metrics,
  node-exporter (all the standard kps targets).

`monitoring/homelab/promtail-values.yaml`:
- `config.clients: [{ url: http://192.168.1.181:30310/loki/api/v1/push }]`
- `config.snippets.extraClientConfigs: { external_labels: { cluster: homelab } }`

In Grafana, both data sources are stamped with the `cluster=` label so
dashboards can split sources. Watch out: local Prometheus scrapes
itself with NO `cluster` label by default (externalLabels only stamp on
egress / remote_write). A useful filter is `{cluster=~"k3os-local|"}`.

Reference: `monitoring/README.md`.

---

## Phase 20 — edge proxy host (Ubuntu 24.04, gdragon-ubuntu)

Install Ubuntu 24.04 LTS minimal on the third box; static IP `192.168.1.203`.
Allow rootless podman to bind privileged port 80:

```bash
echo 'net.ipv4.ip_unprivileged_port_start=80' | sudo tee /etc/sysctl.d/99-rootless-low-ports.conf
sudo sysctl -p /etc/sysctl.d/99-rootless-low-ports.conf
sudo apt-get update && sudo apt-get install -y podman
```

Make sure `bstha` has SSH key access from the workstation (drop your
pubkey in `~/.ssh/authorized_keys`).

Add it to the ansible inventory as `[edge_proxy]` if it isn't already:
```ini
[edge_proxy]
gdragon-edge ansible_host=192.168.1.203 ansible_user=bstha ansible_ssh_private_key_file=/home/bstha/.ssh/id_ed25519
```

---

## Phase 21 — image registry on quay.io

Two repos under `quay.io/bpraisa/`:
- `quay.io/bpraisa/nginx` — custom edge reverse-proxy image (we build).
- `quay.io/bpraisa/vault` — mirror of `hashicorp/vault` (for future helm cutover).

**Auth model**: a quay.io **robot account**, scoped per-repo with `Write`.
Username + token stored ansible-vault encrypted in
`ansible/group_vars/all/vault.yml` as:
- `vault_quay_username`
- `vault_quay_password`

To set / rotate:
```bash
ansible-vault edit ansible/group_vars/all/vault.yml --vault-password-file=ansible/.vault_pass
```

Bootstrap a persistent podman authfile on the edge host (idempotent):
```bash
cd ansible/
ansible-playbook -i inventory/hosts.ini --vault-password-file=.vault_pass \
  playbooks/quay-login.yml
# Result: ~/.config/containers/auth.json on 192.168.1.203
```

**Per-repo permission gotcha (bit us 2026-05-18)**: robot accounts are
scoped per-repo. A brand-new repo needs the robot added under
`Settings → User and Robot Permissions` with `Write` access. Symptom:
`unauthorized: access to the requested resource is not authorized` on
`podman push`.

---

## Phase 22 — build + push nginx-proxy image

Source lives in `nginx-proxy/`:
- `Dockerfile` — `FROM docker.io/library/nginx:1.27-alpine`, COPYs `nginx.conf`.
- `nginx.conf` — path-based routing rules (see Phase 23 for the location blocks).
- `install.sh` — deploys 2 containers on the edge host.
- `build-and-push.sh` — bundled build + push helper.

Build + push (using the persistent authfile from Phase 21):
```bash
TAG=homelab-proxy-1.4   # bump on every config change

scp nginx-proxy/{Dockerfile,nginx.conf} bstha@192.168.1.203:/tmp/
ssh bstha@192.168.1.203 \
  "cd /tmp && podman build -t quay.io/bpraisa/nginx:${TAG} ."

ssh bstha@192.168.1.203 \
  "podman push --authfile ~/.config/containers/auth.json \
   quay.io/bpraisa/nginx:${TAG}"
```

Deploy the 2-container HA pair:
```bash
sed -i "s|homelab-proxy-[0-9.]*|${TAG}|g" nginx-proxy/install.sh
bash nginx-proxy/install.sh 192.168.1.203
```

`install.sh` runs on the edge host as `bstha`:
- Stops any system nginx.
- Ensures rootless port 80 binding is allowed.
- `podman pull quay.io/bpraisa/nginx:${TAG}`.
- `podman rm -f nginx-1 nginx-2` (if present).
- `podman run -d --restart=always --name nginx-1 -p 80:80 ...`
- `podman run -d --restart=always --name nginx-2 -p 8080:80 ...`

Reference: `nginx-proxy/README.md`.

---

## Phase 23 — sub-path mode per app

The edge proxy mounts each app at a path under `http://192.168.1.203/`.
Different apps need different upstream config to make sub-paths work:

| App | nginx `location` strategy | App-side config required |
|---|---|---|
| `/grafana/` | preserve prefix (`proxy_pass http://grafana;`) | helm: `grafana.grafana.ini.server.{root_url=http://192.168.1.203/grafana/, serve_from_sub_path=true}` |
| `/prometheus/` | preserve prefix | helm: `prometheus.prometheusSpec.{externalUrl=http://192.168.1.203/prometheus, routePrefix=/prometheus}` |
| `/loki/` | strip prefix (`proxy_pass http://loki/;`) | none — Loki has no sub-path mode but its endpoints already live at root (`/ready`, `/metrics`, `/loki/api/v1/*`). Stripping `/loki/` aligns them. |
| `/argocd/` | preserve prefix | configmap `argocd-cmd-params-cm` `server.rootpath: /argocd` (see Phase 24) |
| `/ui/`, `/v1/` (Vault, root-mounted) | direct pass | none — Vault has no sub-path mode; its Ember SPA hard-codes `rootURL="/ui/"`. Solution: don't mount Vault under a sub-path; expose `/ui/` and `/v1/` at the nginx root. `/vault/*` 302-redirects to `/ui/`. |

The full `nginx-proxy/nginx.conf`:
```nginx
upstream grafana    { server 192.168.1.181:30300; }
upstream prometheus { server 192.168.1.181:30320; }
upstream loki       { server 192.168.1.181:30310; }
upstream vault      { server 192.168.1.181:31326; }   # vault-active, leader-only
upstream argocd     { server 192.168.1.181:30401; }

server {
  listen 80 default_server;

  location = /            { return 200 '<landing page>'; default_type text/html; }
  location /grafana/      { proxy_pass http://grafana;    <headers>; }
  location /prometheus/   { proxy_pass http://prometheus; <headers>; }
  location /loki/         { proxy_pass http://loki/;      <headers>; }
  location /ui/           { proxy_pass http://vault;      <headers>; }
  location /v1/           { proxy_pass http://vault;      <headers>; }
  location = /vault       { return 302 /ui/; }
  location = /vault/      { return 302 /ui/; }
  location /vault/        { rewrite ^/vault/(.*)$ /$1 last; }
  location /argocd/       { proxy_pass http://argocd;     <headers>; gRPC-upgrade; }
}
```

(See the actual file for header/timeout details — this is the structural map.)

---

## Phase 24 — ArgoCD `rootpath=/argocd`

```bash
kubectl --context k3os-local -n argocd patch configmap argocd-cmd-params-cm \
  --type merge -p '{"data":{"server.rootpath":"/argocd"}}'

kubectl --context k3os-local -n argocd rollout restart deploy/argocd-server
```

After the rollout, `http://192.168.1.181:30401/argocd/` and
`http://192.168.1.203/argocd/` both render the UI correctly.

---

## Phase 25 — day-2 power management

Four tiers, smallest scope to largest:

| Playbook | Scope |
|---|---|
| `cluster_shutdown.yml` / `cluster_powerup.yml` | 8 cluster VMs only (vault-server skipped) |
| `all_shutdown.yml` / `all_powerup.yml` | 9 ESXi VMs (incl. vault-server) |
| `edge_shutdown.yml` / `edge_powerup.yml` | nginx-1 + nginx-2 on .203 |
| **`full_shutdown.yml` / `full_powerup.yml`** | **3-host orchestration — recommended** |

`full_powerup.yml` does, in order:
1. **ESXi maintenance-mode pre-check** (fails fast with the exit command).
2. Power on all 9 VMs (vault-server → LBs → masters → workers).
3. `chronyc makestep` on each VM to absorb ESXi clock drift.
4. Probe k8s API + DNS via the keepalived VIP.
5. Unseal Vault (`vault_unseal.yml`) with keys from `~/.vault/init.json`.
6. (Re)start edge nginx pair and probe all six routes.

`full_shutdown.yml` reverses the order: edge nginx stops first (so users
see a clean cut), then the 9 VMs in workers → LBs → masters → vault-server
order.

Usage:
```bash
cd ansible/
ansible-playbook -i inventory/hosts.ini --vault-password-file=.vault_pass \
  playbooks/full_powerup.yml      # or full_shutdown.yml
```

Reference: `docs/operations.md` and `docs/restart-sequence.md`.

---

## Verification end-to-end

Run this list after a fresh build (or after `full_powerup.yml`):

```bash
# 1. Homelab cluster up
kubectl --context homelab get nodes
# expect 6 nodes Ready, k8s v1.36.1

# 2. Calico healthy
kubectl --context homelab get tigerastatus
# apiserver + calico: True/True

# 3. k8s API via VIP
curl -sk https://192.168.1.50:6443/healthz                 # → ok

# 4. DNS via VIP
dig @192.168.1.50 kmaster1.myhomelab.com +short            # → 192.168.1.186

# 5. LB failover
ssh ansible@lb1 'sudo systemctl stop keepalived'
sleep 4
ssh ansible@lb2 'ip -4 addr show ens192 | grep 192.168.1.50'   # VIP migrated
curl -sk https://192.168.1.50:6443/healthz                     # still ok
ssh ansible@lb1 'sudo systemctl start keepalived'              # VIP returns

# 6. Local k3s up
kubectl --context k3os-local get pods -A | grep -v Running | grep -v Completed
# should be empty except for the known vault-1 CrashLoopBackOff

# 7. Vault leader is unsealed + active
kubectl --context k3os-local -n vault exec vault-0 -- vault status | grep -E "Sealed|HA Mode"
# Sealed: false   HA Mode: active

# 8. Edge proxy — every path 2xx
for p in / /grafana/ /prometheus/ /loki/ready /ui/ /argocd/ /v1/sys/health; do
  printf "%-22s %s\n" "$p" "$(curl -sSL -o /dev/null -w '%{http_code}' http://192.168.1.203$p)"
done

# 9. Cross-cluster metrics flowing
kubectl --context k3os-local -n monitoring exec prometheus-kps-prometheus-0 -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=up{cluster="homelab"}' | jq '.data.result | length'
# expect >0
```

---

## Common failure modes & fixes

| Symptom | Cause | Fix |
|---|---|---|
| `cluster_powerup.yml` reports success but every VM stays `Powered off`. `hostd.log`: "State Transition not allowed". | ESXi in maintenance mode (sometimes after a dirty shutdown). | `ssh root@192.168.1.174 'vim-cmd hostsvc/maintenance_mode_exit'`. Re-run powerup. The new playbooks pre-check this. |
| `vim-cmd vmsvc/power.on` fails with `vim.fault.InvalidState`. | hostd has stale VMX cache. | `vim-cmd vmsvc/reload <vmid>`. If that also fails: `/etc/init.d/hostd restart` (safe when no VMs running). Last resort: `unregister` + `solo/registervm`. |
| `calico-node` pods are `0/1`, BIRD "BGP not established", `v3.projectcalico.org` APIService `FailedDiscoveryCheck`. | firewalld blocks BGP (179) and pod CIDR after reboot. | Already fixed in `k8s_master.yml`/`k8s_worker.yml`. If a host slips through: open 179/tcp + 5473/tcp + 4789/udp and `firewall-cmd --permanent --zone=trusted --add-source={{ pod_network_cidr }}` then `firewall-cmd --reload`. |
| `tigerastatus/ippools` `Degraded` even after BGP recovers. | Operator caches a poisoned discovery client. | `kubectl --context homelab -n tigera-operator rollout restart deploy/tigera-operator`. |
| Vault pods CrashLoopBackOff, all sealed. | Default liveness probe path lacks `sealedcode=204`. | `argocd/vault.yaml` + `vault/values.yaml` now set `path: /v1/sys/health?standbyok=true&sealedcode=204&uninitcode=204`. ArgoCD sync rolls the StatefulSet. |
| vault-1 stays CrashLoopBackOff after the liveness fix. | Calico IPPool `192.168.0.0/16` overlaps home LAN; vault-1's pod IP can't reach vault-0:8201. | Workaround already in place via `k3s-pod-masq.service`. Destructive fix: migrate IPPool to non-overlapping CIDR. |
| Through-proxy URL returns 404 even though direct NodePort works. | App not configured for its sub-path. | Apply the per-app fix in Phase 23. Most need helm values; ArgoCD needs the configmap patch in Phase 24. |
| Vault `/vault/` redirects to `/ui/` but UI renders blank. | Vault SPA hard-codes `rootURL=/ui/` and fetches absolute paths. | Don't mount Vault under a sub-path — expose `/ui/` and `/v1/` at nginx root, as the current `nginx.conf` does. |
| `podman push` to a new quay repo fails with `unauthorized`. | Robot account doesn't have Write on the new repo. | Quay → repo → Settings → User and Robot Permissions → add the robot with Write. |
| Prometheus rejects remote_write samples as "out of order". | ESXi clock drifted; VMs inherited the drift. | `chronyc makestep` on every VM (now automatic in `all_powerup.yml`). Fix ESXi NTP too — open item. |
| ArgoCD `repo-server` can't fetch helm charts (SERVFAIL on external DNS). | k3s pods can't reach the home router because of the IPPool overlap. | `k3s-pod-masq.service` workaround already applied. Verify with `kubectl --context k3os-local -n argocd exec deploy/argocd-repo-server -- nslookup helm.releases.hashicorp.com`. |

---

## Quick reference: where everything lives

**Repo layout (`/apps/git-code/git-vsphere`):**
- `ansible/` — all playbooks, inventory, group_vars, ansible.cfg
- `terraform/clone-from-vault.sh` — the ESXi VM clone script (Phase 3)
- `monitoring/` — helm values for local-k3s + homelab monitoring stacks
- `vault/` — `values.yaml` (mirror of inlined ArgoCD Application values) + `README.md`
- `argocd/` — ArgoCD Application manifests (`vault.yaml`, `app-of-apps.yaml`)
- `nginx-proxy/` — Dockerfile, nginx.conf, install.sh, build-and-push.sh for the edge proxy
- `docs/` — per-component runbooks (deeper than this single-file guide)
- `drawio-dgr/` — multi-page draw.io architecture diagrams
- `AGENTS.md` — short orientation for anyone (human or AI agent) coming cold
- `INFRA_IMPLEMENTATION_NOTES.md` — **this file**

**External resources:**
- GitHub: `git@github.com:myhome-automation/git-vsphere.git`
- Quay: `quay.io/bpraisa/nginx`, `quay.io/bpraisa/vault`
- ESXi web UI: `https://192.168.1.174/`
- Grafana: `http://192.168.1.203/grafana/` (admin / changeme-home-lab)
- Prometheus: `http://192.168.1.203/prometheus/`
- Loki (no UI): `http://192.168.1.203/loki/ready`
- ArgoCD: `http://192.168.1.203/argocd/` (admin / initial-admin-secret)
- Vault: `http://192.168.1.203/ui/` (Token method, root from `~/.vault/init.json`)

**Credentials cheatsheet:**
- ansible-vault password: `ansible/.vault_pass` on the workstation (gitignored).
- SSH key for ansible user on cluster VMs: `/apps/git-code/keys/ansible-key`.
- `bstha` SSH key for ongoing work: `~/.ssh/id_ed25519` (workstation default).
- Vault root token + unseal keys: `~/.vault/init.json` on the workstation (chmod 600). **Move to a password manager and wipe from disk for production-grade hygiene.**
- ArgoCD admin password: `kubectl --context k3os-local -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`.
- Grafana admin password: `changeme-home-lab` (in `monitoring/local-k3s/kube-prometheus-stack-values.yaml`; rotate via `helm upgrade --set grafana.adminPassword=...`).
- quay.io robot creds: ansible-vault encrypted at `ansible/group_vars/all/vault.yml`.

---

*End of file. If you reached here from a cold start, this is the one
guide that will get you to a working lab. For surgical questions on a
single component (e.g. "why is BGP failing on Calico after reboot?"),
the per-component docs under `docs/` are more detailed.*
