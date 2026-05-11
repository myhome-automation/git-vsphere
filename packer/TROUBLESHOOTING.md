# Packer Rocky9 Template Build — Troubleshooting Guide

## Environment

| Item | Value |
|------|-------|
| ESXi host | 192.168.1.174 (HP Z620, ESXi 6.7.0 build-8169922) |
| Packer machine | 192.168.1.181 (VMware VM running Rocky Linux) |
| ISO | `[datastore1] iso_file/Rocky-9.1-x86_64-minimal.iso` |
| Packer plugin | hashicorp/vmware `~> 1.0` (pinned at v1.2.0) |
| Packer binary | `/usr/bin/packer` v1.15.3 |
| Build script | `packer/build.sh` |

---

## Current State (2026-05-10)

The Packer build reaches anaconda but hits an "anaconda installer error".
The most recent attempted fixes (applied, not yet tested):

1. Reverted `disk_adapter_type` from `pvscsi` → `lsilogic`
2. Changed `logvol / --size=1` → `--size=8192`
3. Added `--ondisk=sda` to the `/boot` partition line

**Next action**: Run `bash build.sh` from `packer/` directory and watch the VNC console.

---

## How to Run the Build

```bash
cd /apps/git-code/git-vsphere/packer
bash build.sh
```

`build.sh` does:
1. Renders `http/ks.cfg` with the actual `build_password` from `packer.pkrvars.hcl`
2. SCPs rendered ks.cfg to ESXi `/tmp/ks.cfg`
3. Starts a `nc` HTTP loop on ESXi port 8080 (serves ks.cfg to installer)
4. Runs `packer build -var-file=packer.pkrvars.hcl .`
5. On exit (trap): kills nc loop, removes /tmp/ks.cfg from ESXi

## How to Clean Up a Failed Build

```bash
# Kill nc server loop on ESXi
ssh root@192.168.1.174 "pkill -f 'nc -l 8080' 2>/dev/null; rm -f /tmp/ks.cfg; true"

# Find and destroy the half-built VM
ssh root@192.168.1.174 "vim-cmd vmsvc/getallvms"
# Note the VMID for rocky9-template, then:
ssh root@192.168.1.174 "vim-cmd vmsvc/power.off <VMID>"
ssh root@192.168.1.174 "vim-cmd vmsvc/unregister <VMID>"
ssh root@192.168.1.174 "rm -rf /vmfs/volumes/datastore1/rocky9-template"
```

---

## Failed Approaches (Do Not Retry)

### 1. Packer's built-in HTTP server (`http_directory`)

**What we tried:** Let Packer serve ks.cfg on its own HTTP server (default behavior, port 8100–8110).

**Why it fails:** The packer machine at 192.168.1.181 runs as a non-root user inside a systemd user session. Systemd attaches `cgroup_skb` BPF programs (`sd_fw_ingress`) to the user session cgroup. These BPF programs drop inbound TCP SYN packets **before iptables sees them**. Adding firewall rules has zero effect — iptables counters stay at 0 while connections are dropped.

Confirmed with:
```bash
# SYN packets arrive at ens33 but iptables ACCEPT rule gets 0 hits:
tcpdump -i ens33 -n 'tcp and port 8100'    # shows SYN from ESXi
iptables -L INPUT -n -v | grep 8100         # counter stays at 0
```

Even `sudo python3 -m http.server` is affected because `sudo` inherits the cgroup of the calling user process.

**Fix:** Serve kickstart FROM ESXi itself (nc server on ESXi at 192.168.1.174:8080). The installer VM is on the same physical host, so this is always reachable. `build.sh` implements this.

---

### 2. Floppy delivery (`floppy_content` / `inst.ks=floppy:/ks.cfg`)

**What we tried:** Used Packer's `floppy_content` to inject ks.cfg onto a virtual floppy, then booted with `inst.ks=floppy:/ks.cfg`.

**Why it fails:** Rocky 9.1 installer initramfs does not include the `floppy` kernel module. The installer cannot mount the floppy device. Adding `rd.driver.pre=floppy` to the boot line also fails — module simply isn't present.

Error seen: `kickstart file /run/install/ks.cfg is missing` then `pane is dead (status 1)`.

**Fix:** ESXi nc HTTP server approach (see above).

---

### 3. GRUB2 boot command syntax

**What we tried (wrong):** Boot command using GRUB2 syntax (`<e>` to edit, GRUB2 `linux` line editing).

**Why it fails:** Rocky 9.1 minimal ISO on this hardware boots in **BIOS mode using ISOLINUX**, not GRUB2. The console shows:
```
Press Tab for full configuration options
```

ISOLINUX key behavior:
- `<up>` — wraps from item 1 (Install) to LAST item (Troubleshooting). **Never use `<up>`.**
- `<tab>` — appends to the current boot line of the selected entry
- `<enter>` — boots

Correct boot command:
```hcl
boot_command = [
  "<tab><wait2>",
  " inst.text inst.stage2=cdrom inst.ks=http://192.168.1.174:8080/ks.cfg",
  "<enter><wait>"
]
```

---

### 4. GPT partition with `biosboot` partition

**What we tried:** Added `part biosboot --fstype=biosboot --size=1` to ks.cfg for GPT layout.

**Why it fails:** ESXi 6.7 VMs created in BIOS mode (no UEFI) with pvscsi or lsilogic — the biosboot partition caused dracut emergency shell on boot.

Error: VM drops to `dracut:/# ` emergency prompt immediately after install reboot.

**Fix:** Use MBR partition layout (no biosboot partition, `--location=mbr` on bootloader directive):
```
bootloader --location=mbr --boot-drive=sda
zerombr
clearpart --all --initlabel
part /boot  --fstype=xfs   --size=1024 --ondisk=sda
part pv.01  --fstype=lvmpv --size=1 --grow --ondisk=sda
```

---

### 5. `http_ip` parameter

**What we tried:** Adding `http_ip = "192.168.1.181"` to force Packer's HTTP server IP.

**Why it fails:** The `http_ip` parameter does not exist in hashicorp/vmware plugin v1.2.0. Packer parse error: `An argument named "http_ip" is not expected here`.

---

### 6. `pvscsi` disk adapter

**What we tried:** `disk_adapter_type = "pvscsi"` (supposedly better performance).

**Why it likely fails:** Rocky 9.1 anaconda may not have pvscsi driver available during install, so the disk doesn't appear as `sda`. The anaconda "storage error" is the likely result.

**Current fix:** Reverted to `disk_adapter_type = "lsilogic"` which has universal driver support in anaconda.

---

### 7. `logvol / --size=1`

**What we tried:** `logvol / --fstype=xfs --size=1 --grow`

**Why it fails:** Anaconda's storage validation requires a minimum real size for the root logical volume. A `--size=1` (1 MB) specification is rejected even with `--grow`.

**Fix:** `logvol / --fstype=xfs --size=8192 --grow`

---

## ESXi-Specific Notes

### nc syntax on ESXi
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

### ISO location
The ISO is already on the ESXi datastore — Packer's remote cache check finds it and skips download:
```
[datastore1] iso_file/Rocky-9.1-x86_64-minimal.iso
```
The `iso_url = "file:///tmp/..."` in the HCL is a dummy that never gets fetched.

### VNC over WebSocket
Required for ESXi 6.5+:
```hcl
vnc_over_websocket  = true
insecure_connection = true
```

---

## Current File State

### `rocky9-template.pkr.hcl` key settings
```hcl
disk_adapter_type = "lsilogic"    # reverted from pvscsi
disk_type_id      = "thin"
boot_wait = "15s"
boot_command = [
  "<tab><wait2>",
  " inst.text inst.stage2=cdrom inst.ks=http://192.168.1.174:8080/ks.cfg",
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
Connect to the VM's VNC console via vSphere Web Client while packer runs. You can see exactly where anaconda fails — the error text is displayed on screen.

### Check ESXi nc server is running
From ESXi shell after build.sh starts:
```bash
ps | grep nc
wget -O- http://localhost:8080/ks.cfg  # should dump ks.cfg contents
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
Anaconda may have failed silently. Check the VNC console. Common causes:
- Kickstart fetch failed (nc server died, wrong URL)
- Storage config error (disk not found, LV size too small)
- Package install error (network unreachable, bad mirror)

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
