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

variable "oss_bucket_name" {
  description = "OSS 存储桶名称。指定时：检查存在则复用，不存在则创建；未指定（空）时：创建 {project_name}-{env_id}-{random} 新桶。默认可设为 deploy-engine-k3s-storage"
  type        = string
  default     = ""
}

variable "oss_bucket_acl" {
  description = "新建 OSS Bucket 的 ACL：public-read 公网只读；private 仅账号可访问。部分账号禁止 public-read-write"
  type        = string
  default     = "public-read"
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

variable "ssh_allowed_cidr" {
  description = "允许 SSH/6443 的源 CIDR；为空时使用 apply 时检测到的出口 IP/32。可设为 \"0.0.0.0/0\" 以允许任意 IP（仅建议开发环境）"
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

variable "nas_use_existing_mount_target" {
  description = "是否复用已有 NAS 挂载点（为 true 时使用 nas_existing_mount_target_domain，不创建新挂载点）"
  type        = bool
  default     = false
}

variable "nas_existing_mount_target_domain" {
  description = "已存在的 NAS 挂载点域名（如 xxx.cn-hongkong.nas.aliyuncs.com）"
  type        = string
  default     = ""
}

variable "ram_role_name" {
  description = "ECS RAM Role 名称（可选，需在控制台预先创建；不自动创建 Role/Policy）"
  type        = string
  default     = ""
}

variable "init_script_acl" {
  description = "OSS 初始化脚本对象 ACL：public-read 时 ECS 可直接 HTTP 下载；private 时需 ram_role_name。若 apply 报 PutObject acl 不允许则设为 private。"
  type        = string
  default     = "public-read"
}

variable "force_destroy_bucket" {
  description = "销毁 OSS Bucket 时是否先清空对象（非空 Bucket 无法删除时需为 true）"
  type        = bool
  default     = true
}

# ---------- Stage2-06 生产数据环境：独立数据盘（Down 时保留，再次 Up 挂载同盘）----------
variable "enable_prod_data_disk" {
  description = "是否启用独立数据盘（与 ECS 分离；Down 仅回收 ECS/EIP 时保留此盘，再次 Up 可挂载同盘）"
  type        = bool
  default     = false
}

variable "use_existing_data_disk_id" {
  description = "已有数据盘 ID（Down 后再次 Up 时传入，不再新建盘；由 prod-data-env.disk_id 或 TF_VAR 注入）"
  type        = string
  default     = ""
}

variable "data_disk_size" {
  description = "独立数据盘大小（GB）；仅当 enable_prod_data_disk=true 且未传 use_existing_data_disk_id 时新建盘使用"
  type        = number
  default     = 100
}

variable "data_disk_category" {
  description = "独立数据盘类型（需与实例规格兼容）"
  type        = string
  default     = "cloud_essd"
}

# ============================================================================
# v2 新增：多 stack `for_each` 模型
# ============================================================================
# 用法：
#   - 兼容旧调用（stacks = {}）：根级 main.tf 用 enable_spot / instance_type / spot_strategy 等
#     合成单一 "base" stack，等价旧的 spot 实例创建路径。
#   - 新调用：在 tfvars / config 中显式声明 stacks = { base = {...}, train = {...}, infer = {...} }，
#     按 stack_id 起停，配合 terraform apply -target='module.ecs.alicloud_instance.stack["base"]' 等。
# 详见 03_/共享平台基础/.../02_deploy-engine扩展规约.md §2。
variable "stacks" {
  description = "多 stack 定义（map · 字段同 module.ecs.variables.tf 中 stacks）"
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

variable "enable_proxy_ingress" {
  description = "为 3proxy 开放入站（sg-proxy 环境 true）"
  type        = bool
  default     = false
}

variable "anthropic_proxy_port" {
  description = "3proxy 监听端口"
  type        = number
  default     = 3128
}

variable "anthropic_proxy_user" {
  description = "3proxy 认证用户名"
  type        = string
  default     = "ditingproxy"
}

variable "anthropic_proxy_password" {
  description = "3proxy 认证密码（空则复用 instance_password）"
  type        = string
  sensitive   = true
  default     = ""
}
