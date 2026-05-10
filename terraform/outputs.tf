output "vm_name" {
  value = esxi_guest.vm.guest_name
}

output "vm_ip" {
  description = "IP assigned to the VM (populated after boot + VMware tools)"
  value       = esxi_guest.vm.ip_address
}

output "ansible_inventory_entry" {
  description = "Paste this into ansible/inventory/hosts.ini"
  value       = "[vm]\n${esxi_guest.vm.guest_name} ansible_host=${esxi_guest.vm.ip_address} ansible_user=ansible"
}
