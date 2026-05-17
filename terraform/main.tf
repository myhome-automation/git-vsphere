locals {
  vms = {
    # control plane + infra — datastore1 (WD 500 GB)
    kmaster1 = { role = "k8s_master",   datastore = "datastore1" }
    kmaster2 = { role = "k8s_master",   datastore = "datastore1" }
    kmaster3 = { role = "k8s_master",   datastore = "datastore1" }
    dns1     = { role = "dns_dhcp",     datastore = "datastore1" }
    lb1      = { role = "loadbalancer", datastore = "datastore1" }
    lb2      = { role = "loadbalancer", datastore = "datastore1" }

    # workers — datastore2 (Hitachi 1 TB)
    kworker1 = { role = "k8s_worker",   datastore = "datastore2" }
    kworker2 = { role = "k8s_worker",   datastore = "datastore2" }
    kworker3 = { role = "k8s_worker",   datastore = "datastore2" }
  }
}

resource "esxi_guest" "vm" {
  for_each = local.vms

  guest_name     = each.key
  disk_store     = each.value.datastore
  clone_from_vm  = var.template_name
  numvcpus       = var.role_config[each.value.role].cpu
  memsize        = var.role_config[each.value.role].memory_mb
  boot_disk_size = var.role_config[each.value.role].disk_gb
  boot_disk_type = "thin"
  power          = "on"

  network_interfaces {
    virtual_network = "VM Network"
    nic_type        = "vmxnet3"
  }

  notes = "role=${each.value.role}"
}
