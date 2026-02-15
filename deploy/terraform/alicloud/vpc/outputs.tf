output "vpc_id" {
  description = "VPC ID"
  value       = local.vpc_id
}

output "vswitch_id" {
  description = "VSwitch ID"
  value       = local.vswitch_id
}

output "selected_zone" {
  description = "选中的可用区（复用 VPC 和 VSwitch 时为 null，ECS 模块会从 VSwitch 获取）"
  value       = local.selected_zone
}

output "vpc_cidr" {
  description = "VPC CIDR"
  value       = local.vpc_cidr
}
