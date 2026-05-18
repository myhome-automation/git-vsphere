# drawio-dgr — Architecture diagrams (draw.io / diagrams.net)

Importable `.drawio` (mxfile) source for the home-lab architecture. Open
[https://app.diagrams.net/](https://app.diagrams.net/) (or any draw.io
desktop install / VS Code extension) and load `home-lab-architecture.drawio`.

## Files

| File | What |
|------|------|
| `home-lab-architecture.drawio` | Multi-page diagram. Each page is a separate perspective with its own color scheme. |

## Pages inside `home-lab-architecture.drawio`

| # | Page name | Perspective |
|---|-----------|-------------|
| 1 | Physical topology | Three physical hosts (ESXi 192.168.1.174, gdragon 192.168.1.181, gdragon-ubuntu 192.168.1.203) and the LAN they share. Color groups by host. |
| 2 | Cluster / namespace view | Side-by-side breakdown of `homelab` and `k3os-local` kubeconfig contexts and what lives in each namespace. Color groups by namespace role. |
| 3 | User request flow | Browser → nginx edge proxy → upstream NodePort → pod. One row per `location` block in `nginx-proxy/nginx.conf`. Color follows the app. |
| 4 | Monitoring data flow | `homelab` Prometheus + Promtail → `k3os-local` Prometheus + Loki → Grafana. Shows the cross-cluster `remote_write` and Promtail push streams. |
| 5 | Image / registry flow | Where every running container actually pulls its image from (quay.io, dockerhub, helm charts) and how our two custom repos (`quay.io/bpraisa/nginx`, `quay.io/bpraisa/vault`) get built and pushed. |
| 6 | Vault stack detail | StatefulSet → 3 pods → 3 Services (`vault`, `vault-active`, `vault-standby`). Highlights why `vault-active:31326` is the only NodePort to use, why `vault-1` stays CrashLoopBackOff (Calico IPPool overlap), and the unseal recovery loop. |

## Color conventions (consistent across pages)

- **Blue**     — kube-system / control-plane / management-plane pieces
- **Green**    — healthy / unsealed / leader-active components, also `k3os-local` and Loki
- **Yellow**   — monitoring stack (Grafana / Prometheus / metric path)
- **Orange**   — `homelab` cluster, workers, ESXi-hosted boxes
- **Red/Pink** — Vault and degraded / crash-looping things
- **Purple**   — edge / nginx proxy / image registry / external dependencies
- **Gray**     — neutral context (LAN, user browser, file references)

## Updating the diagram

1. Open the file in [draw.io](https://app.diagrams.net/) (or the VS Code
   "Draw.io Integration" extension).
2. Edit visually. Pages live in tabs along the bottom.
3. Save back to this path. The file is XML, so diffs in PRs are readable.
4. If the structure changes meaningfully, update this README's page table.

## Source of truth

These diagrams are derived from — and should always agree with — the text
docs:

- [`../docs/architecture.md`](../docs/architecture.md) — endpoint catalog,
  topology ASCII diagram, network-flow per cluster
- [`../docs/operations.md`](../docs/operations.md) — day-2 procedures
- [`../docs/deployment.md`](../docs/deployment.md) — zero-to-running runbook
- [`../CLAUDE.md`](../CLAUDE.md) — short orientation summary

If a diagram and a doc disagree, fix the diagram (the text is authoritative
for this repo).
