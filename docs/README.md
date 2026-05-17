# Troubleshooting Index

Per-component issue logs from building this home-lab Kubernetes cluster on
ESXi 6.7. Each file is self-contained — read only the one for the component
you're debugging.

| File | Covers |
|------|--------|
| **[architecture.md](architecture.md)** | **Full system architecture: hardware, network, k8s layer, CIDRs, build pipeline** |
| [k8s-cluster.md](k8s-cluster.md) | kubeadm preflight, containerd CRI, flannel, k8s repo channel, single-LB API VIP |
| [calico.md](calico.md) | Calico/Tigera operator, firewalld blocking BGP, ippools stale-status, CIDR coupling |
| [vault-server.md](vault-server.md) | vault-server as clone source, vmkfstools clone pitfalls, NFC leases, ovftool task locks |
| [haproxy.md](haproxy.md) | HAProxy on Rocky 9: SELinux bind, single-LB keepalived, interface auto-detect |
| [dns.md](dns.md) | dnsmasq on lb1 for `myhomelab.com`, addn-hosts placement, NM resolver overrides |
| [ansible.md](ansible.md) | `group_vars/` location, vault password, inventory groups, busybox vs bash on ESXi |
| [esxi-host.md](esxi-host.md) | ESXi 6.7 quirks: scp/sftp bugs, /tmp ramdisk, MAC OUI rules, memory ceiling |
| [packer.md](packer.md) | Packer Rocky 9 template attempts (abandoned approach) — kickstart delivery, ISO checksum, anaconda TUI |
| [operations.md](operations.md) | Day-to-day ops: shutdown / power on, reset cluster, change pod CIDR |

## Current architecture

- **vault-server** (192.168.1.202) — Rocky 9.7, manually built, used as the clone template
- **8 cluster VMs** cloned from vault-server via `terraform/clone-from-vault.sh` (vmkfstools)
- **k8s 1.36.1** via ansible playbooks under `ansible/playbooks/`
- **Internal DNS** (myhomelab.com) served by dnsmasq on lb1

See [project memory](../../../home/bstha/.claude/projects/-apps-git-code-git-vsphere/memory/project_vsphere_k8s.md)
(local-only) for the current build state.
