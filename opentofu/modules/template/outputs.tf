output "template_vmid" {
  value       = proxmox_virtual_environment_vm.template.vm_id
  description = "VMID of the template on this host. Use as clone source."
}

output "host" {
  value = var.host
}
