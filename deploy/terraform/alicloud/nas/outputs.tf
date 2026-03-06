output "nas_mount_domain" {
  description = "NAS 挂载目标域名（复用已有时取 existing_mount_target_domain，否则取新创建的）"
  value       = var.use_existing_mount_target ? var.existing_mount_target_domain : alicloud_nas_mount_target.main[0].mount_target_domain
}
