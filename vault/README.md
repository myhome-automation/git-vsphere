# HashiCorp Vault on the local k3s

Production-shape Vault deployment (3-replica Raft HA target), running
on the local k3s cluster (`k3os-local`, host `gdragon` 192.168.1.181).
Reachable at `http://192.168.1.181:30200` and (when nginx proxy is
configured for sub-path) at `http://192.168.1.203/vault/`.

Deployed via ArgoCD — see `argocd/vault.yaml`.

## Current state (2026-05-17)

- `vault-0`: **leader**, initialized, unsealed, Raft state-machine working.
  - KV-v2 secrets engine enabled at `secret/`.
  - AppRole auth enabled at `approle/`.
- `vault-1`, `vault-2`: **pods running, sealed, not joined to Raft yet**.
  Pod-to-pod traffic between them and `vault-0` is failing with "no route
  to host" — same Calico/IPPool overlap that bit pod→DNS earlier
  (192.168.0.0/16 IPPool collides with the home network). The
  workstation-level fix (`k3s-pod-masq.service`) handles
  pod-to-external, but pod-to-pod for vault-internal needs a separate
  Calico IPPool migration.
- TODO: migrate Calico IPPool off `192.168.0.0/16` (proposed
  `10.42.0.0/16` — k3s default — non-overlapping), then redo Raft join.

## Unseal keys + root token

Stored at `~/.vault/init.json` on the workstation (chmod 600). Move
these to your password manager and remove the file from disk afterward.
Never commit them to git.

Vault is initialized with **5 unseal-key shares, threshold 3**.

## URLs

| URL | Use |
|---|---|
| `http://192.168.1.181:30200/ui/` | Vault UI |
| `http://192.168.1.181:30200/v1/` | Vault HTTP API |
| (future) `http://192.168.1.203/vault/` | through nginx proxy on .203 |

## Re-unseal procedure (after pod restart or cluster restart)

Vault on Raft requires manual unseal of every replica on each boot.
The unseal keys live in `~/.vault/init.json` on the workstation:

```bash
ROOT=$(jq -r .root_token ~/.vault/init.json)
for r in vault-0 vault-1 vault-2; do
  jq -r '.unseal_keys_b64[:3][]' ~/.vault/init.json | while read key; do
    kubectl --context k3os-local -n vault exec $r -- vault operator unseal "$key"
  done
done
```

Once vault-1/vault-2 raft-join is fixed, automate this via Vault auto-unseal
(transit auth from a 4th Vault, or a cloud KMS) — out of scope for home lab.

## Enabling KV + AppRole again from scratch

If you ever destroy and rebuild Vault:

```bash
ROOT="<root-token-from-init.json>"
kubectl --context k3os-local -n vault exec vault-0 -- /bin/sh -c \
  "VAULT_TOKEN=$ROOT vault secrets enable -path=secret kv-v2"
kubectl --context k3os-local -n vault exec vault-0 -- /bin/sh -c \
  "VAULT_TOKEN=$ROOT vault auth enable approle"
```

## Files

```
vault/
├── README.md            # this file
└── values.yaml          # helm values mirror (canonical is argocd/vault.yaml)
argocd/
└── vault.yaml           # ArgoCD Application: deploys vault helm chart
```
