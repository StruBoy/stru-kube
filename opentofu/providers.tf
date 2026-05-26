provider "proxmox" {
  # endpoint, api_token, insecure read from PROXMOX_VE_* env vars.

  ssh {
    agent    = true
    username = "root"

    # Workstation can't resolve the PVE node hostnames (they're only in the cluster's
    # internal /etc/pve/.members). Map each cluster node name to its management IP
    # so the provider can SSH directly when it uploads snippets / imports disks.
    dynamic "node" {
      for_each = var.pve_hosts
      content {
        name    = node.key
        address = node.value
      }
    }
  }
}
