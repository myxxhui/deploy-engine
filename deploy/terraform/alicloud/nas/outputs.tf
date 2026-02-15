output "nas_mount_domain" {
  description = "NAS 挂载目标域名"
  value       = alicloud_nas_mount_target.main.mount_target_domain
}
