variable "esxi_host" {
  type    = string
  default = "192.168.1.174"
}

variable "esxi_password" {
  type      = string
  sensitive = true
}

variable "template_name" {
  type    = string
  default = "rocky9-template"
}

variable "role_config" {
  type = map(object({
    cpu       = number
    memory_mb = number
    disk_gb   = number
  }))
  default = {
    k8s_master = {
      cpu       = 2
      memory_mb = 4096
      disk_gb   = 50
    }
    k8s_worker = {
      cpu       = 2
      memory_mb = 8192
      disk_gb   = 100
    }
    dns_dhcp = {
      cpu       = 1
      memory_mb = 1024
      disk_gb   = 20
    }
    loadbalancer = {
      cpu       = 1
      memory_mb = 2048
      disk_gb   = 20
    }
  }
}
