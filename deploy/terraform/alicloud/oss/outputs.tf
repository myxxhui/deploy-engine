output "bucket_name" {
  description = "OSS Bucket 名称"
  value       = local.bucket_name
}

output "bucket_endpoint" {
  description = "OSS Bucket 访问端点"
  value       = "${local.bucket_name}.oss-${var.region}.aliyuncs.com"
}

output "bucket_region" {
  description = "OSS Bucket 地域"
  value       = var.region
}
