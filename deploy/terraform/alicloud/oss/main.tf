# ==============================================================================
# OSS 模块：对象存储资源（用于 K3s 数据持久化）
# ==============================================================================

# 生成随机后缀（用于避免固定名称被占用时的冲突）
# 随机后缀基于 keepers，相同配置会生成相同的后缀，便于复用
resource "random_id" "bucket_suffix" {
  keepers = {
    env_id       = var.env_id
    project_name = var.project_name
  }
  byte_length = 4
}

# Bucket 名称：默认使用带随机后缀的名称（避免全局名称冲突）
# 如果希望使用固定名称，可以设置 oss_use_existing_bucket = true 并指定固定名称
locals {
  fixed_bucket_name       = "${var.project_name}-k3s-storage-${var.env_id}"
  bucket_name_with_suffix = "${var.project_name}-k3s-storage-${var.env_id}-${random_id.bucket_suffix.hex}"

  # 使用的 Bucket 名称：
  # - 如果 use_existing_bucket=true，使用 existing_bucket_name 或 fixed_bucket_name
  # - 如果 use_existing_bucket=false，使用带随机后缀的名称（避免冲突）
  bucket_name_to_create = var.use_existing_bucket ? (
    var.existing_bucket_name != "" ? var.existing_bucket_name : local.fixed_bucket_name
    ) : (
    local.bucket_name_with_suffix
  )

  # 判断是否需要创建新 Bucket
  # - 如果 use_existing_bucket=true，不创建（使用已存在的 Bucket）
  # - 如果 use_existing_bucket=false，创建新 Bucket（使用带随机后缀的名称，避免冲突）
  # 注意：由于 random_id.bucket_suffix.hex 在 plan 阶段是 known after apply，
  # 我们不能在 plan 阶段检查 Bucket 是否存在，所以简化逻辑：
  # 如果 use_existing_bucket=false，总是尝试创建（使用随机后缀，冲突概率很低）
  should_create_bucket = !var.use_existing_bucket
}

# 创建新的 OSS Bucket（仅当 Bucket 不存在时）
# 默认使用带随机后缀的名称，避免全局名称冲突
# 如果希望使用固定名称，设置 oss_use_existing_bucket = true 并指定固定名称
resource "alicloud_oss_bucket" "main" {
  count = local.should_create_bucket ? 1 : 0

  bucket        = local.bucket_name_to_create
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

  # 确保先创建再销毁，避免对象资源创建时 Bucket 不存在
  lifecycle {
    create_before_destroy = true
  }
}

# OSS Bucket ACL（使用新资源替代废弃的 acl 字段）
# 仅当创建新 Bucket 时设置 ACL
resource "alicloud_oss_bucket_acl" "main" {
  count  = local.should_create_bucket ? 1 : 0
  bucket = alicloud_oss_bucket.main[0].bucket
  acl    = "private"

  # 确保先创建再销毁，避免对象资源创建时 Bucket 不存在
  lifecycle {
    create_before_destroy = true
  }
}

# 本地值：统一 Bucket 名称引用
# 优先级：use_existing_bucket > 新创建的 Bucket
locals {
  bucket_name = var.use_existing_bucket ? (
    var.existing_bucket_name != "" ? var.existing_bucket_name : local.fixed_bucket_name
    ) : (
    length(alicloud_oss_bucket.main) > 0 ? alicloud_oss_bucket.main[0].bucket : local.bucket_name_to_create
  )
}

# 上传初始化脚本到 OSS（用于 user-data 下载）
# 无论 Bucket 是否存在，都上传/更新脚本（确保脚本始终是最新的）
resource "alicloud_oss_bucket_object" "init_script" {
  # 只有当 Bucket 存在或已创建时才创建对象
  # 如果 use_existing_bucket=true，总是创建对象（假设 Bucket 已存在）
  # 如果 use_existing_bucket=false，只有当 Bucket 创建成功时才创建对象
  # 注意：由于 random_id.bucket_suffix.hex 在 plan 阶段是 known after apply，
  # 我们不能在 plan 阶段检查 Bucket 是否存在，所以简化逻辑
  count = var.use_existing_bucket ? 1 : (
    length(alicloud_oss_bucket.main) > 0 ? 1 : 0
  )

  bucket = local.bucket_name
  key    = "scripts/titan-init.sh"

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

  # 对象私有读，避免账号策略 "Put public object acl is not allowed"；ECS 通过 RAM Role 用 ossutil 下载
  # 请在 tfvars 中设置 ram_role_name，并在控制台为该 Role 授予目标 Bucket 的 oss:GetObject 权限
  acl = "private"

  # 注意：Terraform 会自动根据 content 计算 etag
  # 当脚本内容变化时，Terraform 会自动检测并更新对象
  # 不需要手动设置 etag 字段（该字段不支持手动设置）

  # 确保 Bucket 和 ACL 先创建（如果 Bucket 需要创建）
  depends_on = [
    alicloud_oss_bucket.main,
    alicloud_oss_bucket_acl.main
  ]
}

# 对象为 private 时，ECS user-data 会先尝试 HTTP 下载（失败），再使用 ossutil + 实例元数据（RAM Role）
# 必须在 tfvars 中设置 ram_role_name，并在控制台为该 Role 授予 OSS 读权限（如 oss:GetObject）
# 如需启用 Bucket Policy，请确保账户允许设置公共策略
#
# resource "alicloud_oss_bucket_policy" "main" {
#   bucket = alicloud_oss_bucket.main.bucket
#   
#   policy = jsonencode({
#     Version = "1"
#     Statement = [
#       {
#         Effect = "Allow"
#         Principal = "*"
#         Action = [
#           "oss:GetObject",
#           "oss:PutObject",
#           "oss:DeleteObject",
#           "oss:ListObjects",
#           "oss:ListParts",
#           "oss:AbortMultipartUpload"
#         ]
#         Resource = [
#           "${alicloud_oss_bucket.main.bucket}/*"
#         ]
#         Condition = {
#           StringEquals = {
#             "acs:SourceVpc" = var.vpc_id
#           }
#         }
#       }
#     ]
#   })
# }
