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

variable "use_existing_bucket" {
  description = "是否使用已存在的 OSS Bucket（如果为 true，则使用 existing_bucket_name）"
  type        = bool
  default     = false
}

variable "existing_bucket_name" {
  description = "已存在的 OSS Bucket 名称（当 use_existing_bucket=true 时使用）"
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

variable "force_destroy_bucket" {
  description = "销毁时是否强制清空 Bucket 内对象（非空 Bucket 无法删除时设为 true）"
  type        = bool
  default     = false
}
