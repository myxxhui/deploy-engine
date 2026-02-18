output "instance_id" {
  description = "ECS 实例 ID（竞价或按量二选一）"
  value       = var.enable_spot ? try(alicloud_instance.spot[0].id, null) : try(alicloud_instance.on_demand[0].id, null)
}

output "public_ip" {
  description = "ECS 实例的公网 IP"
  value = var.enable_spot ? (
    try(alicloud_eip_address.spot[0].ip_address, "Instance Released")
  ) : try(alicloud_eip_address.on_demand[0].ip_address, "Instance Released")
}

output "eip_id" {
  description = "EIP ID"
  value       = var.enable_spot ? try(alicloud_eip_address.spot[0].id, null) : try(alicloud_eip_address.on_demand[0].id, null)
}
