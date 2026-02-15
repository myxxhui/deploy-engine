# ==============================================================================
# VPC 模块：网络资源
# ==============================================================================

data "alicloud_zones" "available" {
  count                      = var.use_existing_vpc && var.use_existing_vswitch ? 0 : 1
  available_instance_type     = var.instance_type
  available_resource_creation = "Instance"
}

locals {
  # 当复用 VPC 和 VSwitch 时，不需要查询可用区（ECS 模块会从 VSwitch 获取）
  # 当创建新资源时，使用查询到的可用区
  selected_zone = var.use_existing_vpc && var.use_existing_vswitch ? null : data.alicloud_zones.available[0].zones[0].id
}

# 创建新的 VPC（当 use_existing_vpc=false 时）
resource "alicloud_vpc" "main" {
  count      = var.use_existing_vpc ? 0 : 1
  vpc_name   = "${var.project_name}-vpc-${var.env_id}"
  cidr_block = var.vpc_cidr
}

# 创建新的 VSwitch（当 use_existing_vswitch=false 时）
resource "alicloud_vswitch" "main" {
  count       = var.use_existing_vswitch ? 0 : 1
  vpc_id      = var.use_existing_vpc ? var.existing_vpc_id : alicloud_vpc.main[0].id
  cidr_block  = var.vswitch_cidr
  zone_id     = local.selected_zone
  vswitch_name = "${var.project_name}-vswitch-${var.env_id}"
}

# 本地值：统一 VPC 和 VSwitch ID 引用
locals {
  vpc_id     = var.use_existing_vpc ? var.existing_vpc_id : alicloud_vpc.main[0].id
  vswitch_id = var.use_existing_vswitch ? var.existing_vswitch_id : alicloud_vswitch.main[0].id
  vpc_cidr   = var.use_existing_vpc ? var.existing_vpc_cidr : var.vpc_cidr
}
