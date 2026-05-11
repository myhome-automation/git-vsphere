packer {
  required_plugins {
    vmware = {
      version = "~> 1.0"
      source  = "github.com/hashicorp/vmware"
    }
  }
}

source "vmware-iso" "rocky9" {
  # ── Remote ESXi target ─────────────────────────────────────────────────────
  remote_type              = "esx5"
  remote_host              = var.esxi_host
  remote_username          = "root"
  remote_password          = var.esxi_password
  remote_datastore         = "datastore1"
  remote_cache_datastore   = "datastore1"
  remote_cache_directory   = "iso_file"

  # ── VM definition ──────────────────────────────────────────────────────────
  vm_name           = "rocky9-template"
  guest_os_type     = "otherlinux-64"  # VMX format — ESXi 6.7 native value for 64-bit Other Linux
  version           = "14"                 # vmx-14 is the max supported by ESXi 6.7

  cpus              = 2
  memory            = 2048
  disk_size         = 20480         # 20 GB — Terraform expands per node role
  disk_adapter_type = "lsilogic"
  disk_type_id      = "thin"

  network_adapter_type = "vmxnet3"
  network              = "VM Network"

  # ── ISO — already on ESXi datastore ───────────────────────────────────────
  # Packer checks remote_cache_datastore/remote_cache_directory/<filename> first.
  # Since Rocky-9.1-x86_64-minimal.iso is already at [datastore1] iso_file/,
  # the file is found and the download from iso_url is skipped entirely.
  iso_url      = "file:///tmp/Rocky-9.1-x86_64-minimal.iso"
  iso_checksum = "none"

  # ── Kickstart via sudo HTTP server on 192.168.1.181:8200 ──────────────────
  # Packer's own HTTP server (user cgroup) is blocked by systemd's sd_fw_ingress
  # BPF filter. Running as root bypasses it. build.sh pre-renders ks.cfg and
  # starts a sudo Python HTTP server before invoking packer.

  # Rocky 9.1 minimal ISO uses ISOLINUX in BIOS mode:
  #   NO <up> — <up> wraps ISOLINUX to the LAST item (Troubleshooting), not Install.
  #   The default selected item is already "Install Rocky Linux 9.1".
  #   <tab> appends to the current boot line; <enter> boots.
  #   Kickstart served from ESXi host (192.168.1.174:8080) — same physical host
  #   as the installer VM, so always reachable regardless of external firewall.
  boot_wait = "15s"
  boot_command = [
    "<tab><wait2>",
    " inst.text inst.stage2=cdrom inst.ks=http://192.168.1.174:8080/ks.cfg",
    "<enter><wait>"
  ]

  # ── SSH communicator — connects after anaconda reboots ─────────────────────
  communicator = "ssh"
  ssh_username = "ansible"
  ssh_password = var.build_password
  ssh_timeout  = "30m"
  ssh_port     = 22

  # ── VNC over ESXi WebSocket (required for ESXi 6.5+) ──────────────────────
  vnc_over_websocket  = true
  insecure_connection = true

  # ── Leave the template VM registered on ESXi ──────────────────────────────
  # Terraform uses clone_from_vm = "rocky9-template" — no OVA export needed
  skip_export     = true
  keep_registered = true

  shutdown_command = "echo '${var.build_password}' | sudo -S /sbin/shutdown -h now"
}

build {
  name    = "rocky9-template"
  sources = ["source.vmware-iso.rocky9"]

  # ── Seal the template so each clone gets a fresh identity ─────────────────
  provisioner "shell" {
    execute_command = "echo '${var.build_password}' | sudo -S bash -c '{{ .Path }}'"
    inline = [
      # Remove machine-specific IDs — each clone regenerates them
      "truncate -s 0 /etc/machine-id",
      "rm -f /var/lib/dbus/machine-id",

      # Remove SSH host keys — each clone generates its own on first boot
      "rm -f /etc/ssh/ssh_host_*",

      # Clear network interface state (MAC-based naming cache)
      "rm -f /etc/udev/rules.d/70-persistent-net.rules",
      "rm -f /var/lib/NetworkManager/*.lease",

      # Clean package and log artifacts
      "dnf clean all",
      "rm -rf /var/cache/dnf /var/log/dnf* /var/log/yum*",
      "truncate -s 0 /var/log/messages",
      "truncate -s 0 /var/log/secure",

      # Zero free space to improve VMDK compression when cloning
      "dd if=/dev/zero of=/zerofill bs=1M 2>/dev/null; rm -f /zerofill",
      "sync"
    ]
  }
}
