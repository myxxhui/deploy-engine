output "instance_id" {
  description = "ECS 实例 ID"
  value       = var.enable_spot ? try(alicloud_instance.spot[0].id, null) : null
}

output "public_ip" {
  description = "ECS 实例的公网 IP"
  value = var.enable_spot ? (
    try(alicloud_eip_address.spot[0].ip_address, "Instance Released")
  ) : "Instance Released"
}

output "eip_id" {
  description = "EIP ID"
  value       = var.enable_spot ? try(alicloud_eip_address.spot[0].id, null) : null
}
