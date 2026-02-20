variable "project_name" {
  description = "项目名称"
  type        = string
}

variable "env_id" {
  description = "环境标识符"
  type        = string
}

variable "enable_spot" {
  description = "是否启用 Spot 实例"
  type        = bool
  default     = true
}

variable "instance_type" {
  description = "ECS 实例规格"
  type        = string
}

variable "instance_password" {
  description = "ECS 实例 root 密码"
  type        = string
  sensitive   = true
}

variable "availability_zone" {
  description = "可用区 ID（可选，如果为空则从 vswitch_id 获取）"
  type        = string
  default     = ""
}

variable "security_group_id" {
  description = "安全组 ID"
  type        = string
}

variable "vswitch_id" {
  description = "VSwitch ID"
  type        = string
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
  description = "系统盘类型（IoOptimized 实例仅支持 cloud_efficiency/cloud_ssd；非 IoOptimized 可用 cloud）"
  type        = string
  default     = "cloud_efficiency"
}

variable "disk_size" {
  description = "系统盘大小（GB）"
  type        = number
  default     = 100
}

variable "image_id" {
  description = "ECS 镜像 ID（默认使用动态查找）"
  type        = string
  default     = "ubuntu_22_04_x64_20G_alibase_20251226"
}

variable "user_data" {
  description = "User Data 脚本路径（用于 K3s 自动点火）"
  type        = string
  default     = ""
}

variable "user_data_vars" {
  description = "User Data 模板变量"
  type        = map(string)
  default     = {}
}

variable "common_tags" {
  description = "通用标签"
  type        = map(string)
  default     = {}
}

variable "eip_bandwidth" {
  description = "EIP 带宽上限（Mbps），按量付费（PayByTraffic）时表示峰值带宽"
  type        = number
  default     = 100
}

variable "ram_role_name" {
  description = "ECS 实例 RAM Role 名称（用于访问 OSS 等资源）"
  type        = string
  default     = ""
}
