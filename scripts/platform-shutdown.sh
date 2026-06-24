#!/usr/bin/env bash
# platform-shutdown.sh — bring the home lab DOWN gracefully, in REVERSE
# dependency order. Run from gdragon (the Ansible control host).
#
# Reverse of startup:
#   1. Workers       kworker3/2/1   (workloads drain as nodes stop)
#   2. Control plane kmaster3/2/1
#   3. Load balancers lb2 .185 -> lb1 .188
#   4. DNS           vault-server .202 (last — others may resolve via it)
#
# Vault seals itself automatically when its pods stop — re-unseal on next boot
# (platform-startup.sh step 7). Stateful data is on Longhorn PVCs (Retain).
# gdragon k3s (AWX/OpenVAS) + edge nginx .203 run on separate hosts; shut those
# down with their own host if desired (they auto-start on boot).
set -uo pipefail

REPO=/apps/git-code/git-vsphere
ANS="$REPO/ansible"

echo "== Graceful power-off of the 9 ESXi VMs (workers -> masters -> lb -> DNS) =="
# all_shutdown.yml issues guest shutdown via ESXi vim-cmd in reverse order and
# waits for power-off. vault-server (DNS) goes last.
cd "$ANS"
ANSIBLE_CONFIG="$PWD/ansible.cfg" ansible-playbook playbooks/all_shutdown.yml

echo
echo "SHUTDOWN COMPLETE. To also stop the mgmt tier, power off gdragon (.181)"
echo "and gdragon-edge (.203) — both auto-start their services (k3s / nginx)."
