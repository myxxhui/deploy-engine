variable "project_name" {
  description = "项目名称"
  type        = string
}

variable "env_id" {
  description = "环境标识符"
  type        = string
}

variable "instance_type" {
  description = "ECS 实例规格（用于查找可用区）"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR 块"
  type        = string
  default     = "10.0.0.0/16"
}

variable "vswitch_cidr" {
  description = "VSwitch CIDR 块"
  type        = string
  default     = "10.0.1.0/24"
}

variable "use_existing_vpc" {
  description = "是否使用已存在的 VPC（如果为 true，则使用 existing_vpc_id）"
  type        = bool
  default     = false
}

variable "existing_vpc_id" {
  description = "已存在的 VPC ID（当 use_existing_vpc=true 时使用）"
  type        = string
  default     = ""
}

variable "use_existing_vswitch" {
  description = "是否使用已存在的 VSwitch（如果为 true，则使用 existing_vswitch_id）"
  type        = bool
  default     = false
}

variable "existing_vswitch_id" {
  description = "已存在的 VSwitch ID（当 use_existing_vswitch=true 时使用）"
  type        = string
  default     = ""
}

variable "existing_vpc_cidr" {
  description = "已存在的 VPC CIDR（当 use_existing_vpc=true 时使用，用于安全组规则）"
  type        = string
  default     = ""
}
