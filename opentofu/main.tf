data "local_file" "ssh_public_key" {
  filename = pathexpand(var.ssh_public_key_file)
}

# One template per Proxmox host; clones stay local.
module "template" {
  for_each = var.pve_hosts

  source = "./modules/template"

  host                 = each.key
  template_vmid        = local.template_vmids[each.key]
  cloud_image_url      = var.cloud_image_url
  cloud_image_checksum = var.cloud_image_checksum
  image_datastore_id   = var.image_datastore_id
  datastore_id         = var.datastore_id
}

module "control_plane" {
  for_each = { for cp in var.control_plane : cp.name => cp }

  source = "./modules/vm"

  name                 = each.value.name
  host                 = each.value.host
  vmid                 = each.value.vmid
  template_vmid        = module.template[each.value.host].template_vmid
  cpu                  = each.value.cpu
  ram                  = each.value.ram
  disk                 = each.value.disk
  ip                   = each.value.ip
  cidr_bits            = var.subnet_cidr_bits
  gateway              = var.gateway
  dns_servers          = var.dns_servers
  domain               = var.domain
  datastore_id         = var.datastore_id
  snippet_datastore_id = var.snippet_datastore_id
  bridge               = var.bridge
  tags                 = concat(local.base_tags, ["rke2-server", each.value.name])
  ssh_username         = var.ssh_username
  ssh_public_key       = data.local_file.ssh_public_key.content
}

module "worker" {
  for_each = { for w in var.workers : w.name => w }

  source = "./modules/vm"

  name                 = each.value.name
  host                 = each.value.host
  vmid                 = each.value.vmid
  template_vmid        = module.template[each.value.host].template_vmid
  cpu                  = each.value.cpu
  ram                  = each.value.ram
  disk                 = each.value.disk
  extra_disk           = each.value.extra_disk
  ip                   = each.value.ip
  cidr_bits            = var.subnet_cidr_bits
  gateway              = var.gateway
  dns_servers          = var.dns_servers
  domain               = var.domain
  datastore_id         = var.datastore_id
  snippet_datastore_id = var.snippet_datastore_id
  bridge               = var.bridge
  tags                 = concat(local.base_tags, ["rke2-agent", each.value.name])
  ssh_username         = var.ssh_username
  ssh_public_key       = data.local_file.ssh_public_key.content
}

resource "local_file" "ansible_inventory" {
  filename        = var.ansible_inventory_path
  file_permission = "0644"

  content = templatefile("${path.module}/inventory.tftpl", {
    servers = [
      for cp in var.control_plane : {
        name = module.control_plane[cp.name].name
        ip   = module.control_plane[cp.name].ip
      }
    ]
    agents = [
      for w in var.workers : {
        name = module.worker[w.name].name
        ip   = module.worker[w.name].ip
      }
    ]
    ssh_user             = var.ssh_username
    ssh_private_key_file = pathexpand(var.ssh_private_key_file)
    api_vip              = var.api_vip
  })
}
