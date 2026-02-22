# ==============================================================================
# OSS 模块：对象存储资源（用于 K3s 数据持久化）
# ==============================================================================
# 行为：
# - 指定 oss_bucket_name：用 alicloud_oss_buckets 检查存在性；存在则复用，不存在则创建
# - 未指定（空）：创建 {project_name}-{env_id}-{random} 新桶
# - 上传与下载统一使用同一桶
# ==============================================================================

# 检查指定桶名是否已存在（仅当 oss_bucket_name 非空时查询；空时用 ^$ 无匹配）
data "alicloud_oss_buckets" "existing" {
  name_regex = var.oss_bucket_name != "" ? "^${replace(var.oss_bucket_name, "/", "\\/")}$" : "^$"
}

# 未指定桶名时用于生成随机后缀
resource "random_string" "bucket_suffix" {
  count   = var.oss_bucket_name == "" ? 1 : 0
  length  = 8
  special = false
  upper   = false
}

locals {
  bucket_exists      = var.oss_bucket_name != "" && length(data.alicloud_oss_buckets.existing.buckets) > 0
  should_create      = !local.bucket_exists
  new_bucket_name    = var.oss_bucket_name != "" ? var.oss_bucket_name : "${var.project_name}-${var.env_id}-${random_string.bucket_suffix[0].result}"
}

# 需要创建时新建 Bucket
resource "alicloud_oss_bucket" "main" {
  count = local.should_create ? 1 : 0

  bucket        = local.new_bucket_name
  force_destroy = var.force_destroy_bucket

  versioning {
    status = "Enabled"
  }

  lifecycle_rule {
    id      = "cleanup-old-versions"
    enabled = true

    expiration {
      days = 90
    }
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-oss-k3s-storage-${var.env_id}"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "alicloud_oss_bucket_acl" "main" {
  count  = local.should_create ? 1 : 0
  bucket = alicloud_oss_bucket.main[0].bucket
  acl    = var.bucket_acl

  lifecycle {
    create_before_destroy = true
  }
}

# 统一 Bucket 名称：已有则用指定名，否则用新创建的桶名
locals {
  bucket_name = local.bucket_exists ? var.oss_bucket_name : (
    length(alicloud_oss_bucket.main) > 0 ? alicloud_oss_bucket.main[0].bucket : local.new_bucket_name
  )
}

# 上传初始化脚本到 OSS（用于 user-data 下载），始终上传（桶或已存在或刚创建）
resource "alicloud_oss_bucket_object" "init_script" {
  bucket = local.bucket_name
  key    = "scripts/k3s-init.sh"

  content = replace(
    replace(
      var.init_script_content,
      "oss_bucket_name=\"\"",
      "oss_bucket_name=\"${local.bucket_name}\""
    ),
    "oss_endpoint=\"\"",
    "oss_endpoint=\"${local.bucket_name}.oss-${var.region}.aliyuncs.com\""
  )

  content_type = "text/x-shellscript"
  acl          = var.init_script_acl

  depends_on = [
    alicloud_oss_bucket.main,
    alicloud_oss_bucket_acl.main
  ]
}
