variable "project_name" {
  description = "项目名称"
  type        = string
}

variable "env_id" {
  description = "环境标识符"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR（用于内部通信规则）"
  type        = string
}

variable "use_existing_security_group" {
  description = "是否使用已存在的安全组（如果为 true，则使用 existing_security_group_id）"
  type        = bool
  default     = false
}

variable "existing_security_group_id" {
  description = "已存在的安全组 ID（当 use_existing_security_group=true 时使用）"
  type        = string
  default     = ""
}

variable "ssh_allowed_cidr" {
  description = "允许 SSH/6443 的源 CIDR；为空时使用 apply 时检测到的出口 IP/32"
  type        = string
  default     = ""
}
