variable "project_name" {
  description = "项目名称"
  type        = string
}

variable "env_id" {
  description = "环境标识符"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID（用于 Bucket Policy）"
  type        = string
}

variable "common_tags" {
  description = "通用标签"
  type        = map(string)
  default     = {}
}

variable "region" {
  description = "阿里云地域"
  type        = string
  default     = "cn-hongkong"
}

variable "oss_bucket_name" {
  description = "OSS 存储桶名称。指定时：检查存在则复用，不存在则创建；未指定（空）时：创建 {project_name}-{env_id}-{random} 新桶"
  type        = string
  default     = ""
}

variable "nas_mount_domain" {
  description = "NAS 挂载域名（用于初始化脚本）"
  type        = string
}

variable "acr_server" {
  description = "ACR 镜像仓库服务器地址（用于初始化脚本）"
  type        = string
  default     = ""
}

variable "acr_namespace" {
  description = "ACR 镜像仓库命名空间（用于初始化脚本）"
  type        = string
  default     = ""
}

variable "init_script_content" {
  description = "初始化脚本内容（已通过 templatefile 处理）"
  type        = string
}

variable "init_script_acl" {
  description = "OSS 初始化脚本对象 ACL：public-read 时 ECS 可直接 HTTP 下载；private 时需 ECS 绑定 ram_role_name。若 apply 报 PutObject acl 不允许则设为 private。"
  type        = string
  default     = "public-read"
}

variable "bucket_acl" {
  description = "新建 OSS Bucket 的 ACL：public-read 公网只读；private 仅账号可访问。部分账号禁止 public-read-write"
  type        = string
  default     = "public-read"
}

variable "force_destroy_bucket" {
  description = "销毁时是否强制清空 Bucket 内对象（非空 Bucket 无法删除时设为 true）"
  type        = bool
  default     = false
}
