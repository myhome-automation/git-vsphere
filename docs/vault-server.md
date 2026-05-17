# vault-server — clone source for the cluster

`vault-server` (vmid 66, `[datastore2] vault-server/`) is a Rocky 9.7 VM
the user built manually outside this repo. It serves the live Vault
workload AND acts as the template for cloning the 8 cluster VMs.

ESXi reports its guest OS as `fedora64Guest` (that's just the guest-OS
hint the user picked at VM creation; actual OS is Rocky 9.7).

---

## V1. ovftool/josenk-esxi gets stuck in `TaskInProgress` loops

**Symptom:** Every `terraform apply` or direct `ovftool` invocation against
vault-server fails with:
```
Received SOAP response fault: exportVm
Another task is already in progress.
Fault cause: vim.fault.TaskInProgress
```

The error persists even when `parallelism=1`, `vim-cmd vmsvc/snapshot.get
<vmid>` shows no snapshots, and no obvious ovftool processes are running.

**Root cause:** Each ovftool invocation creates an `exportVm` task on
ESXi. Cancelled/failed invocations leave the task in queue. ESXi only
allows ONE exportVm task per VM. The queue accumulates fast and blocks
all subsequent attempts. `hostd` restart sometimes clears it, sometimes
not (the NFC lease lingers).

**What didn't work:**
- `parallelism=1` on terraform apply — the josenk/esxi provider spawns
  ovftool processes faster than the queue clears.
- `vim-cmd vimsvc/task_cancel` — no permission to cancel system tasks.
- Just waiting — tasks never timed out in the time we waited (5+ min).

**What did work** (one-shot only — the queue refills as soon as
terraform retries):
- `/sbin/services.sh restart` on ESXi (heavier than `hostd restart`;
  takes ~30 s; running VMs unaffected).

**Permanent fix:** abandon ovftool. Use `vmkfstools -i` directly on ESXi
(see V2 below) for any future cloning. ovftool's only advantage was
per-clone resize, which we now do via separate `vmkfstools -X` after.

---

## V2. `vmkfstools` clone path (the working approach)

`terraform/clone-from-vault.sh` does the whole thing in bash:

1. SSH to ESXi, run an `sh -s` script (busybox, not bash — see [ansible.md](ansible.md)).
2. Power off vault-server gracefully (`vmsvc/power.shutdown`, 30 s timeout,
   hard fallback). Vault is offline for ~5-10 min during clones.
3. For each of 8 target VMs, in parallel:
   ```
   vmkfstools -i /vmfs/volumes/datastore2/vault-server/vault-server.vmdk \
              /vmfs/volumes/<ds>/<name>/<name>.vmdk -d thin
   ```
4. Emit per-clone VMX (POSIX heredoc; new UUID and `ethernet0.addressType="generated"`).
5. `vim-cmd solo/registervm` each.
6. (Optional) `vmkfstools -X <size>G` to extend each disk to its target size.
7. Power vault-server back on FIRST.
8. Power on the clones.

**Single-clone recovery** (one VM corrupted, vault-server stays running):
```
ssh root@192.168.1.174
vim-cmd vmsvc/unregister <bad-vmid>
rm -rf /vmfs/volumes/<ds>/<name>
vim-cmd vmsvc/snapshot.create 66 clone-snap dummy 1 0   # snapshot live vault
mkdir -p /vmfs/volumes/<ds>/<name>
vmkfstools -i /vmfs/volumes/datastore2/vault-server/vault-server.vmdk \
           /vmfs/volumes/<ds>/<name>/<name>.vmdk -d thin
vim-cmd vmsvc/snapshot.removeall 66
# write VMX (copy from a working sibling clone, edit displayName + uuid)
vim-cmd solo/registervm /vmfs/volumes/<ds>/<name>/<name>.vmx
vim-cmd vmsvc/power.on <new-vmid>
```

---

## V3. NFC lease lingers after killed ovftool

Symptom: `vim-cmd hostsvc/runtimeinfo | grep -A1 lease` shows
`state = "active"` even when nothing is exporting.

**Fix:** `/sbin/services.sh restart` (drops all leases; running VMs
unaffected). If that doesn't work, brief power-cycle of vault-server
clears it definitively.

---

## V4. Subshell `wait` doesn't actually wait

Early version of clone-from-vault.sh used:
```sh
echo "$VMS" | while read name role ds cpu mem disk; do
  vmkfstools -i ... &
done
wait      # <-- only waits on subshell parent's bg procs (none)
```

The pipe puts the while loop in a subshell. The 9 background vmkfstools
processes belong to that subshell, not the parent. `wait` returns
immediately and the script proceeds to register VMs and power them on
while the actual disk copies are still running. vault-server then can't
power on because its `-flat.vmdk` is held by 27 still-running vmkfstools
helper threads.

**Fix:** use a non-pipe construct (or capture PIDs):
```sh
for entry in $(echo "$VMS"); do
  ...
  vmkfstools -i ... &
done
wait      # now in the parent shell
```

---

## V5. `vmkfstools -X` silently no-ops sometimes

The "extend disk to target size" step in clone-from-vault.sh often
finishes without error but the vmdk stays at the source size. Detection
inside the guest: `lsblk` shows sda at 30 GB even though we asked for
50/100 GB.

**Workaround:**
- Best-effort during initial clone — script logs a warning and continues.
- To fix per-VM later: power off the clone, `vmkfstools -X <size>G
  /vmfs/volumes/<ds>/<name>/<name>.vmdk`, power back on, then run base.yml
  to growpart + pvresize + lvol extend.

---

## V6. Vault-server's LVM layout is unique

vault-server was set up with VG `rlm` and LVs `root` (10G) / `var` (10G)
/ `apps` (5G) / `home` (3G). Clones inherit this layout — they're NOT
the `vg_system`/`lv_root` layout the packer template would have created.

`ansible/playbooks/base.yml`:
- Auto-detects VG name via `vgs --noheadings -o vg_name | head -1`
- Extends `var` LV (where `/var/lib/containerd` lives) if VG has >1 GiB free
- Skips otherwise (no-op idempotent)

---

## V7. What changed on vault-server

The user explicitly authorized these modifications to vault-server:

1. **ansible user**: created with `wheel` group + NOPASSWD sudo +
   `/apps/git-code/keys/ansible-key.pub` in authorized_keys.
2. **bstha user**: same (via `bootstrap-users.yml`).
3. **IPv6 disabled**: `/etc/sysctl.d/99-disable-ipv6.conf` +
   `grubby --update-kernel=ALL --args="ipv6.disable=1"`.
4. **GUI removed**: `Server with GUI` group, GNOME, X.org. Default target
   `multi-user.target`. Memory dropped from ~1.5 GB used to ~473 MB.
5. **DNS pointer**: `nmcli` modified primary connection's `ipv4.dns` to
   `192.168.1.188 8.8.8.8`, `ipv4.dns-search myhomelab.com`,
   `ipv4.ignore-auto-dns yes`.

These changes propagate to clones (since they were made BEFORE clone) AND
re-applied to vault-server in subsequent ansible runs (since it's in the
`everyone` group).
