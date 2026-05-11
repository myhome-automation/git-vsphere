locals {
  # ── datastore1 (VMFS-6, 1.4 TB) — control plane + infrastructure ──────────
  # Hosts the template, masters, load balancers, and DNS/DHCP.
  # Kept separate so the cluster brain is on one storage unit.
  #
  # ── apps (VMFS-5, 931 GB) — data plane ────────────────────────────────────
  # Workers only — the nodes that actually run workloads.
  # Large capacity for container images and persistent volumes.

  vms = {
    # control plane — datastore1
    kmaster1 = { role = "k8s_master",   datastore = "datastore1" }
    kmaster2 = { role = "k8s_master",   datastore = "datastore1" }
    kmaster3 = { role = "k8s_master",   datastore = "datastore1" }

    # data plane — apps
    kworker1 = { role = "k8s_worker",   datastore = "apps" }
    kworker2 = { role = "k8s_worker",   datastore = "apps" }
    kworker3 = { role = "k8s_worker",   datastore = "apps" }

    # infrastructure services — datastore1 (manage the cluster, not workloads)
    dns1     = { role = "dns_dhcp",     datastore = "datastore1" }
    lb1      = { role = "loadbalancer", datastore = "datastore1" }
    lb2      = { role = "loadbalancer", datastore = "datastore1" }
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
