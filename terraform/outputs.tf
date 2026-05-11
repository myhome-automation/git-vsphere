output "vm_ips" {
  description = "IP address of each VM (populated once open-vm-tools reports in)"
  value       = { for k, v in esxi_guest.vm : k => v.ip_address }
}

output "ansible_inventory" {
  description = "Paste into ansible/inventory/hosts.ini"
  value = <<-EOT
[k8s_masters]
${join("\n", [for k, v in esxi_guest.vm : "${k} ansible_host=${v.ip_address}" if local.vms[k].role == "k8s_master"])}

[k8s_workers]
${join("\n", [for k, v in esxi_guest.vm : "${k} ansible_host=${v.ip_address}" if local.vms[k].role == "k8s_worker"])}

[dns_dhcp]
${join("\n", [for k, v in esxi_guest.vm : "${k} ansible_host=${v.ip_address}" if local.vms[k].role == "dns_dhcp"])}

[loadbalancers]
${join("\n", [for k, v in esxi_guest.vm : "${k} ansible_host=${v.ip_address}" if local.vms[k].role == "loadbalancer"])}

[all:vars]
ansible_user=ansible
ansible_ssh_private_key_file=/apps/git-code/keys/ansible-key
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
EOT
}
