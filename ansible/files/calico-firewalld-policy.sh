#!/bin/bash
# calico-firewalld-policy.sh POD_CIDR
#
# firewalld with the nftables backend DROPS forwarded host->pod packets. The
# k8s playbooks add the pod CIDR to the `trusted` zone, but firewalld zones
# match by SOURCE only, so they cover pod-sourced traffic (pod->anywhere) and
# NOT the host->pod direction (source = node IP). Forwarded (inter-zone)
# traffic in firewalld is governed by POLICIES, not zones. Without this policy,
# after any firewalld reload (e.g. a NetworkManager reapply or a reboot)
# kube-apiserver->pod (aggregated APIs like projectcalico.org/v3, admission
# webhooks) and node->pod connections fail with "no route to host", which in
# turn wedges namespace deletion on a FailedDiscoveryCheck. See docs/calico.md.
#
# Idempotent: prints CHANGED and reloads firewalld only when it had to act,
# otherwise prints UNCHANGED and leaves firewalld alone.
set -euo pipefail
POD_CIDR="${1:-10.0.0.0/16}"
POLICY="calico-fwd"
RR_SRC="rule family=\"ipv4\" source address=\"${POD_CIDR}\" accept"
RR_DST="rule family=\"ipv4\" destination address=\"${POD_CIDR}\" accept"

want_ok() {
  firewall-cmd --permanent --get-policies | tr ' ' '\n' | grep -qx "$POLICY" || return 1
  [ "$(firewall-cmd --permanent --policy "$POLICY" --get-target 2>/dev/null)" ] || true
  firewall-cmd --permanent --policy "$POLICY" --query-ingress-zone ANY >/dev/null 2>&1 || return 1
  firewall-cmd --permanent --policy "$POLICY" --query-egress-zone ANY >/dev/null 2>&1 || return 1
  firewall-cmd --permanent --policy "$POLICY" --query-rich-rule="$RR_SRC" >/dev/null 2>&1 || return 1
  firewall-cmd --permanent --policy "$POLICY" --query-rich-rule="$RR_DST" >/dev/null 2>&1 || return 1
  return 0
}

if want_ok; then
  echo "POLICY_OK"
  exit 0
fi

# (Re)build the policy from scratch so it is always in the desired state.
firewall-cmd --permanent --delete-policy "$POLICY" 2>/dev/null || true
firewall-cmd --permanent --new-policy "$POLICY"
firewall-cmd --permanent --policy "$POLICY" --add-ingress-zone ANY
firewall-cmd --permanent --policy "$POLICY" --add-egress-zone ANY
firewall-cmd --permanent --policy "$POLICY" --add-rich-rule="$RR_SRC"
firewall-cmd --permanent --policy "$POLICY" --add-rich-rule="$RR_DST"
firewall-cmd --reload
echo "POLICY_CHANGED"
