# HA nginx reverse proxy (2 containers on Ubuntu host)

Path-based reverse proxy that fronts the home-lab's k3s + homelab apps,
running as **two podman containers on `192.168.1.203` (Ubuntu 24.04)**.
Hosting the proxy off the loaded k3s box frees gdragon for the
monitoring + Vault workloads.

```
                                       ┌──────────────────────────────┐
  Browser / client (LAN)  ────►  :80  ─┤  192.168.1.203 (gdragon-ubuntu)
                          ────► :8080 ─┤
                                       │   ┌──────────┐  ┌──────────┐
                                       │   │ nginx-1  │  │ nginx-2  │   (podman, --restart=always)
                                       │   │ :80      │  │ :8080    │
                                       │   └──────────┘  └──────────┘
                                       │       │             │
                                       │       └──────┬──────┘
                                       │              │
                                       └──────────────│───────────────┘
                                                      ▼
                                       192.168.1.181:30300  (Grafana)
                                       192.168.1.181:30320  (Prometheus)
                                       192.168.1.181:30310  (Loki API)
                                       192.168.1.181:30200  (Vault)
                                       192.168.1.181:30401  (ArgoCD)
```

## HA model

- Both containers run the **same image** (`nginx-homelab-proxy:1.0`)
  with the same config baked in.
- `--restart=always` so each restarts on its own crash.
- Different host ports so they don't conflict. If `nginx-1` (`:80`)
  dies and podman can't restart it (image gone, OOM, etc.), users
  reach `:8080` (`nginx-2`).
- Real single-endpoint HA across both would need a VIP in front
  (keepalived) — single-box "HA" here means redundancy with a
  port flip.

Tested: stopping `nginx-1` → port 80 dies → `:8080` still serves →
restart `nginx-1` → port 80 recovers in ~2 s.

## Paths exposed

| Path | Backend | App needs to know it's at sub-path? |
|---|---|---|
| `/` | nginx-served HTML | n/a (landing page) |
| `/grafana/` | 192.168.1.181:30300 | **Yes** — set `grafana.ini` `server.root_url` + `serve_from_sub_path: true` |
| `/prometheus/` | 192.168.1.181:30320 | **Yes** — `--web.external-url=http://<host>/prometheus/ --web.route-prefix=/` |
| `/loki/` | 192.168.1.181:30310 | No (Loki has no UI, only API) |
| `/vault/` | 192.168.1.181:30200 | Mostly no — Vault honors X-Forwarded-* |
| `/argocd/` | 192.168.1.181:30401 | **Yes** — `--rootpath=/argocd` via `argocd-cmd-params-cm` |

The apps that need sub-path mode are **not yet configured** as of this
write-up; that's a TODO. Until then `/grafana/`, `/prometheus/`, and
`/argocd/` return 404. Once each is reconfigured, the proxy works
without further nginx changes.

## Files

```
nginx-proxy/
├── README.md           # this file
├── Dockerfile          # bakes nginx.conf into a self-contained image
├── nginx.conf          # the path-based vhost
├── install.sh          # podman-runs the 2 containers on .203
└── build-and-push.sh   # builds the image and pushes to quay.io
```

## Operate

```bash
# Initial setup or refresh after editing nginx.conf:
bash nginx-proxy/install.sh 192.168.1.203

# Build + push image to quay.io (one-time `sudo podman login quay.io` on .203 first):
bash nginx-proxy/build-and-push.sh quay.io/myhome-automation/nginx-homelab-proxy:1.0

# On the .203 host:
sudo podman ps                                       # see both nginx containers
sudo podman logs nginx-1 --tail 50                   # request logs
sudo podman restart nginx-1                          # bounce one
sudo podman exec nginx-1 nginx -t                    # validate config inside container
```
