#!/usr/bin/env bash
# platform-shutdown.sh — bring the home lab DOWN gracefully, in REVERSE
# dependency order. Run from gdragon. Use for the nightly shutdown.
#
# ── Reverse order ─────────────────────────────────────────────────────────────
#   1. Stateful apps:  Vault seals automatically when pods stop; Longhorn PVCs
#      are Retain so data persists. Nothing to do manually.
#   2. ESXi cluster VMs:  kworker3/2/1 -> kmaster3/2/1 -> lb2 -> lb1
#      (cluster_shutdown.yml — vault-server/.202 is decommissioned, not touched).
#   3. gdragon k3s + edge .203:  leave running, OR power off their hosts last
#      (k3s/nginx/dnsmasq + the transit Vault auto-start on boot).
#
# On the next boot run scripts/platform-startup.sh — it unseals the gdragon
# transit Vault, powers the cluster on, and the cluster Vault AUTO-unseals.
set -uo pipefail

REPO=/apps/git-code/git-vsphere
ANS="$REPO/ansible"

echo "== Graceful power-off of the 8 cluster VMs (workers -> masters -> lb) =="
# cluster_shutdown.yml issues guest shutdown via ESXi vim-cmd in reverse order
# and waits for power-off. Leaves the decommissioned vault-server (.202) alone.
cd "$ANS"
ANSIBLE_CONFIG="$PWD/ansible.cfg" ansible-playbook playbooks/cluster_shutdown.yml

echo
echo "CLUSTER DOWN. The mgmt tier (gdragon k3s: AWX/OpenVAS/transit-Vault, and"
echo "edge .203: nginx/dnsmasq) keeps running. To shut those too, power off the"
echo "gdragon (.181) and gdragon-edge (.203) hosts — services auto-start on boot."
echo "Next boot: run scripts/platform-startup.sh (Vault auto-unseals via transit)."
