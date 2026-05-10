resource "esxi_guest" "vm" {
  guest_name = var.vm_name
  disk_store = var.datastore
  ovf_source = var.ovf_source

  numvcpus = var.vm_cpus
  memsize  = var.vm_memory_mb

  power = "on"

  network_interfaces {
    virtual_network = var.vm_network
    nic_type        = "vmxnet3"
  }

  # Resize the root disk beyond the OVA default
  virtual_disks {
    virtual_disk_id = esxi_virtual_disk.root.id
    slot            = "0:0"
  }

  # Inject SSH key via cloud-init guestinfo (Ubuntu cloud image reads these)
  guestinfo = var.ssh_public_key != "" ? {
    "metadata"          = base64encode(local.cloud_meta)
    "metadata.encoding" = "base64"
    "userdata"          = base64encode(local.cloud_user)
    "userdata.encoding" = "base64"
  } : {}

  guest_startup_timeout  = 120
  guest_shutdown_timeout = 30
}

resource "esxi_virtual_disk" "root" {
  virtual_disk_disk_store = var.datastore
  virtual_disk_dir        = var.vm_name
  virtual_disk_name       = "${var.vm_name}-root.vmdk"
  virtual_disk_size       = var.vm_disk_gb
  virtual_disk_type       = "thin"
}

locals {
  cloud_meta = <<-META
    instance-id: ${var.vm_name}
    local-hostname: ${var.vm_name}
  META

  cloud_user = <<-USERDATA
    #cloud-config
    users:
      - name: ansible
        groups: sudo
        shell: /bin/bash
        sudo: ALL=(ALL) NOPASSWD:ALL
        ssh_authorized_keys:
          - ${var.ssh_public_key}
    package_update: true
    packages:
      - python3
      - python3-pip
  USERDATA
}
