provider "proxmox" {
  # All of these read from PROXMOX_VE_* env vars by default; declared here
  # for explicitness. Never put the API token in tfvars.
  endpoint  = null
  api_token = null
  insecure  = null

  ssh {
    agent    = true
    username = null
  }
}
