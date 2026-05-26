variable "name" {
  description = "VM name and hostname (e.g. cp1, w2)."
  type        = string
}

variable "host" {
  description = "Proxmox node this VM runs on."
  type        = string
}

variable "vmid" {
  type = number
}

variable "template_vmid" {
  description = "Source template VMID (on the same host) to clone from."
  type        = number
}

variable "cpu" {
  type = number
}

variable "ram" {
  description = "Memory in MiB."
  type        = number
}

variable "disk" {
  description = "Root disk size in GiB."
  type        = number
}

variable "extra_disk" {
  description = "Optional extra disk in GiB (0 = none). Used for Longhorn data on workers."
  type        = number
  default     = 0
}

variable "ip" {
  description = "Static IPv4 address (no CIDR suffix)."
  type        = string
}

variable "cidr_bits" {
  type    = number
  default = 24
}

variable "gateway" {
  type = string
}

variable "dns_servers" {
  type = list(string)
}

variable "domain" {
  type    = string
  default = "lan"
}

variable "datastore_id" {
  type    = string
  default = "local-lvm"
}

variable "snippet_datastore_id" {
  type    = string
  default = "local"
}

variable "bridge" {
  type    = string
  default = "vmbr0"
}

variable "tags" {
  type    = list(string)
  default = []
}

variable "ssh_username" {
  type    = string
  default = "ubuntu"
}

variable "ssh_public_key" {
  description = "Authorized SSH public key (inline content)."
  type        = string
}
