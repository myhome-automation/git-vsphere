#!/usr/bin/env python3
# Add apiServer hardening to a kubeadm ClusterConfiguration YAML.
#
# Idempotent: re-running with the same input leaves the document unchanged
# apart from key ordering. Used by playbooks/k8s_harden.yml.
#
#   Usage: merge_cluster_config.py <input.yaml> <output.yaml>
#
# What it adds to apiServer:
#   extraArgs:
#     encryption-provider-config, audit-policy-file, audit-log-*,
#     admission-control-config-file
#   extraVolumes:
#     /etc/kubernetes/enc, /etc/kubernetes/audit, /var/log/kubernetes/audit
#
# kubeadm.k8s.io/v1beta4 (k8s 1.31+) uses list-of-{name,value} for
# extraArgs; v1beta3 and earlier used a map. Helper handles both shapes.

import sys
import yaml

EXTRA_ARGS = [
    ("encryption-provider-config", "/etc/kubernetes/enc/encryption.yaml"),
    ("audit-policy-file", "/etc/kubernetes/audit/policy.yaml"),
    ("audit-log-path", "/var/log/kubernetes/audit/audit.log"),
    ("audit-log-maxage", "30"),
    ("audit-log-maxbackup", "10"),
    ("audit-log-maxsize", "100"),
    ("admission-control-config-file", "/etc/kubernetes/admission/admission.yaml"),
]

EXTRA_VOLUMES = [
    {
        "name": "k8s-encryption",
        "hostPath": "/etc/kubernetes/enc",
        "mountPath": "/etc/kubernetes/enc",
        "readOnly": True,
        "pathType": "DirectoryOrCreate",
    },
    {
        "name": "k8s-audit-policy",
        "hostPath": "/etc/kubernetes/audit",
        "mountPath": "/etc/kubernetes/audit",
        "readOnly": True,
        "pathType": "DirectoryOrCreate",
    },
    {
        "name": "k8s-audit-log",
        "hostPath": "/var/log/kubernetes/audit",
        "mountPath": "/var/log/kubernetes/audit",
        "readOnly": False,
        "pathType": "DirectoryOrCreate",
    },
    {
        "name": "k8s-admission",
        "hostPath": "/etc/kubernetes/admission",
        "mountPath": "/etc/kubernetes/admission",
        "readOnly": True,
        "pathType": "DirectoryOrCreate",
    },
]


def upsert_args(extra_args, pairs, api_version):
    # kubeadm.k8s.io/v1beta4 (k8s 1.31+) REQUIRES list-of-{name,value};
    # the map form was removed. v1beta3 and earlier use a map. When
    # extraArgs is empty/None we have to pick the right shape based on
    # apiVersion, or kubeadm rejects the regenerated manifest.
    use_list = "v1beta4" in (api_version or "") or "v1beta5" in (api_version or "")
    if extra_args is None or (isinstance(extra_args, (dict, list)) and not extra_args):
        extra_args = [] if use_list else {}
    if isinstance(extra_args, list):
        index = {item.get("name"): item for item in extra_args}
        for k, v in pairs:
            if k in index:
                index[k]["value"] = v
            else:
                extra_args.append({"name": k, "value": v})
        return extra_args
    if isinstance(extra_args, dict):
        for k, v in pairs:
            extra_args[k] = v
        return extra_args
    sys.exit("ERROR: unexpected extraArgs type: %r" % type(extra_args))


def upsert_volumes(extra_volumes, volumes):
    if extra_volumes is None:
        extra_volumes = []
    existing = {v.get("name") for v in extra_volumes}
    for v in volumes:
        if v["name"] not in existing:
            extra_volumes.append(v)
    return extra_volumes


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: merge_cluster_config.py <input.yaml> <output.yaml>")
    src, dst = sys.argv[1], sys.argv[2]

    with open(src) as f:
        docs = list(yaml.safe_load_all(f))

    found = False
    for doc in docs:
        if not doc or doc.get("kind") != "ClusterConfiguration":
            continue
        api = doc.setdefault("apiServer", {}) or {}
        doc["apiServer"] = api
        api["extraArgs"] = upsert_args(api.get("extraArgs"), EXTRA_ARGS, doc.get("apiVersion"))
        api["extraVolumes"] = upsert_volumes(api.get("extraVolumes"), EXTRA_VOLUMES)
        found = True

    if not found:
        sys.exit("ERROR: no ClusterConfiguration document found in %s" % src)

    with open(dst, "w") as f:
        yaml.safe_dump_all(docs, f, default_flow_style=False, sort_keys=False)


if __name__ == "__main__":
    main()
