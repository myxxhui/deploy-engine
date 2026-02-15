output "security_group_id" {
  description = "安全组 ID"
  value       = local.security_group_id
}

output "current_ip" {
  description = "当前 IP 地址（用于白名单）"
  value       = local.current_ip
}
