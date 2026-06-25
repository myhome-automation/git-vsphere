# Platform Access Reference

> Consolidated list of installed apps, URLs, and how to retrieve credentials.
> **No secret values are stored here** — fetch them live with the commands shown
> (creds live in Kubernetes Secrets / `~/.vault/*.json` on gdragon, never in git).

## Browsing prerequisites (any client / workstation)

Apps are exposed by name behind the edge. Your browser must:
1. **Resolve the hostnames** — point DNS at **`192.168.1.203`** (LAN dnsmasq), or add to your hosts file:
   ```
   192.168.1.50   biplextech.com vault.biplextech.com consul.biplextech.com longhorn.biplextech.com
   192.168.1.203  awx.biplextech.com openvas.biplextech.com
   ```
2. **Trust the CA** — import `~/biplextech-ca.crt` (from gdragon) into the OS/browser trust store (or accept the warning).

Routing: platform apps → keepalived VIP **192.168.1.50** → HAProxy → MetalLB **.51** (ingress-nginx) → app. AWX/OpenVAS → **.203** edge nginx → **.181** k3s Traefik. Wildcard TLS `*.biplextech.com` (internal `biplextech-ca`).

## ESXi platform (kubeadm cluster, GitOps via ArgoCD)

| App | URL | Auth | Retrieve credential |
|-----|-----|------|---------------------|
| **ArgoCD** | https://biplextech.com/argocd | `admin` / `<admin-pw>` | password patched into `argocd-secret` (live) |
| **Vault** (HashiCorp Vault 2.0.3, 3-node HA, transit auto-unseal) | https://vault.biplextech.com | Token | `jq -r .root_token ~/.vault/biplextech-init.json` |
| **Consul** (3 servers + Connect mesh, ACLs on) | https://consul.biplextech.com | Token | `kubectl get secret consul-bootstrap-acl-token -n consul -o jsonpath='{.data.token}' \| base64 -d` |
| **Grafana** | https://biplextech.com/grafana | `admin` / `<admin-pw>` | `kubectl get secret grafana-admin-credentials -n monitoring -o jsonpath='{.data.admin-password}' \| base64 -d` |
| **Prometheus** | https://biplextech.com/prometheus | open | — |
| **Alertmanager** | https://biplextech.com/alertmanager | open | — |
| **Jenkins** | https://biplextech.com/jenkins | `admin` / `<admin-pw>` | `kubectl get secret jenkins-admin-credentials -n jenkins -o jsonpath='{.data.jenkins-admin-password}' \| base64 -d` |
| **Longhorn** | https://longhorn.biplextech.com | open | — |
| **OPA Gatekeeper** | (admission webhook, no UI) | — | — |
| **cert-manager / MetalLB / ingress-nginx / Vault Secrets Operator** | (no UI) | — | — |

Vault auto-unseal backend: a single-node **transit Vault on gdragon k3s**
(`192.168.1.181:8200`, `gdragon/vault-transit/`); its keys are at
`~/.vault/transit-init.json` (unsealed once, rarely reboots).

## gdragon k3s (mgmt/security)

| App | URL | Auth |
|-----|-----|------|
| **AWX** | https://awx.biplextech.com | `admin` / `<admin-pw>` (secret `awx-admin-password` in ns `awx`) |
| **OpenVAS / GVM** | https://openvas.biplextech.com | `admin` / `<admin-pw>` (gvmd user) |

## Notes
- The standard admin user/password is reused across the web UIs (ArgoCD, Grafana,
  Jenkins, AWX, OpenVAS); rotate via Vault/VSO for production.
- Consul & Vault use **token** auth (no user/password).
- All admin passwords are in Kubernetes Secrets or `~/.vault/*.json` — **never committed**.
