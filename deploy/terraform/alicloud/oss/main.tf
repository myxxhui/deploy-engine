# ==============================================================================
# OSS 模块：对象存储资源（用于 K3s 数据持久化）
# ==============================================================================

# 固定 Bucket 名称：region 不变时始终复用同一存储桶，不重复创建
locals {
  fixed_bucket_name = "deploy-engine-k3s-storage"

  # 创建时使用固定名称；使用已存在时用 existing_bucket_name 或固定名
  bucket_name_to_create = var.use_existing_bucket ? (
    var.existing_bucket_name != "" ? var.existing_bucket_name : local.fixed_bucket_name
  ) : local.fixed_bucket_name

  should_create_bucket = !var.use_existing_bucket
}

# 创建 OSS Bucket：固定名称 deploy-engine-k3s-storage，region 不变时复用同一桶；bucket_acl 默认 public-read 公网只读
# 未设置 oss_use_existing_bucket=true 时一定会创建桶并上传 scripts/titan-init.sh；若 state 丢失且桶已存在，可设 oss_use_existing_bucket=true、oss_existing_bucket_name="deploy-engine-k3s-storage" 复用
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

# OSS Bucket ACL（仅当创建新 Bucket 时设置）。默认 public-read 公网只读；若 403 可在 tfvars 设 oss_bucket_acl = "private"
resource "alicloud_oss_bucket_acl" "main" {
  count  = local.should_create_bucket ? 1 : 0
  bucket = alicloud_oss_bucket.main[0].bucket
  acl    = var.bucket_acl

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
  # use_existing_bucket 时上传到已存在桶；否则在创建桶（固定名 deploy-engine-k3s-storage）成功后上传
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

  # init_script_acl=public-read 时 ECS 可直接 HTTP 下载；private 时需 ECS 绑定 ram_role_name
  acl = var.init_script_acl

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
