variable "project_name" {
  description = "项目名称"
  type        = string
}

variable "env_id" {
  description = "环境标识符"
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

variable "user_data" {
  description = "User Data 脚本路径（K3s · 与 user_data_k3s 二选一，向后兼容）"
  type        = string
  default     = ""
}

variable "user_data_vars" {
  description = "User Data 模板变量（注入到所有 stack）"
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

variable "data_disk_id" {
  description = "独立数据盘 ID（非空时挂载到 attach_data_disk=true 的 stack；Down 保留盘时不销毁此盘）"
  type        = string
  default     = ""
}

# ============================================================================
# v2 新增：多 stack `for_each` 模型
# ============================================================================
# 旧的 enable_spot / instance_type / spot_strategy / disk_category 等单实例变量已废弃。
# 现在通过 stacks map 声明若干 stack，每个 stack 一组 ECS + EIP + 系统盘。
# 兼容旧调用：当 stacks = {} 时，根级 main.tf 会用 var.instance_type 等合成一个 "base" stack。
variable "stacks" {
  description = <<EOT
多 stack 定义（按 stack_id 分组创建 ECS + EIP + 系统盘）。
key = stack_id（如 base / train / infer）。

字段说明：
  instance_type        - ECS 规格（如 ecs.u1-c1m4.xlarge / ecs.gn6i-c4g1.xlarge）
  spot_strategy        - SpotAsPriceGo | SpotWithPriceLimit | NoSpot
  spot_price_limit     - Spot 最高出价（NoSpot 时忽略）
  image_family         - ubuntu_22_04 | ubuntu_22_04_gpu（gpu 自动选阿里云 GPU 预装镜像）
  system_disk_gb       - 系统盘 GB
  system_disk_category - cloud_essd | cloud_ssd | cloud_efficiency
  attach_data_disk     - true 时挂载根级 var.data_disk_id（仅 base 应为 true）
  k3s_role             - server | agent；agent 需 join master
  node_labels          - K3s --node-label k=v；如 { "stack.diting/node" = "base" }
  enable_eip           - 是否分配 EIP（base 必 true；train/infer 可走 base 跳板 SSH）
  count                - 0 或 1；0 时本 stack 不创建任何资源（用于"按需起停"）
  bootstrap_mode       - k3s（默认）| proxy（仅 3proxy，不装 K3s）
EOT
  type = map(object({
    instance_type        = string
    spot_strategy        = string
    spot_price_limit     = number
    image_family         = string
    system_disk_gb       = number
    system_disk_category = string
    attach_data_disk     = bool
    k3s_role             = string
    node_labels          = map(string)
    enable_eip           = bool
    count                = number
    bootstrap_mode       = optional(string, "k3s")
  }))
  default = {}
}

variable "user_data_k3s" {
  description = "K3s cloud-init 模板路径"
  type        = string
  default     = ""
}

variable "user_data_proxy" {
  description = "Anthropic 3proxy cloud-init 模板路径"
  type        = string
  default     = ""
}
