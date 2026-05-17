# Cross-cluster monitoring (Prometheus + Grafana + Loki)

Lightweight observability stack with the data/UI plane on the local
**k3os-local** cluster (runs on `gdragon`) and scrapers on both
clusters. Everything is reachable from the workstation at
`http://192.168.1.181`.

```
                ┌────────────────────────────────────────────┐
                │  workstation / gdragon (192.168.1.181)     │
                │  k3os-local (k3s)                          │
                │  ┌─────────────────────────────────────┐   │
                │  │  Grafana       :30300  (UI)         │   │
                │  │  Prometheus    :30320  (data + RW)  │   │
                │  │  Loki          :30310  (logs)       │   │
                │  │  + node-exporter / kube-state / promtail │
                │  └─────────────────────────────────────┘   │
                └────────────────┬───────────────────────────┘
                                 ▲  ▲
              remote_write       │  │  log push
              cluster=homelab    │  │  cluster=homelab
                                 │  │
                ┌────────────────┴──┴───────────────────────┐
                │  homelab (vsphere k8s, VIP 192.168.1.50)  │
                │  ┌─────────────────────────────────────┐  │
                │  │  Prometheus (no UI exposed)         │  │
                │  │    └─ remote_write → 30320          │  │
                │  │  Promtail DaemonSet                 │  │
                │  │    └─ push → 30310                  │  │
                │  │  node-exporter / kube-state-metrics │  │
                │  └─────────────────────────────────────┘  │
                └────────────────────────────────────────────┘
```

## URLs

| Component | URL | Default creds |
|---|---|---|
| Grafana | http://192.168.1.181:30300 | `admin` / `changeme-home-lab` |
| Prometheus | http://192.168.1.181:30320 | — |
| Loki API | http://192.168.1.181:30310 | — |

Inside Grafana, datasources `Prometheus` and `Loki` are auto-wired. The
homelab cluster shows up tagged with `cluster=homelab`; local data is
tagged `cluster=k3os-local` (logs always; metrics on local-only data
have no `cluster` label since Prometheus `external_labels` only stamp
data on egress — Grafana queries can use `{cluster=~"k3os-local|"}` to
match either-or-empty).

## Install / upgrade

### Local k3s side
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
  -n monitoring --create-namespace \
  -f monitoring/local-k3s/loki-stack-values.yaml
```

### Homelab side (push-only)
```bash
helm --kube-context homelab upgrade --install kps \
  prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f monitoring/homelab/kube-prometheus-stack-values.yaml

helm --kube-context homelab upgrade --install promtail \
  grafana/promtail \
  -n monitoring --create-namespace \
  -f monitoring/homelab/promtail-values.yaml
```

## Verification

```bash
# 1) Both clusters reporting `up` in local Prometheus
curl -sG --data-urlencode 'query=count(up) by (cluster)' \
  http://192.168.1.181:30320/api/v1/query | python3 -m json.tool

# 2) Both clusters in Loki
curl -s http://192.168.1.181:30310/loki/api/v1/label/cluster/values

# 3) Homelab Prometheus remote_write health (port-forward)
kubectl --context homelab -n monitoring port-forward svc/kps-prometheus 9090:9090
curl -s 'http://localhost:9090/metrics' | grep -E 'remote_storage_(samples_total|samples_failed|samples_dropped)'
```

## Gotchas hit during this build

1. **Clock skew breaks remote_write.** ESXi host had a 7-hour-off
   system time → VMware Tools propagated wrong time to homelab VMs at
   boot → `chrony` couldn't auto-step past the 1000s safety threshold
   → Prometheus `out of order sample` rejection at the local
   ingest endpoint. Instant queries returned empty even though
   `samples_total` was climbing.
   - Fix: `sudo chronyc makestep` on every homelab node forces an
     immediate step. Long-term: configure ESXi NTP (`/etc/init.d/ntpd`)
     and/or pin the VMs' chrony to a known-good upstream so they don't
     trust VMware Tools' boot-time set.

2. **metrics-server broken APIService blocks namespace deletion.**
   The pre-existing `v1beta1.metrics.k8s.io` APIService on local k3s
   was `MissingEndpoints`; namespace deletions hang on
   `NamespaceDeletionDiscoveryFailure`. Drop the broken APIService
   (`kubectl delete apiservice v1beta1.metrics.k8s.io`) before any
   `kubectl delete namespace`.

3. **Loki-stack default Promtail has no `cluster` label.** Use
   `extraArgs: -client.external-labels=cluster=<name>` per cluster so
   logs are joinable across clusters.

4. **kube-prometheus-stack on k3s** must turn off the
   `kubeControllerManager` / `kubeScheduler` / `kubeProxy` /
   `kubeEtcd` jobs — k3s collapses those into a single binary with no
   separate Services to scrape. Leaving them on gives 8+ permanent
   `DOWN` targets in the UI.

5. **Resource budget on a 5.8 GiB single-node k3s** — the values file
   under `monitoring/local-k3s/` is tuned for this; Prometheus retention
   is 7d, Loki 7d, both with 5-10 GiB PVCs on the k3s `local-path`
   storage class.

## File layout

```
monitoring/
├── README.md                                     # this file
├── local-k3s/
│   ├── kube-prometheus-stack-values.yaml         # Prom + Grafana + AM + node-exporter + kube-state
│   └── loki-stack-values.yaml                    # Loki + Promtail (with cluster=k3os-local label)
└── homelab/
    ├── kube-prometheus-stack-values.yaml         # Prom-only, remote_write to local
    └── promtail-values.yaml                      # Promtail DaemonSet -> local Loki
```
