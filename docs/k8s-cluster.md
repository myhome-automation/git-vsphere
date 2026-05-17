# Kubernetes cluster — issues & fixes

Cluster topology: 3 masters (kmaster1-3) + 3 workers (kworker1-3) + single
loadbalancer (lb1). API VIP `192.168.1.50:6443`. Pod CIDR `10.244.0.0/16`
(Flannel). Version target: **k8s 1.36.1**.

---

## I1. `kubeadm init` fails with "unknown service runtime.v1.RuntimeService"

**Symptom (kmaster1):**
```
[preflight] Some fatal errors occurred:
  [ERROR CRI]: could not connect to the container runtime: failed to create
    new CRI runtime service: validate service connection: validate CRI v1
    runtime API for endpoint "unix:///var/run/containerd/containerd.sock":
    rpc error: code = Unimplemented desc = unknown service runtime.v1.RuntimeService
```

**Root cause:** Rocky 9's containerd RPM ships `/etc/containerd/config.toml`
with `disabled_plugins = ["cri"]`. The ansible task generating the default
config used `creates: /etc/containerd/config.toml` which silently skipped
overwriting the Rocky default — CRI never got enabled.

**Fix:** Always regenerate the config (no `creates:` guard). The
CRI-enabled output from `containerd config default` is what kubeadm needs.

```yaml
- name: generate default containerd config (CRI enabled)
  shell: containerd config default > /etc/containerd/config.toml
  notify: restart containerd
```

Then `SystemdCgroup = true` so kubelet's cgroup driver matches.

---

## I2. Verifying Kubernetes channel before bumping `k8s_version`

The repo URL is `https://pkgs.k8s.io/core:/stable:/v{{ k8s_version }}/rpm/`.
Channels exist per minor (v1.30, v1.31, ... v1.36). If you bump to a minor
that's not yet released, dnf will fail with 404s.

**Verify before bumping:**
```bash
curl -s https://dl.k8s.io/release/stable.txt
# -> v1.36.1   (as of 2026-05-16)

curl -sI https://pkgs.k8s.io/core:/stable:/v1.36/rpm/repodata/repomd.xml
# -> HTTP/2 302 (channel exists)
```

`k8s_version` is set in `ansible/group_vars/all/vars.yml`. Both
`k8s_master.yml` and `k8s_worker.yml` interpolate it into the
`/etc/yum.repos.d/kubernetes.repo` baseurl.

---

## I3. HA LB pair fronts the API VIP

`lb1` (MASTER, prio 101) and `lb2` (BACKUP, prio 100) own
`192.168.1.50` via keepalived; HAProxy on both fronts the k8s API on
6443 → kmaster1/2/3. kubeadm init was run with
`--control-plane-endpoint=192.168.1.50:6443` so etcd quorum,
kube-apiserver TLS SANs, and worker join all go through the VIP.

If lb1 dies, VRRP fails the VIP over to lb2 in ~3 s and the API stays
reachable. See [haproxy.md](haproxy.md) H2 for the failover test.

---

## I3a. firewalld blocks BGP / pod-to-pod after reboot

After every host reboot (or fresh deploy), `calico-node` pods come up
0/1 Ready and `calico-node -bird-ready` reports "BGP not established"
because firewalld on each k8s node drops Calico traffic before Calico's
iptables rules can apply.

`k8s_master.yml` and `k8s_worker.yml` now open BGP/Typha/VXLAN and trust
`pod_network_cidr` (10.0.0.0/16) in firewalld zone `trusted`. If a node
ever shows 0/1 calico-node after a reboot, run **only the firewall play**:

```bash
ansible-playbook ... playbooks/site.yml --tags k8s --start-at-task='open control-plane firewall ports'
```

Full details and ad-hoc one-liner fix in [calico.md](calico.md) section C1.

---

## I4. Flannel CNI

Master init plays `kubectl apply -f` on
`https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml`
after the first master init.

If pods stay in `ContainerCreating` after install, check:
```bash
kubectl -n kube-flannel get pods
kubectl -n kube-flannel logs <flannel-pod>
journalctl -u kubelet | tail -50
```

Common issues:
- `br_netfilter` module missing → check `lsmod | grep br_netfilter`,
  reload via `modprobe br_netfilter` (the base.yml task does this).
- `net.bridge.bridge-nf-call-iptables=0` → reset via the sysctl task.
- Pod CIDR mismatch → kubeadm init was given `--pod-network-cidr=10.244.0.0/16`,
  Flannel default expects `10.244.0.0/16` — confirm both match.

---

## I5. Joining additional masters / workers

The playbook handles joins automatically via delegated commands:

- **Master joins** (kmaster2/3): `serial: 1` so each joins fully before the
  next starts (avoids etcd quorum split during bootstrap). Uses a freshly
  generated cert-key via `kubeadm init phase upload-certs --upload-certs`
  on kmaster1.
- **Worker joins** (kworker1/2/3): runs `kubeadm token create
  --print-join-command` on kmaster1 (delegated), then executes on each
  worker. Idempotent via `stat: /etc/kubernetes/kubelet.conf` check.

To manually re-issue a join token (e.g. after the 2 h cert-key expires):
```bash
ssh ansible@<kmaster1>
sudo kubeadm token create --print-join-command
sudo kubeadm init phase upload-certs --upload-certs
```

---

## I6. Fetching kubeconfig to your workstation

```bash
scp -i /apps/git-code/keys/ansible-key ansible@192.168.1.186:/root/.kube/config ~/.kube/vsphere-cluster.config
# Edit ~/.kube/vsphere-cluster.config: server: https://192.168.1.186:6443 -> https://192.168.1.50:6443
export KUBECONFIG=~/.kube/vsphere-cluster.config
kubectl get nodes -o wide
```

The copy on kmaster1 has `server: https://192.168.1.50:6443` already since
the cluster was init'd with that endpoint, but verify.
