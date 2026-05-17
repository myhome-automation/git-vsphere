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
  remote_cache_datastore   = "datastore2"
  remote_cache_directory   = "iso-image"

  # ── VM definition ──────────────────────────────────────────────────────────
  vm_name           = "rocky9-template"
  guest_os_type     = "otherlinux-64"  # VMX format — ESXi 6.7 native value for 64-bit Other Linux
  version           = "14"                 # vmx-14 is the max supported by ESXi 6.7

  cpus              = 2
  memory            = 2048
  disk_size         = 20480         # 20 GB — Terraform expands per node role
  disk_adapter_type = "pvscsi"      # VMware paravirtual — vmw_pvscsi always in Rocky 9 initramfs
  disk_type_id      = "thin"

  network_adapter_type = "vmxnet3"
  network              = "VM Network"

  # ── ISO — staged at /tmp locally and at [datastore2] iso-image/ on ESXi ──
  # Packer verifies the local file matches iso_checksum, then checks
  # remote_cache_datastore/remote_cache_directory/<filename> on the ESXi side
  # and uses that copy if present (no re-upload). SHA256 below is the value
  # published in https://download.rockylinux.org/pub/rocky/9/isos/x86_64/CHECKSUM.
  iso_url      = "file:///tmp/Rocky-9.7-x86_64-minimal.iso"
  iso_checksum = "sha256:06b9e67a1ad7a992927022442837fa683fa846f9540d55090c84c4b2f31dc357"

  # ── Kickstart via HTTP from ESXi ──────────────────────────────────────────
  # build.sh renders ks.cfg locally with build_password substituted, scps it
  # to ESXi /tmp/ks.cfg, and runs an nc loop on ESXi:8080 to serve it.
  # No OEMDRV CD — only the install ISO is attached, so anaconda's `cdrom`
  # directive in ks.cfg resolves to the install ISO unambiguously.
  # See TROUBLESHOOTING.md Failed Approach #10/#11/#12/#13 for why OEMDRV
  # was abandoned (anaconda's hd: block source can't double-mount the install
  # CD that's already providing stage2).

  # Rocky 9.7 minimal ISO — ISOLINUX in BIOS mode.
  # boot_key_interval: ESXi VNC-over-WebSocket drops if keys sent too fast.
  #
  # Boot args:
  #   inst.text             — TUI installer (no X)
  #   inst.stage2=cdrom     — anaconda finds stage2 on the (only) CD
  #   ip=dhcp               — force dracut to bring up DHCP early, BEFORE the
  #                           kickstart fetch. Without this anaconda may fetch
  #                           the URL before networking is ready → "failed to
  #                           fetch kickstart" error
  #   inst.ks=http://192.168.1.174:8080/ks.cfg
  #                         — fetch kickstart from ESXi-side nc loop
  #   inst.sshd             — start sshd in the installer environment so we can
  #                           SSH in and look at /tmp/anaconda.log if install
  #                           hangs (password "ansible" from rd.shell, root)
  #   inst.nomediacheck     — skip anaconda's "It is not recommended to use
  #                           this media" warning
  #   rd.live.check=0       — disable dracut media verification at early boot
  boot_wait         = "20s"
  boot_key_interval = "200ms"
  boot_command = [
    "<tab><wait3>",
    " inst.text",
    "<wait>",
    " inst.stage2=cdrom",
    "<wait>",
    " ip=dhcp",
    "<wait>",
    " inst.ks=http://192.168.1.174:8080/ks.cfg",
    "<wait>",
    " inst.sshd inst.nomediacheck rd.live.check=0",
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
