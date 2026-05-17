# Packer Rocky 9 template (abandoned approach)

The original plan was to build a Rocky 9.7 template with Packer
(`packer/rocky9-template.pkr.hcl`), then clone it via Terraform. That
approach was **abandoned** after ~12 iterations on this host — anaconda
kept landing in interactive TUI with various missing pieces.

The cluster is now built by cloning the manually-provisioned **vault-server**
VM via `terraform/clone-from-vault.sh` (see [vault-server.md](vault-server.md)).

This document preserves the packer-attempt history for reference.
Full historical detail (12 failed approaches) lives in
[`packer/TROUBLESHOOTING.md`](../packer/TROUBLESHOOTING.md).

---

## Why packer was abandoned

After fixing each layer of the kickstart delivery problem, a new one
popped up:

| # | Symptom | Fix tried | Outcome |
|---|---------|-----------|---------|
| 8 | `iso_checksum` stale after ISO refresh | recompute sha256 of `/tmp/Rocky-9.7-x86_64-minimal.iso` | unblocked |
| 9 | "not recommended media" warning blocks TUI | `inst.nomediacheck rd.live.check=0` | unblocked |
| 10 | OEMDRV kickstart auto-discovery fails when `inst.stage2=` is pinned | add `inst.ks=hd:LABEL=OEMDRV:/ks.cfg` | unblocked |
| 11 | TUI shows `[!] Installation source` — kickstart parsed but anaconda can't find packages | tried `cdrom`, `harddrive --partition=LABEL=...`, `inst.repo=hd:LABEL=...:/`, `inst.repo=hd:LABEL=...:/Minimal/` | all failed |

The fundamental issue at #11 appears to be that anaconda's `hd:LABEL=`
block source can't double-mount the install CD that's already providing
stage2. This is undocumented but consistent across our attempts.

---

## What the working packer config looked like (final state before abandonment)

`packer/rocky9-template.pkr.hcl` (HTTP/nc kickstart variant — the cleanest
of the failed approaches):

- `cd_label = "OEMDRV"` and `cd_content` were removed (single CD attached)
- Boot args:
  ```
  inst.text
  inst.stage2=cdrom
  ip=dhcp
  inst.ks=http://192.168.1.174:8080/ks.cfg
  inst.sshd
  inst.nomediacheck
  rd.live.check=0
  ```
- `build.sh` renders `http/ks.cfg` with `build_password` substituted,
  scps to ESXi `/tmp/ks.cfg`, runs an nc loop on ESXi:8080 that emits
  `HTTP/1.0 200 OK` + the kickstart content, then runs `packer build`.
- ESXi firewall disabled during build (re-enabled by trap on exit).

This config gets anaconda to a "failed to fetch kickstart" state. With
`ip=dhcp` and `inst.sshd` we never got further — the cluster was built
via vault-server clones instead.

---

## If you ever resurrect the packer path

1. The HCL + scripts are still committed (`packer/`); start from
   `packer/build.sh`.
2. Make sure `iso_checksum` matches `sha256sum /tmp/Rocky-9.7-x86_64-minimal.iso`.
3. ESXi `/tmp` must be clean (see [esxi-host.md](esxi-host.md) E2).
4. Before each retry: `pkill -INT -f "packer build"` locally AND clean
   ESXi-side nc loops:
   ```bash
   ssh root@192.168.1.174 \
     "for pid in \$(ps -c | awk '/nc -l 8080/{print \$1}'); do kill -9 \$pid; done; \
      rm -f /tmp/ks.cfg /tmp/nc.log; \
      esxcli network firewall set --enabled true"
   ```
5. The `inst.ks=http://...` URL must be typed correctly via VNC at
   anaconda boot. `boot_key_interval = "200ms"` is conservative; the URL
   is long — verify the args appear in `/proc/cmdline` (would require
   `inst.sshd` to ssh into anaconda).
6. Watch VNC. If TUI items 3 (Installation source) and 4 (Software
   selection) show `[!]`, you're stuck at the same place we were.

---

## What we learned that's still useful

- **Anaconda HTTP fetch needs `ip=dhcp`** to bring up networking in dracut
  before fetching the kickstart URL — otherwise "failed to fetch kickstart".
- **ESXi nc loop is the only reliable way to serve content from inside the
  same LAN to a fresh-booting VM.** Packer's built-in HTTP server is
  blocked by systemd's cgroup_skb BPF rules on Rocky 9 user sessions
  (Failed Approach #1 in `packer/TROUBLESHOOTING.md`).
- **`disk_adapter_type = "pvscsi"`** for Rocky 9 — `vmw_pvscsi` is in
  the initramfs unconditionally; `lsilogic` drops to dracut emergency
  on first boot because the kickstart `%post` chroot rebuilds initramfs
  in hostonly mode without the mptspi driver.
- **MBR partition layout** for BIOS-boot Rocky 9 on ESXi — `biosboot`
  partition with GPT causes dracut emergency.
