#!/usr/bin/env python3
# Apply hardening fields to /var/lib/kubelet/config.yaml.
# Idempotent. Prints "changed" or "unchanged" to stdout so the calling
# playbook can decide whether to restart kubelet.
#
#   Usage: patch_kubelet_config.py <path>
#
# Sets:
#   readOnlyPort: 0                  (disables unauthenticated :10255)
#   protectKernelDefaults: true      (kubelet asserts host sysctls match)
#   eventRecordQPS: 5                (cap event spam from a runaway pod)
#   tlsCipherSuites: <safe modern list>

import sys
import yaml

SAFE_CIPHERS = [
    "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384",
    "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384",
    "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256",
    "TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256",
    "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256",
    "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256",
]

DESIRED = {
    "readOnlyPort": 0,
    "protectKernelDefaults": True,
    "eventRecordQPS": 5,
    "tlsCipherSuites": SAFE_CIPHERS,
}


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: patch_kubelet_config.py <path>")
    path = sys.argv[1]

    with open(path) as f:
        cfg = yaml.safe_load(f) or {}

    before = yaml.safe_dump(cfg, sort_keys=True)
    for k, v in DESIRED.items():
        cfg[k] = v
    after = yaml.safe_dump(cfg, sort_keys=True)

    if before == after:
        print("unchanged")
        return

    with open(path, "w") as f:
        yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False)
    print("changed")


if __name__ == "__main__":
    main()
