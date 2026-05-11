variable "esxi_host" {
  type    = string
  default = "192.168.1.174"
}

variable "esxi_password" {
  type      = string
  sensitive = true
}

# Temporary password for the ansible user during Packer build
# Ansible replaces this with key-based auth on first run
variable "build_password" {
  type      = string
  sensitive = true
  default   = "ChangeMe123!"
}
