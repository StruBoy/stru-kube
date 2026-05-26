output "name" {
  value = proxmox_virtual_environment_vm.this.name
}

output "host" {
  value = var.host
}

output "ip" {
  value       = var.ip
  description = "Static IP from cloud-init (deterministic; doesn't require agent reporting)."
}

output "vmid" {
  value = proxmox_virtual_environment_vm.this.vm_id
}
