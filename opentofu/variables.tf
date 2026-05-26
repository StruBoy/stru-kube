variable "pve_hosts" {
  description = "Map of Proxmox node name (as it appears in /etc/pve/.members) to its management IP. Templates are built once per host."
  type        = map(string)
  default = {
    stru-prox0 = "10.74.2.20"
    stru-prox1 = "10.74.2.21"
    stru-prox2 = "10.74.2.22"
  }
}

variable "datastore_id" {
  description = "Proxmox storage pool for VM disks."
  type        = string
  default     = "local-lvm"
}

variable "snippet_datastore_id" {
  description = "Proxmox storage pool that has the 'snippets' content type enabled (for cloud-init user-data)."
  type        = string
  default     = "local"
}

variable "image_datastore_id" {
  description = "Proxmox storage pool to download the cloud image into (must allow content type 'iso')."
  type        = string
  default     = "local"
}

variable "bridge" {
  description = "Linux bridge VMs attach to."
  type        = string
  default     = "vmbr0"
}

variable "cloud_image_url" {
  description = "URL of the Ubuntu cloud image."
  type        = string
  default     = "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
}

variable "cloud_image_checksum" {
  description = "SHA256 checksum of the cloud image. Empty string skips verification."
  type        = string
  default     = ""
}

variable "domain" {
  description = "DNS suffix for VM FQDNs."
  type        = string
  default     = "lan"
}

variable "subnet_cidr_bits" {
  description = "CIDR mask bits for the VM subnet (e.g. 24 for /24)."
  type        = number
  default     = 24
}

variable "gateway" {
  description = "Default gateway for VMs."
  type        = string
  default     = "10.74.2.1"
}

variable "dns_servers" {
  description = "DNS resolvers for VMs."
  type        = list(string)
  default     = ["10.74.2.1", "1.1.1.1"]
}

variable "api_vip" {
  description = "Floating VIP for the Kubernetes API (kube-vip)."
  type        = string
  default     = "10.74.2.29"
}

variable "ssh_username" {
  description = "Default user created by cloud-init on each VM."
  type        = string
  default     = "ubuntu"
}

variable "ssh_public_key_file" {
  description = "Path to the SSH public key authorized on each VM."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "ssh_private_key_file" {
  description = "Path to the SSH private key Ansible uses (recorded in the inventory). Tofu does not read this file."
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "control_plane" {
  description = "Control-plane VM definitions. One per Proxmox host."
  type = list(object({
    name = string
    host = string
    vmid = number
    ip   = string
    cpu  = number
    ram  = number
    disk = number
  }))
  default = [
    { name = "cp1", host = "stru-prox0", vmid = 110, ip = "10.74.2.30", cpu = 2, ram = 4096, disk = 40 },
    { name = "cp2", host = "stru-prox1", vmid = 120, ip = "10.74.2.31", cpu = 2, ram = 4096, disk = 40 },
    { name = "cp3", host = "stru-prox2", vmid = 130, ip = "10.74.2.32", cpu = 2, ram = 4096, disk = 40 },
  ]
}

variable "workers" {
  description = "Worker VM definitions. One per Proxmox host. extra_disk feeds Longhorn."
  type = list(object({
    name       = string
    host       = string
    vmid       = number
    ip         = string
    cpu        = number
    ram        = number
    disk       = number
    extra_disk = number
  }))
  default = [
    { name = "w1", host = "stru-prox0", vmid = 111, ip = "10.74.2.33", cpu = 4, ram = 8192, disk = 80, extra_disk = 100 },
    { name = "w2", host = "stru-prox1", vmid = 121, ip = "10.74.2.34", cpu = 4, ram = 8192, disk = 80, extra_disk = 100 },
    { name = "w3", host = "stru-prox2", vmid = 131, ip = "10.74.2.35", cpu = 4, ram = 8192, disk = 80, extra_disk = 100 },
  ]
}

variable "template_vmid_base" {
  description = "Starting VMID for per-host templates. Each host uses base + index (9000, 9001, 9002)."
  type        = number
  default     = 9000
}

variable "ansible_inventory_path" {
  description = "Where to write the generated Ansible inventory."
  type        = string
  default     = "../ansible/inventory/hosts.ini"
}
