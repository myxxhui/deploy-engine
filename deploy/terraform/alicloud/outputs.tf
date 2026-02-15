output "public_ip" {
  description = "ECS 实例的公网 IP 地址"
  value       = module.ecs.public_ip
}

output "nas_mount_domain" {
  description = "NAS 挂载目标域名"
  value       = module.nas.nas_mount_domain
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "vswitch_id" {
  description = "VSwitch ID"
  value       = module.vpc.vswitch_id
}

output "security_group_id" {
  description = "安全组 ID"
  value       = module.security.security_group_id
}

output "instance_id" {
  description = "ECS 实例 ID"
  value       = module.ecs.instance_id
}

output "current_ip_used" {
  description = "实际用于安全组白名单的 IP 地址"
  value       = module.security.current_ip
}

output "oss_bucket_name" {
  description = "OSS Bucket 名称（用于 K3s 数据持久化）"
  value       = module.oss.bucket_name
}

output "oss_endpoint" {
  description = "OSS Bucket 访问端点"
  value       = module.oss.bucket_endpoint
}

output "oss_region" {
  description = "OSS Bucket 地域"
  value       = module.oss.bucket_region
}
