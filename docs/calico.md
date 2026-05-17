# Calico — issues & fixes

Calico Tigera operator install on this cluster: pod CIDR `10.0.0.0/16`,
encapsulation `VXLANCrossSubnet` (all nodes share `192.168.1.0/24` so VXLAN
is not actually used between them — BGP routes pod traffic directly).

---

## C1. After reboot: `calico-node` is 0/1, "BGP not established"

**Symptom (after powerup or fresh deploy):**
```
kubectl -n calico-system get pod -l k8s-app=calico-node
# all 6 pods Running but 0/1 Ready

kubectl -n calico-system exec <calico-node-pod> -c calico-node -- \
  /bin/calico-node -felix-ready -bird-ready
# calico/node is not ready: BIRD is not ready: BGP not established with <peer-ips>
```

Cluster-wide knock-on effects:
- `kubectl get tigerastatus` → `calico` and `ippools` show Degraded.
- `kubectl get apiservices v3.projectcalico.org` → `False (FailedDiscoveryCheck)`.
- Istio sidecar / ingress can't reach `istiod.istio-system.svc` (DNS / pod
  network broken across nodes).

**Root cause:** firewalld on every k8s node blocks TCP/179 (BGP) and the
pod CIDR. Calico installs iptables/nftables rules for pod routing, but
firewalld's INPUT/FORWARD chains drop the traffic before Calico's chains
see it. The cluster was working before reboot only because Calico
happened to install its rules in a position firewalld tolerated; after a
fresh reboot ordering flips and firewalld wins.

**Fix (applied in `k8s_master.yml` and `k8s_worker.yml` since 2026-05-17):**

Trust the pod CIDR and open Calico's control ports on every k8s node:

```yaml
- name: trust pod CIDR ({{ pod_network_cidr }})
  firewalld:
    source: "{{ pod_network_cidr }}"
    zone: trusted
    state: enabled
    permanent: true
    immediate: true

- name: open Calico ports
  firewalld: { port: "{{ item }}", state: enabled, permanent: true, immediate: true }
  loop:
    - 179/tcp     # BGP between nodes
    - 5473/tcp    # Typha
    - 4789/udp    # VXLAN (cross-subnet; harmless to open same-subnet)
```

**One-shot fix on a live cluster (no playbook re-run needed):**
```bash
cd ansible/
ansible -i inventory/hosts.ini --vault-password-file=.vault_pass \
  'k8s_masters:k8s_workers' -b \
  -m firewalld -a 'source=10.0.0.0/16 zone=trusted state=enabled permanent=yes immediate=yes'

for port in 179/tcp 4789/udp 5473/tcp; do
  ansible -i inventory/hosts.ini --vault-password-file=.vault_pass \
    'k8s_masters:k8s_workers' -b \
    -m firewalld -a "port=$port state=enabled permanent=yes immediate=yes"
done
```

BGP re-establishes within ~30 s. `tigerastatus` calico flips Available
within another ~60 s.

---

## C2. `tigerastatus/ippools` stuck Degraded after C1 fixed

**Symptom:** Calico-node is healthy, BGP up, the APIService
`v3.projectcalico.org` reports Available=True. But:
```
kubectl get tigerastatus
# ippools                               True   <hours ago>
```

The condition's `lastTransitionTime` is from when the cluster was broken,
and `observedGeneration` matches the current `Installation.spec` generation
— the operator considers the status object current.

**Root cause:** the tigera-operator pod was running while the calico-apiserver
was unreachable, so it cached a "no API group projectcalico.org/v3" error in
its discovery client. When the APIService recovered, the operator's cached
discovery results did not auto-invalidate.

**Fix:** restart the operator AFTER the APIService is Available=True.

```bash
kubectl get apiservices v3.projectcalico.org   # confirm AVAILABLE=True first
kubectl -n tigera-operator rollout restart deployment/tigera-operator
```

If the status still doesn't refresh, also bounce calico-apiserver and
delete the stale status object (operator will recreate):
```bash
kubectl -n calico-apiserver rollout restart deployment/calico-apiserver
kubectl delete tigerastatus ippools
```

This is cosmetic — the underlying `IPPool` resource is fine and pods get
addresses from it. Verify with:
```bash
kubectl get ippools.crd.projectcalico.org -o wide
kubectl get pods -A -o wide | head      # pod IPs should be in pod CIDR
```

---

## C3. Pod-network sanity tests

When suspecting Calico, run these in order:

```bash
# BGP / readiness probe (manual)
POD=$(kubectl -n calico-system get pod -l k8s-app=calico-node -o name | head -1)
kubectl -n calico-system exec $POD -c calico-node -- \
  /bin/calico-node -felix-ready -bird-ready
# Expected: nothing printed; exit 0. Errors mention "BGP not established"
# or "Felix is not ready".

# DNS works pod -> CoreDNS -> ClusterIP service
kubectl run dnstest --rm -i --restart=Never --image=busybox:1.36 -- \
  nslookup kubernetes.default.svc.cluster.local
# Expected: Address: 10.96.0.1

# Aggregated API discovery
kubectl get apiservices v3.projectcalico.org
# Expected: AVAILABLE=True

# IPPool exists and matches pod_network_cidr
kubectl get ippools.crd.projectcalico.org default-ipv4-ippool -o yaml | grep cidr:
# Expected: cidr: 10.0.0.0/16  (or whatever pod_network_cidr is set to)
```

---

## C4. CIDR mismatch ⇒ Tigera install fails entirely

The Tigera operator strictly enforces:
```
spec.calicoNetwork.ipPools[].cidr == kubeadm --pod-network-cidr
```

When they disagree, the operator refuses to install and `tigerastatus
calico` stays Available=False / Progressing=True forever.

Three places that must match:
1. `ansible/group_vars/all/vars.yml` → `pod_network_cidr`
2. `ansible/playbooks/cni_calico.yml` → `pod_cidr` task var
3. The actual `kubeadm init --pod-network-cidr=...` flag (driven by #1
   in `k8s_master.yml`)

CIDR cannot be changed in place. Procedure to change:
1. Edit #1 and #2.
2. `ansible-playbook playbooks/k8s_reset.yml`
3. `ansible-playbook playbooks/site.yml --tags k8s,calico,istio`

See [operations.md](operations.md) "Change pod CIDR".
