variable "host" {
  description = "Proxmox node name this template lives on."
  type        = string
}

variable "template_vmid" {
  description = "VMID for the template VM on this host."
  type        = number
}

variable "cloud_image_url" {
  type = string
}

variable "cloud_image_checksum" {
  type    = string
  default = ""
}

variable "image_datastore_id" {
  description = "Datastore for the downloaded cloud image (content type 'iso')."
  type        = string
  default     = "local"
}

variable "datastore_id" {
  description = "Datastore for the template's disk."
  type        = string
  default     = "local-lvm"
}
