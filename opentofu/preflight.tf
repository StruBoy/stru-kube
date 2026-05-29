# Plan-time validation: assert that var.pve_hosts keys match the live cluster's
# /etc/pve/.members nodelist. Without this, a typo'd node name silently passes
# `tofu plan` and then explodes during apply with HTTP 500 "hostname lookup failed".
#
# Uses the bpg/proxmox `nodes` data source (same provider auth as everything else),
# so this requires no new dependencies and no SSH/jq dance.

data "proxmox_virtual_environment_nodes" "cluster" {}

locals {
  expected_pve_nodes = sort(keys(var.pve_hosts))
  actual_pve_nodes   = sort(data.proxmox_virtual_environment_nodes.cluster.names)
}

resource "terraform_data" "validate_pve_hosts" {
  # Re-runs whenever either set changes; the precondition fires on every plan.
  input = {
    expected = local.expected_pve_nodes
    actual   = local.actual_pve_nodes
  }

  lifecycle {
    precondition {
      condition = local.actual_pve_nodes == local.expected_pve_nodes
      error_message = join("\n", [
        "var.pve_hosts keys do not match the live Proxmox cluster.",
        "  configured (var.pve_hosts): ${jsonencode(local.expected_pve_nodes)}",
        "  actual (cluster):           ${jsonencode(local.actual_pve_nodes)}",
        "Edit opentofu/variables.tf or set pve_hosts in terraform.tfvars to match",
        "the keys under `nodelist` in /etc/pve/.members on the cluster.",
      ])
    }
  }
}
