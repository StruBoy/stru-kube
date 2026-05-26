locals {
  # One template per PVE host so clones don't traverse the network.
  pve_host_list = sort(keys(var.pve_hosts))

  template_vmids = {
    for idx, host in local.pve_host_list :
    host => var.template_vmid_base + idx
  }

  # Tag every cluster VM for filtering in the PVE UI.
  base_tags = ["k8s", "stru-kube"]
}
