# ESXi 6.7 host — quirks & fixes

Host: `192.168.1.174` (HP Z620, ESXi 6.7.0 build-8169922). 60 GB RAM,
Intel Xeon E5-2689 (8 cores / 16 threads), two datastores (datastore1
1.4 TB, datastore2 931 GB).

---

## E1. scp / sftp are unreliable

Random failures like:
```
Couldn't write to remote file "/tmp/ks.cfg": Failure
Couldn't fsetstat: Failure
failed to upload file /tmp/ks.cfg.XXXX to /tmp/ks.cfg
```
Happens even when `/tmp` has space and ssh works fine.

**Fix:** use `cat | ssh "cat >"` instead of scp:
```bash
cat localfile | ssh -o StrictHostKeyChecking=no root@192.168.1.174 \
  "cat > /tmp/remotefile && chmod 644 /tmp/remotefile"
```

`packer/build.sh` was rewritten to use this pattern.

---

## E2. `/tmp` is a small ramdisk (~256 MB)

Symptoms when full:
- scp fails (E1).
- `vsish` writes fail.
- VM power-on returns generic errors.

The most common offender is a leftover log from a previous run:
```bash
ssh root@192.168.1.174 'ls -la /tmp/'
# Look for *.log files in the hundreds of MB
```

This session, an old `/tmp/ks_server.log` from a previous packer attempt
had grown to 256 MB and blocked scp. Cleanup:
```bash
ssh root@192.168.1.174 'rm -f /tmp/*.log /tmp/ks.cfg /tmp/nc.log /tmp/ks_server.log'
```

Don't write nc / dnsmasq / kickstart server logs to `/tmp`; either
`/scratch/log/` (persistent) or `/dev/null`.

---

## E3. `00:0c:29:xx:xx:xx` MAC range is RESERVED for ESXi-generated MACs

Trying to set one as a static `ethernet0.address` fails at VM power-on:
```
Impermissible static Ethernet address: '00:0c:29:91:66:75'.
It conflicts with VMware reserved MACs.
Invalid MAC address specified.
Could not set up 'macAddress' for 'ethernet0'.
```

**Allowed static ranges:**
- `00:50:56:00:00:00` – `00:50:56:3f:ff:ff` (VMware manual-MAC range)

**Recommended:** don't bother with static — use `ethernet0.addressType =
"generated"` and let ESXi pick a `00:0c:29:xx:xx:xx` MAC itself. That's
what `clone-from-vault.sh` does after the initial mistake.

---

## E4. VMX cached in memory — `vim-cmd vmsvc/reload <vmid>` after edits

Direct `sed -i` on a `.vmx` file does NOT take effect on next
`vim-cmd vmsvc/power.on <vmid>` — hostd caches the parsed VMX. Either:

1. `vim-cmd vmsvc/reload <vmid>` then `power.on`
2. Or `vim-cmd vmsvc/unregister <vmid>` + `solo/registervm <vmx-path>`

If neither makes the change visible, restart `hostd` (`/etc/init.d/hostd
restart`) — running VMs are unaffected.

---

## E5. Memory ceiling — `-22 Initial VMX memory reservation failed`

ESXi reserves per-VM overhead at power-on (~200 MB to 1 GB per VM beyond
the `memSize`). With ~9 VMs powered on at 43 GB total `memSize`, plus
VMkernel + overhead, this host hit a ceiling and refused to start a 10th
VM (lb2 at 2 GB) even though `vsish -e get /memory/comprehensive` showed
43 GB free.

**Symptoms:**
```
hostd: VMX exited: '-22 Initial VMX memory reservation failed.
```

**Workarounds:**
- Shrink an existing VM (`memSize = "1024"`) and `vim-cmd vmsvc/reload`.
- Power off something else first.
- Strip GUIs (vault-server + clones had `Server with GUI` group, ~1-2 GB
  each — `bootstrap-users.yml` removes it).
- Drop the VM (we dropped lb2).

---

## E6. ovftool `TaskInProgress` / `InvalidState` loops

See [vault-server.md](vault-server.md) — moved there because the issue is
specifically about cloning vault-server. tl;dr: don't use ovftool, use
`vmkfstools -i` directly.

---

## E7. NFC leases linger

ESXi's NFC (Network File Copy) leases — used by ovftool for VM export —
sometimes stick around as `state = "active"` even after the ovftool
process dies. They prevent new exports from starting.

```bash
ssh root@192.168.1.174 'vim-cmd hostsvc/runtimeinfo | grep -A1 lease'
```

**Fix:** `/sbin/services.sh restart` (heavier than `hostd restart`;
running VMs unaffected; clears all leases). Or briefly power-cycle the
affected VM.

---

## E8. Disk extension via `vmkfstools -X` silently no-ops

When called on a registered VM with the same target size — or sometimes
even with a different target size — `vmkfstools -X 50G /…/clone.vmdk`
exits 0 but the file stays at the source size.

**Workaround:** verify size after extension:
```bash
ls -la /vmfs/volumes/datastore1/kmaster1/kmaster1-flat.vmdk
# Should be 50G * 1024^3 = 53687091200 if extension worked
```

If still source size, unregister the VM first, retry the extension, then
re-register.

---

## E9. ESXi shell tooling — what's missing

`bash`, `tr`, `mapfile`, `disown`, `readarray` are NOT available on
ESXi 6.7 (busybox sh + ash). `python` IS available (on this build, at
least). `awk`, `sed`, `grep` are busybox variants — most options work
but check the `--help` if something seems off.

All scripts that ssh into ESXi must be POSIX sh, not bash.
See [ansible.md](ansible.md) section A5.
