# Packer Rocky9 Template Build — Troubleshooting Guide

## Environment

| Item | Value |
|------|-------|
| ESXi host | 192.168.1.174 (HP Z620, ESXi 6.7.0 build-8169922) |
| Packer machine | 192.168.1.181 (VMware VM running Rocky Linux) |
| ISO | Local: `/tmp/Rocky-9.7-x86_64-minimal.iso`, cached on `[datastore2] iso-image/` |
| Packer plugin | hashicorp/vmware `~> 1.0` (pinned at v1.2.0) |
| Packer binary | `/usr/bin/packer` v1.15.3 |
| Build script | `packer/build.sh` |
| Kickstart delivery | **OEMDRV virtual CD** (`cd_content` in HCL), not HTTP |
| ISO label | `Rocky-9-7-x86_64-dvd` (verified via `file` command on the ISO) |

---

## Current State (2026-05-16, session 2)

The build approach has migrated from HTTP/nc kickstart to **OEMDRV CD delivery**.
Today's session uncovered three new failure modes; the boot_command has been
hardened iteratively. Latest known-good boot_command:

```hcl
boot_command = [
  "<tab><wait3>",
  " inst.text",
  "<wait>",
  " inst.stage2=hd:LABEL=Rocky-9-7-x86_64-dvd",
  "<wait>",
  " inst.ks=hd:LABEL=OEMDRV:/ks.cfg",
  "<wait>",
  " inst.nomediacheck rd.live.check=0",
  "<enter><wait>"
]
```

**Latest test in progress (background bash id may change)**: anaconda boots, kickstart
applied via explicit `inst.ks=hd:LABEL=OEMDRV:/ks.cfg`, install runs non-interactively.
Verify by watching VNC for anaconda package-install progress; success ends with packer
running the seal provisioner and shutting down the VM.

**Next action if interrupted**: re-run `bash build.sh` from `packer/` directory.
If it lands on the same anaconda TUI menu again, see Failed Approach #10 below.

---

## How to Run the Build

```bash
cd /apps/git-code/git-vsphere/packer
bash build.sh
```

`build.sh` (current OEMDRV flow) does:
1. Verifies `packer.pkrvars.hcl` exists (passwords)
2. Touches a zero-byte ISO placeholder at `/tmp/Rocky-9.7-x86_64-minimal.iso` if missing
   (the actual ISO is on ESXi `[datastore2] iso-image/`)
3. Runs `packer build -var-file=packer.pkrvars.hcl .`

Packer flow:
1. Verifies local ISO checksum (`iso_checksum` in HCL must match the local file's SHA256)
2. Uploads ISO to ESXi (if not already in `remote_cache_datastore`)
3. Creates a second mini-ISO with `cd_content = { "/ks.cfg" = templatefile(...) }`
   and `cd_label = "OEMDRV"`
4. Boots the VM, types boot_command over VNC-over-websocket
5. Anaconda reads `inst.ks=hd:LABEL=OEMDRV:/ks.cfg` from the second CD
6. After reboot, packer SSHes in as `ansible` and runs the seal provisioner

## How to Clean Up a Failed Build

```bash
# Kill any running packer / build.sh processes locally
pkill -INT -f "packer build"

# Find and destroy half-built VM on ESXi
ssh root@192.168.1.174 "vim-cmd vmsvc/getallvms"
# Note the VMID for rocky9-template, then:
ssh root@192.168.1.174 "vim-cmd vmsvc/power.off <VMID>"
ssh root@192.168.1.174 "vim-cmd vmsvc/unregister <VMID>"
ssh root@192.168.1.174 "rm -rf /vmfs/volumes/datastore1/rocky9-template"
```

`SIGINT` lets packer run its own cleanup (delete VM, remove temp files) — preferred
over `pkill -9`. After SIGINT, the VM directory on ESXi may still contain a stale
`disk-flat.vmdk` and `vmware.log` from the previous run; remove with the `rm -rf` above.

---

## Failed Approaches (Do Not Retry)

### 1. Packer's built-in HTTP server (`http_directory`)

**What we tried:** Let Packer serve ks.cfg on its own HTTP server (default behavior, port 8100–8110).

**Why it fails:** The packer machine at 192.168.1.181 runs as a non-root user inside a systemd user session. Systemd attaches `cgroup_skb` BPF programs (`sd_fw_ingress`) to the user session cgroup. These BPF programs drop inbound TCP SYN packets **before iptables sees them**. Adding firewall rules has zero effect — iptables counters stay at 0 while connections are dropped.

Confirmed with:
```bash
tcpdump -i ens33 -n 'tcp and port 8100'    # shows SYN from ESXi
iptables -L INPUT -n -v | grep 8100         # counter stays at 0
```

Even `sudo python3 -m http.server` is affected because `sudo` inherits the cgroup of the calling user process.

**Fix (historical):** Serve kickstart FROM ESXi itself (nc server on ESXi at 192.168.1.174:8080).
**Current fix:** Drop HTTP entirely — use OEMDRV virtual CD (`cd_content` in HCL).

---

### 2. Floppy delivery (`floppy_content` / `inst.ks=floppy:/ks.cfg`)

**What we tried:** Used Packer's `floppy_content` to inject ks.cfg onto a virtual floppy, then booted with `inst.ks=floppy:/ks.cfg`.

**Why it fails:** Rocky 9.x installer initramfs does not include the `floppy` kernel module. The installer cannot mount the floppy device. Adding `rd.driver.pre=floppy` to the boot line also fails — module simply isn't present.

Error seen: `kickstart file /run/install/ks.cfg is missing` then `pane is dead (status 1)`.

**Fix:** OEMDRV CD (see current HCL).

---

### 3. GRUB2 boot command syntax

**What we tried (wrong):** Boot command using GRUB2 syntax (`<e>` to edit, GRUB2 `linux` line editing).

**Why it fails:** Rocky 9.x minimal ISO on this hardware boots in **BIOS mode using ISOLINUX**, not GRUB2. The console shows:
```
Press Tab for full configuration options
```

ISOLINUX key behavior:
- `<up>` — wraps from item 1 (Install) to LAST item (Troubleshooting). **Never use `<up>`.**
- `<tab>` — appends to the current boot line of the selected entry
- `<enter>` — boots

---

### 4. GPT partition with `biosboot` partition

**What we tried:** Added `part biosboot --fstype=biosboot --size=1` to ks.cfg for GPT layout.

**Why it fails:** ESXi 6.7 VMs created in BIOS mode (no UEFI) with pvscsi or lsilogic — the biosboot partition caused dracut emergency shell on boot.

**Fix:** Use MBR partition layout (no biosboot partition, `--location=mbr` on bootloader directive).

---

### 5. `http_ip` parameter

**What we tried:** Adding `http_ip = "192.168.1.181"` to force Packer's HTTP server IP.

**Why it fails:** The `http_ip` parameter does not exist in hashicorp/vmware plugin v1.2.0. Packer parse error: `An argument named "http_ip" is not expected here`.

---

### 6. `lsilogic` disk adapter → dracut emergency mode after install

**What we tried:** `disk_adapter_type = "lsilogic"`.

**Why it fails:** Rocky 9.x installs fine with lsilogic (mptspi driver is in anaconda initrd), but the
*installed system* drops to dracut emergency mode on first boot. The kickstart `%post` chroot
environment disables hardware detection, so dracut's hostonly mode never includes the mptspi driver
in the generated initramfs.

**Current fix:** `disk_adapter_type = "pvscsi"` (VMware vmw_pvscsi is unconditionally in every Rocky/RHEL 9 initramfs). Plus `dracut --force --no-hostonly` in %post for extra insurance.

---

### 7. `logvol / --size=1`

**What we tried:** `logvol / --fstype=xfs --size=1 --grow`

**Why it fails:** Anaconda's storage validation requires a minimum real size for the root logical volume. A `--size=1` (1 MB) specification is rejected even with `--grow`.

**Fix:** `logvol / --fstype=xfs --size=8192 --grow`

---

### 8. **(2026-05-16)** Stale `iso_checksum` in HCL after ISO refresh

**What we tried:** Kept old `iso_checksum = "sha256:23a1ac1175d8..."` after a new copy of the ISO was placed at `/tmp/Rocky-9.7-x86_64-minimal.iso`.

**What we saw:**
```
Checksum did not match, removing /home/bstha/.cache/packer/...iso
Expected: 23a1ac1175d8ccada7195863914ef1237f584ff25f73bd53da410d5fffd882b0
Got:      06b9e67a1ad7a992927022442837fa683fa846f9540d55090c84c4b2f31dc357
==> error downloading ISO: *sha256.digest
```

Build errors out in 12 seconds — never even powers a VM on.

**Fix:** Compute the local file's actual SHA256 with `sha256sum /tmp/Rocky-9.7-x86_64-minimal.iso`
and paste that into `iso_checksum` in `rocky9-template.pkr.hcl`. Current canonical value:
```
iso_checksum = "sha256:06b9e67a1ad7a992927022442837fa683fa846f9540d55090c84c4b2f31dc357"
```

The local ISO is intact (size 2,543,628,288 bytes, label `Rocky-9-7-x86_64-dvd`, stage2
at `/images/install.img` is 1,163,980,800 bytes and reads end-to-end cleanly).

---

### 9. **(2026-05-16)** Anaconda blocks on "It is not recommended to use this media" warning

**What we tried:** Booted with just `inst.text inst.stage2=cdrom` — no media-check bypass.

**What we saw on VNC:**
```
It is not recommended to use this media before installing
failed to start Media check on /dev/sr0
```
Followed by either the TUI warning prompt blocking on `[Continue]`, or anaconda dropping
through to an interactive text-mode summary menu (Failed Approach #10).

Packer hangs at "Waiting for SSH to become available..." for the full ssh_timeout
(30 min) before giving up.

**Root cause:** With two CDs attached (install ISO + OEMDRV ks CD), the systemd
`media-check@sr0.service` fails to verify the install media. Anaconda then shows a
non-recommended-media warning that, in dual-CD mode, waits for human confirmation.

**Fix:** Add to boot_command:
- `inst.nomediacheck` — skip anaconda's recommendation prompt
- `rd.live.check=0` — disable dracut-side media verification

---

### 10. **(2026-05-16)** OEMDRV kickstart auto-discovery fails when `inst.stage2=` is pinned

**What we tried:** `inst.text inst.stage2=hd:LABEL=Rocky-9-7-x86_64-dvd inst.nomediacheck rd.live.check=0`

**What we saw on VNC:**
```
==== Installation Summary ====
1) [x] Language settings  (English)
2) [x] Time settings      (Americas/Chicago)
3) [!] Installation source (...)
...

Please make your choice from above ['q' to quit | 'b' to begin installation | 'r' to refresh]:
```

Anaconda booted cleanly but landed in **interactive text-mode**. Kickstart was never applied.

**Root cause:** Anaconda's automatic OEMDRV CD discovery is conditional — when
`inst.stage2=hd:LABEL=...` is set, anaconda treats the install source as fixed and skips
scanning for OEMDRV. The `cd_label = "OEMDRV"` in the HCL does create a labeled CD, but
auto-discovery needs to actually run for it to be used.

**Fix:** Pin the kickstart path explicitly too:
```
inst.ks=hd:LABEL=OEMDRV:/ks.cfg
```

This bypasses auto-discovery and tells anaconda exactly where to find ks.cfg.

If you ever see the interactive TUI menu again with kickstart NOT applied, this is the
boot arg that's missing.

(If the TUI appears WITH kickstart settings partially applied — e.g. lang+time correct
but `[!]` on Installation source — see Failed Approach #11 instead.)

---

### 11. **(2026-05-16)** ks.cfg missing install source directive → anaconda TUI

**What we tried:** ks.cfg with all settings (lang, partitioning, packages, network, %post)
EXCEPT a top-level install-source directive (`cdrom` / `url` / `harddrive` / `nfs`).

**What we saw on VNC** even with `inst.ks=hd:LABEL=OEMDRV:/ks.cfg` correctly wired up:
```
==== Installation Summary ====
1) [x] Language settings        (English)
2) [x] Time settings            (Americas/Chicago)
3) [!] Installation source      <-- anaconda doesn't know where to read packages from
4) [!] Software selection
...

Please make your choice from above ['q' to quit | 'b' to begin installation | 'r' to refresh]:
```

The anaconda TUI shows lang+time pulled from ks.cfg, but `[!]` markers on the items
anaconda couldn't auto-resolve. Without an install source, software selection and
partitioning can't proceed — TUI blocks for human input.

This is **distinct from Failed Approach #10** — there, the kickstart wasn't being read
at all. Here, the kickstart IS being read (else lang/time wouldn't show), but it's
incomplete.

**Root cause:** `inst.stage2=hd:LABEL=...` on the boot line only tells anaconda where
to find the *installer runtime* (stage2 squashfs/img). It does NOT set the *package
repository*. Anaconda needs a kickstart directive (`cdrom`, `url`, etc.) or a fallback
discovery to find the actual rpm tree.

**Fix attempt #1 (didn't work):** Add `cdrom` at the top of ks.cfg.

**Why it didn't work:** Anaconda's `cdrom` source picks the CD it just read ks.cfg from
(the OEMDRV CD, /dev/sr1), which has no repodata. Anaconda then falls back to the TUI
with `[!] Installation source` again.

**Fix attempt #2 (didn't work):** Use `harddrive --partition=LABEL=Rocky-9-7-x86_64-dvd --dir=/`
in ks.cfg.

**Why it didn't work:** The `harddrive` directive in anaconda kickstart only matches
real HDD partitions (`/dev/sda1` etc.), NOT CD-ROM block devices (`/dev/sr0`), even when
the label matches. Anaconda treats optical media differently from disks for this directive.
Still landed in TUI with `[!] Installation source`.

**Fix attempt #3 (didn't work):** Move install-source pinning from ks.cfg to the boot
line using `inst.repo=hd:LABEL=Rocky-9-7-x86_64-dvd:/`.

**Why it didn't work:** Anaconda DID try the source (different error this time:
"Error setting up software source" instead of "[!] Installation source not set"), but
could not finalize it. Rocky 9.7's `.treeinfo` is at `/` and lists
`repository = Minimal`. Anaconda's `hd:` block-source apparently doesn't follow the
relative path inside `.treeinfo` — it expects repodata directly at the path you give it.

ISO layout on `/tmp/Rocky-9.7-x86_64-minimal.iso`:
```
/                    # .treeinfo lives here, says repository=Minimal
├── .treeinfo
├── media.repo
├── Minimal/         # <-- actual repo lives here
│   ├── Packages/
│   └── repodata/
├── images/
├── isolinux/
└── EFI/
```

**Fix attempt #4 (current):** Point `inst.repo=` directly at `/Minimal/`:
```hcl
" inst.repo=hd:LABEL=Rocky-9-7-x86_64-dvd:/Minimal/",
```

In `http/ks.cfg`: no source directive (boot line is authoritative).

If this still fails, the next step is to drop the OEMDRV CD approach entirely and revert
to the historical HTTP/nc kickstart delivery (see Failed Approach #1 — the BPF issue
was on the local Packer host, but ESXi-side nc serving works fine).

---

## ESXi-Specific Notes

### nc syntax on ESXi (historical, kept for HTTP-kickstart fallback)
ESXi ships OpenBSD netcat. The syntax differs from Linux nc:
```bash
# WRONG (Linux syntax):
nc -l -p 8080

# CORRECT (ESXi/OpenBSD syntax):
nc -l 8080
```

### GuestIPHack
Enable on ESXi if Packer can't detect VM IP (needed when open-vm-tools aren't running yet):
```bash
ssh root@192.168.1.174 "esxcli system settings advanced set -o /Net/GuestIPHack -i 1"
```

### ISO location & checksum behaviour
- Local file at `/tmp/Rocky-9.7-x86_64-minimal.iso` is **read by Packer for checksum verification only**
- Packer uploads it to `remote_cache_datastore` (datastore2, `iso-image/` directory) if not already cached
- `build.sh` creates a zero-byte placeholder if no local file exists — this only works when paired with `iso_checksum = "none"`, NOT with a real sha256. Today's HCL uses a real sha256.
- ESXi-side cached ISO can have a *different* file size than the local one if it's a different download; Packer will overwrite it during build to match local.

### VNC over WebSocket
Required for ESXi 6.5+:
```hcl
vnc_over_websocket  = true
insecure_connection = true
```

### Watching the build
The ESXi host serves a VNC-over-WebSocket console. Open the ESXi web UI → find
`rocky9-template` VM → "Console" → "Launch remote console" (or "Open browser console").
**Reopen the console after every packer restart** — cancelling packer deletes the VM,
and a new packer run creates a new VM (potentially with a different vmid).

### Where vmware.log lives
`/vmfs/volumes/datastore1/rocky9-template/vmware.log` — tail to see boot events,
CDROM probes, and `MKSScreenShotMgr: Taking a screenshot` heartbeats (packer takes one
~per minute while waiting for SSH).

---

## Current File State (snapshot — keep in sync with the HCL)

### `rocky9-template.pkr.hcl` key settings
```hcl
remote_type            = "esx5"
remote_datastore       = "datastore1"
remote_cache_datastore = "datastore2"
remote_cache_directory = "iso-image"

disk_adapter_type = "pvscsi"
disk_type_id      = "thin"
network_adapter_type = "vmxnet3"

iso_url      = "file:///tmp/Rocky-9.7-x86_64-minimal.iso"
iso_checksum = "sha256:06b9e67a1ad7a992927022442837fa683fa846f9540d55090c84c4b2f31dc357"

cd_label = "OEMDRV"
cd_content = {
  "/ks.cfg" = templatefile("${path.root}/http/ks.cfg", {
    build_password = var.build_password
  })
}

boot_wait         = "20s"
boot_key_interval = "200ms"
boot_command = [
  "<tab><wait3>",
  " inst.text",
  "<wait>",
  " inst.stage2=hd:LABEL=Rocky-9-7-x86_64-dvd",
  "<wait>",
  " inst.ks=hd:LABEL=OEMDRV:/ks.cfg",
  "<wait>",
  " inst.nomediacheck rd.live.check=0",
  "<enter><wait>"
]

vnc_over_websocket  = true
insecure_connection = true
skip_export     = true
keep_registered = true
```

### `http/ks.cfg` partition layout
```
bootloader --location=mbr --boot-drive=sda
zerombr
clearpart --all --initlabel
part /boot  --fstype=xfs   --size=1024 --ondisk=sda
part pv.01  --fstype=lvmpv --size=1 --grow --ondisk=sda
volgroup vg_system pv.01
logvol /    --fstype=xfs  --size=8192 --grow --vgname=vg_system --name=lv_root
logvol swap --fstype=swap --size=2048        --vgname=vg_system --name=lv_swap
```

---

## Debugging Tips

### Watch the installer over VNC
Connect to the VM's VNC console via the ESXi Web Client. You can see exactly where anaconda
fails — the error text is on screen. Important: reopen the console after every packer restart.

### Check current packer state without VNC
```bash
# Local packer process
ps -ef | grep "packer build" | grep -v grep

# ESXi-side VM state
ssh root@192.168.1.174 "vim-cmd vmsvc/getallvms"
ssh root@192.168.1.174 "vim-cmd vmsvc/power.getstate <vmid>"

# Recent VM events
ssh root@192.168.1.174 "tail -20 /vmfs/volumes/datastore1/rocky9-template/vmware.log"

# ESXi clock (UTC) — log timestamps are in UTC, easy to misread
ssh root@192.168.1.174 "date -u"
```

### Test ks.cfg syntax before building
On any RHEL9/Rocky machine:
```bash
ksvalidator http/ks.cfg
```
(`pykickstart` package provides `ksvalidator`)

### Packer debug mode
```bash
PACKER_LOG=1 bash build.sh 2>&1 | tee /tmp/packer-debug.log
```

### If build hangs at "Waiting for SSH"
Anaconda may have:
- Hit the "not recommended media" prompt (Failed Approach #9) — boot_command missing `inst.nomediacheck rd.live.check=0`
- Landed in interactive TUI (Failed Approach #10) — boot_command missing `inst.ks=hd:LABEL=OEMDRV:/ks.cfg`
- Failed during package install — check VNC for the actual error line
- Network issue fetching packages — Rocky 9 minimal install pulls some packages from network if mirror reachable; check that DHCP worked

---

## What Comes After a Successful Packer Build

```
rocky9-template VM will be registered on ESXi, powered off, sealed.

Next:
1. cd /apps/git-code/git-vsphere/terraform
2. cp terraform.tfvars.example terraform.tfvars  # fill in ESXi creds
3. terraform init && terraform apply              # clones 9 VMs
4. terraform output -raw ansible_inventory > ../ansible/inventory/hosts.ini
5. cd ../ansible
6. ANSIBLE_CONFIG=/apps/git-code/git-vsphere/ansible/ansible.cfg \
   ansible-playbook playbooks/site.yml
```

---

## Resume Cheatsheet (for next session)

1. `git status` — what's modified since last commit?
2. `ls /vmfs/volumes/datastore1/rocky9-template/` via SSH — any leftover VM files? Clean if so.
3. `vim-cmd vmsvc/getallvms` via SSH — is `rocky9-template` registered? Any stuck `kmaster*` VMs?
4. `bash build.sh` from `packer/` to retry the template build.
5. Check this file's "Current State" section at the top — that's the rolling status.

---

# PART 2 — Cluster build via clone-from-vault.sh (session 2 final approach)

Packer abandoned mid-session 2 (see Failed Approaches #8–#11). Cluster was built
by direct `vmkfstools` cloning of the existing `vault-server` Rocky 9.7 VM.
Script: `terraform/clone-from-vault.sh`. The memory file
`project_vsphere_k8s.md` has the inventory and current state.

## What worked

1. Set up `ansible` user + SSH key + `ipv6.disable=1` on vault-server (via existing
   bstha sudo) — clones inherit all of these.
2. Power off vault-server (graceful, 30s timeout, hard fallback).
3. `vmkfstools -i <src> <dst> -d thin` 9× in parallel — fast (~1-3 min total
   when source is offline; reads are pure).
4. Generate per-clone VMX with `ethernet0.addressType = "generated"` (let ESXi
   pick MAC) and unique UUIDs.
5. `vim-cmd solo/registervm` for each.
6. Power vault-server back ON first.
7. Power on clones.

## Pitfalls hit during cloning (FAQ for future-me)

### A. ESXi has no `bash` — must use `sh -s`
Piping `ssh root@esxi 'bash -s' <<EOF` fails with `sh: bash: not found`. Use
`sh -s` and POSIX-only constructs (no `declare -a`, no here-strings).

### B. `cmd | while ... do ... & done` runs in a SUBSHELL
The background processes belong to the subshell, not the parent. `wait` in the
parent returns immediately. The first version of clone-from-vault.sh hit this
and proceeded to register VMs while clones were still copying — vault-server
couldn't be powered on because its `flat.vmdk` was held read-locked by 27
still-running vmkfstools helper threads.

Fix: serialize, or capture PIDs and wait on them explicitly.

### C. `00:0c:29:xx:xx:xx` is RESERVED for ESXi-generated MACs
Setting it as a static `ethernet0.address` produces:
```
Impermissible static Ethernet address: '00:0c:29:xx:xx:xx'.
It conflicts with VMware reserved MACs.
```
For static MACs use `00:50:56:00:00:00`–`00:50:56:3f:ff:ff`. Better: use
`ethernet0.addressType = "generated"` and let ESXi auto-pick a `00:0c:29` MAC.

### D. VMX edits are not picked up until reload
After `sed -i` on a `.vmx`, `vim-cmd vmsvc/power.on <vmid>` still uses the
in-memory cached config. Run `vim-cmd vmsvc/reload <vmid>` first, or
unregister + re-register.

### E. ESXi 6.7 scp/sftp is unreliable
"Couldn't write to remote file" failures even when `/tmp` has space. Use
`cat <file> | ssh root@esxi "cat > /path/to/file"` instead.

### F. ESXi `/tmp` is a small (~256 MB) ramdisk
Leftover log files from previous runs fill it up and block all future scp.
Cleanup checklist: `ssh root@esxi "rm -f /tmp/ks_server.log /tmp/nc.log /tmp/ks.cfg"`.

### G. `tr`, `bash`, `python` may be absent on ESXi
busybox ash + awk + sed are the safe baseline. `python` was present on
this 6.7 host but may not be elsewhere.

### H. Memory ceiling
On a 60 GB host with the planned cluster (3×4 GB master + 3×8 GB worker +
1 GB dns + 2×2 GB LB + 2 GB vault-server = 45 GB configured + VMX overhead),
the second loadbalancer (lb2) failed to power on with
`-22 Initial VMX memory reservation failed`. ESXi's per-VM overhead pre-allocation
ate the remaining headroom even though free RAM looked ample. **Single LB only**
in current build. Loadbalancer playbook needs adjustment.

### I. ovftool task lock on the source VM
This is the deep pit of josenk/esxi + ovftool. Every export_vm attempt creates
a task on ESXi. Failed/cancelled attempts leave the task in queue. Subsequent
ovftool calls fail with `vim.fault.TaskInProgress`. Even hostd restart didn't
fully clear it; only `/sbin/services.sh restart` + a clean retry worked one
time, then the cycle resumed. **Conclusion**: don't use ovftool to clone from
a running VM in tight loops. Use `vmkfstools` directly while source is off.

## Resume cheatsheet for clone-from-vault path

1. `vim-cmd vmsvc/getallvms` — expect vault-server (66) + 8 clones (kmaster1-3,
   kworker1-3, dns1, lb1).
2. If a clone shows `Powered off`, check `tail vmware.log` and `grep <name>
   /var/log/hostd.log | tail -10` for the actual reason.
3. To re-clone a single VM (e.g., recovery from VMFS corruption like lb2 had):
   ```
   ssh root@192.168.1.174
   vim-cmd vmsvc/unregister <vmid>
   rm -rf /vmfs/volumes/<ds>/<name>
   vim-cmd vmsvc/snapshot.create 66 clone-snap dummy 1 0
   mkdir -p /vmfs/volumes/<ds>/<name>
   vmkfstools -i /vmfs/volumes/datastore2/vault-server/vault-server.vmdk \
              /vmfs/volumes/<ds>/<name>/<name>.vmdk -d thin
   vim-cmd vmsvc/snapshot.removeall 66
   # write VMX (copy from a working clone, edit name/uuid)
   vim-cmd solo/registervm /vmfs/volumes/<ds>/<name>/<name>.vmx
   vim-cmd vmsvc/power.on <new-vmid>
   ```
4. Memory pressure debugging: `vsish -e get /memory/comprehensive | grep -i free`
   and `grep -E "Initial VMX memory" /var/log/hostd.log`.
