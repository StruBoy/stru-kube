output "api_vip" {
  value = var.api_vip
}

output "server_ips" {
  value = { for name, m in module.control_plane : name => m.ip }
}

output "agent_ips" {
  value = { for name, m in module.worker : name => m.ip }
}

output "node_ips" {
  value = merge(
    { for name, m in module.control_plane : name => m.ip },
    { for name, m in module.worker : name => m.ip },
  )
}

output "ansible_inventory_path" {
  value = local_file.ansible_inventory.filename
}

output "next_steps" {
  value = <<-EOT

    Infrastructure ready. Next:
      ansible-galaxy install -r ../ansible/requirements.yml
      ansible -i ../ansible/inventory/hosts.ini rke2_cluster -m ping
      ansible-playbook -i ../ansible/inventory/hosts.ini ../ansible/site.yml
      ansible-playbook -i ../ansible/inventory/hosts.ini ../ansible/addons.yml

  EOT
}
