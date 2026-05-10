variable "esxi_host" {
  description = "ESXi host IP or hostname"
  type        = string
  default     = "192.168.1.174"
}

variable "esxi_username" {
  description = "ESXi username"
  type        = string
  default     = "root"
}

variable "esxi_password" {
  description = "ESXi root password"
  type        = string
  sensitive   = true
}

variable "vm_name" {
  description = "Name of the VM to create"
  type        = string
  default     = "ubuntu-vm"
}

variable "vm_cpus" {
  description = "Number of vCPUs"
  type        = number
  default     = 2
}

variable "vm_memory_mb" {
  description = "RAM in MB"
  type        = number
  default     = 2048
}

variable "vm_disk_gb" {
  description = "Disk size in GB (overrides OVA default)"
  type        = number
  default     = 20
}

variable "datastore" {
  description = "Target datastore name"
  type        = string
  default     = "apps"
}

variable "vm_network" {
  description = "Portgroup name for the VM NIC"
  type        = string
  default     = "VM Network"
}

variable "ovf_source" {
  description = "URL or local path to the OVA/OVF image"
  type        = string
  default     = "https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64.ova"
}

variable "ssh_public_key" {
  description = "SSH public key to inject into the VM via guestinfo"
  type        = string
  default     = ""
}
