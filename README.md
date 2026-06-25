# git-vsphere — home-lab platform (IaC)

Production-grade home lab on a single ESXi host: a CIS-hardened **kubeadm**
Kubernetes cluster (3 masters + 3 workers + HA load-balancer pair), a GitOps
platform (ArgoCD app-of-apps), and a separate **k3s** mgmt/security box
(**gdragon**) running AWX, OpenVAS, and the Vault transit auto-unseal backend.

> **The lab is shut down nightly and auto-recovers on boot.**
> Bring up: `scripts/platform-startup.sh` (auto-runs via `platform-startup.service`).
> Bring down: `scripts/platform-shutdown.sh`.

## Read order
1. [`arch.md`](arch.md) §0 — resume anchor / high-level plan & current state
2. [`HandOff.md`](HandOff.md) — live working state + lessons (mistakes & fixes)
3. [`docs/ACCESS.md`](docs/ACCESS.md) — **all apps, URLs, and how to get credentials**
4. [`docs/architecture.md`](docs/architecture.md) — current platform architecture
5. [`docs/cold-boot-resilience.md`](docs/cold-boot-resilience.md) — nightly-reboot design

## Repo layout
| Path | What |
|------|------|
| `ansible/` | Packer/Terraform-built cluster config: base, k8s master/worker, CIS hardening, DNS, LB, power up/down playbooks |
| `packer/` · `terraform/` | Golden image build + VM provisioning on ESXi |
| `gitops/` | ArgoCD app-of-apps: MetalLB, Longhorn, cert-manager, ingress-nginx, **Vault (HA, transit auto-unseal)**, Vault-Secrets-Operator, Consul, OPA Gatekeeper, kube-prometheus-stack, Jenkins |
| `gdragon/` | gdragon k3s: `awx/`, `openvas/`, `vault-transit/` (auto-unseal backend), `edge-203/` (system nginx vhosts) |
| `scripts/` | `platform-startup.sh` / `platform-shutdown.sh` + `platform-startup.service` |
| `docs/` | architecture, operations, deployment, cold-boot resilience, ACCESS |
| `drawio-dgr/` | architecture diagram (reference) |

## Conventions
- No secrets in git — credentials live in Kubernetes Secrets / `~/.vault/*.json` on
  gdragon; `docs/ACCESS.md` shows the live-retrieval commands.
- Conventional-commit messages; semantic version tags at milestones.
