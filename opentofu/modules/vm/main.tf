resource "proxmox_virtual_environment_file" "cloud_init" {
  content_type = "snippets"
  datastore_id = var.snippet_datastore_id
  node_name    = var.host

  source_raw {
    file_name = "${var.name}-user-data.yaml"
    data = templatefile("${path.module}/../../cloud-init.tftpl", {
      name        = var.name
      domain      = var.domain
      ssh_user    = var.ssh_username
      ssh_pubkey  = trimspace(var.ssh_public_key)
    })
  }
}

resource "proxmox_virtual_environment_vm" "this" {
  name      = var.name
  node_name = var.host
  vm_id     = var.vmid
  tags      = var.tags
  on_boot   = true

  clone {
    vm_id = var.template_vmid
    full  = true
  }

  agent {
    enabled = true
    timeout = "5m"
  }

  cpu {
    cores = var.cpu
    type  = "host"
  }

  memory {
    dedicated = var.ram
  }

  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    iothread     = true
    discard      = "on"
    size         = var.disk
  }

  dynamic "disk" {
    for_each = var.extra_disk > 0 ? [1] : []
    content {
      datastore_id = var.datastore_id
      interface    = "scsi1"
      iothread     = true
      discard      = "on"
      file_format  = "raw"
      size         = var.extra_disk
    }
  }

  network_device {
    bridge = var.bridge
    model  = "virtio"
  }

  serial_device {}

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id      = var.datastore_id
    user_data_file_id = proxmox_virtual_environment_file.cloud_init.id

    ip_config {
      ipv4 {
        address = "${var.ip}/${var.cidr_bits}"
        gateway = var.gateway
      }
    }

    dns {
      domain  = var.domain
      servers = var.dns_servers
    }
  }

  lifecycle {
    ignore_changes = [
      # PVE rotates the cloud-init MAC on edits; ignore unless we explicitly change network_device.
      network_device[0].mac_address,
    ]
  }
}
