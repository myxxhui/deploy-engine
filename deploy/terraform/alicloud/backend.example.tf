# ==============================================================================
# Remote Backend 示例（可选）：将 Terraform 状态存于 OSS，便于多人协作与 state 锁
# ==============================================================================
# 使用前请：
# 1. 在阿里云创建 OSS Bucket（建议与 deploy-engine 所用地域一致）
# 2. 将本文件复制为 backend.tf 或合并到 provider.tf 的 terraform 块中，替换 backend "local"
# 3. 填写 bucket、prefix、key；可选填写 region、role_arn 等
# 4. 从 local 迁移：在 deploy/terraform/alicloud 下执行
#      terraform init -migrate-state
#    按提示确认将现有 state 迁移到 OSS
# ==============================================================================
#
# terraform {
#   backend "oss" {
#     bucket               = "your-terraform-state-bucket"
#     prefix               = "deploy-engine/alicloud"
#     key                  = "terraform.tfstate"
#     region               = "cn-hongkong"
#     tablestore_endpoint  = ""  # 可选：用于 state 锁，需开通 TableStore
#     tablestore_table     = ""
#   }
# }
#
# 若使用 OSS 默认的 state 锁（无 TableStore），部分版本支持；否则需配置 tablestore_* 或接受无锁。
# 迁移后请勿删除原 terraform.tfstate 直至确认远程 state 正常。
# ==============================================================================
