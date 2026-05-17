#!/usr/bin/env bash
# Driver script (runs locally on packer host). The actual clone work runs as
# a POSIX sh script that's piped to ESXi (which only has busybox sh, not bash).
#
# Approach:
#   1. ssh to ESXi, run an sh script that:
#      - powers off vault-server (graceful, hard fallback)
#      - clones vault-server.vmdk to 9 targets in parallel via vmkfstools -d thin
#      - emits per-clone VMX with new UUIDs/MAC/CPU/RAM
#      - registers each via vim-cmd
#      - powers vault-server back on FIRST, then powers on clones
#      - resizes disks where role needs > 20 GB
#   2. Back here on the packer host, poll each new VM for DHCP-assigned IP
#   3. Write ansible/inventory/hosts.ini
set -euo pipefail

ESXI=192.168.1.174
TF_DIR="$(cd "$(dirname "$0")" && pwd)"
INVENTORY_OUT="$(dirname "$TF_DIR")/ansible/inventory/hosts.ini"

ssh -o StrictHostKeyChecking=no root@"$ESXI" 'sh -s' <<'REMOTE'
set -eu
VAULT_VMID=66
VAULT_DIR="/vmfs/volumes/datastore2/vault-server"
SRC_VMDK="$VAULT_DIR/vault-server.vmdk"

# Per-VM: name role datastore_path cpu mem_mb disk_gb (newline-separated)
VMS='kmaster1 k8s_master   /vmfs/volumes/datastore1 2 4096 50
kmaster2 k8s_master   /vmfs/volumes/datastore1 2 4096 50
kmaster3 k8s_master   /vmfs/volumes/datastore1 2 4096 50
dns1     dns_dhcp     /vmfs/volumes/datastore1 1 1024 20
lb1      loadbalancer /vmfs/volumes/datastore1 1 2048 20
lb2      loadbalancer /vmfs/volumes/datastore1 1 2048 20
kworker1 k8s_worker   /vmfs/volumes/datastore2 2 8192 100
kworker2 k8s_worker   /vmfs/volumes/datastore2 2 8192 100
kworker3 k8s_worker   /vmfs/volumes/datastore2 2 8192 100'

echo "==> powering off vault-server (graceful, 30s timeout, then hard off)"
vim-cmd vmsvc/power.shutdown "$VAULT_VMID" 2>/dev/null || true
i=0
while [ "$i" -lt 30 ]; do
  state=$(vim-cmd vmsvc/power.getstate "$VAULT_VMID" | tail -1)
  [ "$state" = "Powered off" ] && break
  sleep 1
  i=$((i+1))
done
state=$(vim-cmd vmsvc/power.getstate "$VAULT_VMID" | tail -1)
if [ "$state" != "Powered off" ]; then
  echo "    graceful shutdown didn't complete; forcing power off"
  vim-cmd vmsvc/power.off "$VAULT_VMID"
fi
echo "    vault-server is now powered off"

# UUID generator (busybox awk supports srand and printf)
genuuid() {
  awk 'BEGIN{srand(); s=""; for(i=0;i<16;i++){s=s sprintf("%02x", int(rand()*256)); if(i==7) s=s "-"; else if(i<15) s=s " "} print s}'
}
# MAC generator (00:0c:29 = VMware OUI)
genmac() {
  awk 'BEGIN{srand(); printf "00:0c:29:%02x:%02x:%02x\n", int(rand()*256),int(rand()*256),int(rand()*256)}'
}

# Phase 1: parallel vmkfstools clones
echo "==> launching parallel vmkfstools clones (source is read-only since vault-server is off)"
echo "$VMS" | while read name role ds cpu mem disk; do
  [ -z "$name" ] && continue
  target_dir="$ds/$name"
  if [ -d "$target_dir" ]; then
    echo "    [$name] target dir exists, skipping clone"
    continue
  fi
  mkdir -p "$target_dir"
  echo "    [$name] cloning -> $target_dir/$name.vmdk (thin)"
  vmkfstools -i "$SRC_VMDK" "$target_dir/$name.vmdk" -d thin >/tmp/clone-$name.log 2>&1 &
done
wait
echo "==> all clones finished"

# Phase 2: write VMX, register, resize
echo "$VMS" | while read name role ds cpu mem disk; do
  [ -z "$name" ] && continue
  target_dir="$ds/$name"
  vmx="$target_dir/$name.vmx"

  if [ ! -f "$vmx" ]; then
    uuid=$(genuuid)
    mac=$(genmac)
    echo "==> [$name] writing VMX (cpu=$cpu mem=$mem MB disk=$disk GB mac=$mac)"
    cat > "$vmx" <<VMXEOF
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "14"
nvram = "$name.nvram"
pciBridge0.present = "TRUE"
pciBridge4.present = "TRUE"
pciBridge4.virtualDev = "pcieRootPort"
pciBridge4.functions = "8"
pciBridge5.present = "TRUE"
pciBridge5.virtualDev = "pcieRootPort"
pciBridge5.functions = "8"
pciBridge6.present = "TRUE"
pciBridge6.virtualDev = "pcieRootPort"
pciBridge6.functions = "8"
pciBridge7.present = "TRUE"
pciBridge7.virtualDev = "pcieRootPort"
pciBridge7.functions = "8"
vmci0.present = "TRUE"
hpet0.present = "TRUE"
floppy0.present = "FALSE"
RemoteDisplay.maxConnections = "-1"
numvcpus = "$cpu"
memSize = "$mem"
powerType.powerOff = "default"
powerType.suspend = "soft"
powerType.reset = "default"
tools.upgrade.policy = "manual"
scsi0.virtualDev = "pvscsi"
scsi0.present = "TRUE"
scsi0:0.deviceType = "scsi-hardDisk"
scsi0:0.fileName = "$name.vmdk"
scsi0:0.present = "TRUE"
ethernet0.virtualDev = "vmxnet3"
ethernet0.networkName = "VM Network"
ethernet0.addressType = "static"
ethernet0.address = "$mac"
ethernet0.wakeOnPcktRcv = "FALSE"
ethernet0.uptCompatibility = "TRUE"
ethernet0.present = "TRUE"
displayName = "$name"
guestOS = "centos7-64"
toolScripts.afterPowerOn = "TRUE"
toolScripts.afterResume = "TRUE"
toolScripts.beforeSuspend = "TRUE"
toolScripts.beforePowerOff = "TRUE"
tools.syncTime = "TRUE"
uuid.bios = "$uuid"
uuid.location = "$uuid"
annotation = "role=$role|cloned from vault-server"
VMXEOF
  else
    echo "==> [$name] VMX exists, skipping write"
  fi

  if ! vim-cmd vmsvc/getallvms 2>/dev/null | awk -v n="$name" '$2==n{found=1} END{exit !found}'; then
    echo "==> [$name] registering"
    vim-cmd solo/registervm "$vmx" >/dev/null
  else
    echo "==> [$name] already registered"
  fi

  if [ "$disk" != "20" ]; then
    echo "==> [$name] extending disk to ${disk} GB"
    vmkfstools -X "${disk}G" "$target_dir/$name.vmdk" >/dev/null 2>&1 || \
      echo "    [$name] (vmkfstools extend may have no-op'd; ok if disk already at size)"
  fi
done

# Phase 3: power vault-server back on FIRST, then power on clones
echo "==> powering vault-server back ON (priority)"
vim-cmd vmsvc/power.on "$VAULT_VMID" >/dev/null

echo "==> powering on clones"
echo "$VMS" | while read name role ds cpu mem disk; do
  [ -z "$name" ] && continue
  vmid=$(vim-cmd vmsvc/getallvms 2>/dev/null | awk -v n="$name" '$2==n{print $1}')
  if [ -z "$vmid" ]; then
    echo "==> [$name] cannot find vmid, skipping power on"
    continue
  fi
  state=$(vim-cmd vmsvc/power.getstate "$vmid" | tail -1)
  if [ "$state" = "Powered on" ]; then
    echo "==> [$name] already on (vmid=$vmid)"
  else
    echo "==> [$name] powering on (vmid=$vmid)"
    vim-cmd vmsvc/power.on "$vmid" >/dev/null
  fi
done

echo "==> done. Current VM list:"
vim-cmd vmsvc/getallvms
REMOTE

echo
echo "==> waiting up to 5 min for DHCP/VMware Tools to report IPs ..."
ips=""
i=0
while [ "$i" -lt 60 ]; do
  ips=$(ssh -o StrictHostKeyChecking=no root@"$ESXI" '
    for vmid in $(vim-cmd vmsvc/getallvms | awk "/kmaster|kworker|dns1|lb1|lb2/ {print \$1}"); do
      name=$(vim-cmd vmsvc/getallvms | awk -v v="$vmid" "\$1==v{print \$2}")
      ip=$(vim-cmd vmsvc/get.guest "$vmid" 2>/dev/null | grep -oE "ipAddress = \"[0-9.]+\"" | head -1 | grep -oE "[0-9.]+")
      echo "$name $ip"
    done' 2>/dev/null || true)
  missing=$(echo "$ips" | awk 'NF<2{c++} END{print c+0}')
  echo "  attempt $((i+1))/60: pending=$missing"
  [ "$missing" -eq 0 ] && [ -n "$ips" ] && break
  sleep 5
  i=$((i+1))
done

echo
echo "==> IPs:"
echo "$ips"

mkdir -p "$(dirname "$INVENTORY_OUT")"
{
  echo "# Generated by clone-from-vault.sh"
  echo "[kube_masters]"
  echo "$ips" | awk '/^kmaster/{printf "%s ansible_host=%s\n", $1, $2}'
  echo
  echo "[kube_workers]"
  echo "$ips" | awk '/^kworker/{printf "%s ansible_host=%s\n", $1, $2}'
  echo
  echo "[dns]"
  echo "$ips" | awk '/^dns/{printf "%s ansible_host=%s\n", $1, $2}'
  echo
  echo "[loadbalancers]"
  echo "$ips" | awk '/^lb/{printf "%s ansible_host=%s\n", $1, $2}'
  echo
  echo "[all:vars]"
  echo "ansible_user=ansible"
  echo "ansible_ssh_private_key_file=/apps/git-code/keys/ansible-key"
  echo "ansible_python_interpreter=/usr/bin/python3"
} > "$INVENTORY_OUT"

echo "==> Wrote inventory to $INVENTORY_OUT"
cat "$INVENTORY_OUT"
