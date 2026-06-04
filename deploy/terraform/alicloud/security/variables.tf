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

variable "enable_proxy_ingress" {
  description = "开放 3proxy 入站（sg-proxy）"
  type        = bool
  default     = false
}

variable "proxy_port" {
  description = "3proxy 端口"
  type        = number
  default     = 3128
}

variable "proxy_allowed_cidr" {
  description = "允许访问 3proxy 的 CIDR（默认与 ssh_allowed_cidr 相同，可 0.0.0.0/0）"
  type        = string
  default     = "0.0.0.0/0"
}
