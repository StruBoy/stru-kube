resource "proxmox_virtual_environment_download_file" "ubuntu" {
  content_type = "iso"
  datastore_id = var.image_datastore_id
  node_name    = var.host

  url            = var.cloud_image_url
  file_name      = "ubuntu-24.04-server-cloudimg-amd64.img"
  checksum       = var.cloud_image_checksum != "" ? var.cloud_image_checksum : null
  checksum_algorithm = var.cloud_image_checksum != "" ? "sha256" : null
  overwrite      = false
  upload_timeout = 1800
}

resource "proxmox_virtual_environment_vm" "template" {
  name      = "ubuntu-24.04-tmpl"
  node_name = var.host
  vm_id     = var.template_vmid
  template  = true
  started   = false

  description = "Ubuntu 24.04 cloud-image template managed by stru-kube"
  tags        = ["template", "ubuntu-2404"]

  agent {
    enabled = true
  }

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 2048
  }

  disk {
    datastore_id = var.datastore_id
    file_id      = proxmox_virtual_environment_download_file.ubuntu.id
    interface    = "scsi0"
    iothread     = true
    discard      = "on"
    size         = 8
  }

  network_device {
    bridge = "vmbr0"
    model  = "virtio"
  }

  serial_device {}

  operating_system {
    type = "l26"
  }
}
