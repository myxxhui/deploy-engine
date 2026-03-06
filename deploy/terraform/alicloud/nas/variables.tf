variable "project_name" {
  description = "项目名称"
  type        = string
}

variable "env_id" {
  description = "环境标识符"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR（用于访问规则）"
  type        = string
}

variable "vswitch_id" {
  description = "VSwitch ID（用于挂载点）"
  type        = string
}

variable "use_existing_file_system" {
  description = "是否使用已存在的 NAS File System（如果为 true，则使用 existing_file_system_id）"
  type        = bool
  default     = false
}

variable "existing_file_system_id" {
  description = "已存在的 NAS File System ID（当 use_existing_file_system=true 时使用）"
  type        = string
  default     = ""
}

variable "use_existing_access_group" {
  description = "是否使用已存在的 NAS Access Group（如果为 true，则使用 existing_access_group_name）"
  type        = bool
  default     = false
}

variable "existing_access_group_name" {
  description = "已存在的 NAS Access Group 名称（当 use_existing_access_group=true 时使用）"
  type        = string
  default     = ""
}

variable "use_existing_mount_target" {
  description = "是否复用已有挂载点（为 true 时使用 existing_mount_target_domain，不创建新挂载点，避免每文件系统 2 个上限）"
  type        = bool
  default     = false
}

variable "existing_mount_target_domain" {
  description = "已存在的 NAS 挂载点域名（当 use_existing_mount_target=true 时使用，如 xxx.cn-hongkong.nas.aliyuncs.com）"
  type        = string
  default     = ""
}
