variable "env_id" {
  description = "环境标识符（如：dev, prod）"
  type        = string
}

variable "project" {
  description = "项目名（可选），用于资源命名与 kubeconfig"
  type        = string
  default     = ""
}

variable "config_file" {
  description = "环境 YAML 配置文件绝对路径（由引擎传入，ConfigRoot 下的 <project>-<env>.yaml 或 default-<env>.yaml）"
  type        = string
  default     = ""
}

variable "region" {
  description = "阿里云地域"
  type        = string
  default     = "cn-hongkong"
}

variable "enable_spot" {
  description = "是否启用 Spot 实例"
  type        = bool
  default     = true
}

variable "instance_type" {
  description = "ECS 实例规格（ecs.u1-c1m4.xlarge=4核16G, ecs.u1-c1m2.large=2核4G）"
  type        = string
  default     = "ecs.u1-c1m4.xlarge"
}

variable "instance_password" {
  description = "ECS 实例 root 密码"
  type        = string
  sensitive   = true
  validation {
    condition     = length(var.instance_password) >= 8
    error_message = "instance_password 必须至少 8 位字符"
  }
}

variable "spot_strategy" {
  description = "Spot 实例出价策略"
  type        = string
  default     = "SpotAsPriceGo"
}

variable "spot_price_limit" {
  description = "Spot 最高出价"
  type        = number
  default     = 0.5
}

variable "disk_category" {
  description = "系统盘类型（cloud 兼容性最好；部分地域/规格不支持 cloud_efficiency/cloud_essd）"
  type        = string
  default     = "cloud"
}

variable "disk_size" {
  description = "系统盘大小（GB）"
  type        = number
  default     = 100
}

variable "image_id" {
  description = "ECS 镜像 ID"
  type        = string
  default     = "ubuntu_22_04_x64_20G_alibase_20251226"
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

variable "eip_bandwidth" {
  description = "EIP 带宽上限（Mbps），按量付费（PayByTraffic）"
  type        = number
  default     = 100
}

variable "acr_server" {
  description = "ACR 镜像仓库地址"
  type        = string
  default     = ""
}

variable "acr_namespace" {
  description = "ACR 命名空间"
  type        = string
  default     = ""
}

variable "oss_use_existing_bucket" {
  description = "是否使用已存在的 OSS Bucket"
  type        = bool
  default     = false
}

variable "oss_existing_bucket_name" {
  description = "已存在的 OSS Bucket 名称"
  type        = string
  default     = ""
}

variable "vpc_use_existing" {
  description = "是否使用已存在的 VPC"
  type        = bool
  default     = false
}

variable "vpc_existing_id" {
  description = "已存在的 VPC ID"
  type        = string
  default     = ""
}

variable "vpc_existing_cidr" {
  description = "已存在的 VPC CIDR"
  type        = string
  default     = ""
}

variable "vswitch_use_existing" {
  description = "是否使用已存在的 VSwitch"
  type        = bool
  default     = false
}

variable "vswitch_existing_id" {
  description = "已存在的 VSwitch ID"
  type        = string
  default     = ""
}

variable "security_group_use_existing" {
  description = "是否使用已存在的安全组"
  type        = bool
  default     = false
}

variable "security_group_existing_id" {
  description = "已存在的安全组 ID"
  type        = string
  default     = ""
}

variable "nas_use_existing_file_system" {
  description = "是否使用已存在的 NAS File System"
  type        = bool
  default     = false
}

variable "nas_existing_file_system_id" {
  description = "已存在的 NAS File System ID"
  type        = string
  default     = ""
}

variable "nas_use_existing_access_group" {
  description = "是否使用已存在的 NAS Access Group"
  type        = bool
  default     = false
}

variable "nas_existing_access_group_name" {
  description = "已存在的 NAS Access Group 名称"
  type        = string
  default     = ""
}

variable "ram_role_name" {
  description = "ECS RAM Role 名称（可选，需在控制台预先创建；不自动创建 Role/Policy）"
  type        = string
  default     = ""
}

variable "force_destroy_bucket" {
  description = "销毁 OSS Bucket 时是否先清空对象（非空 Bucket 无法删除时需为 true）"
  type        = bool
  default     = true
}
