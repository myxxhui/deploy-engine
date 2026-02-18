# ==============================================================================
# ECS 模块：计算资源（支持 K3s 自动点火）
# ==============================================================================

data "alicloud_images" "ubuntu_22_04" {
  name_regex    = "^ubuntu_22_04_x64"
  owners        = "system"
  status        = "Available"
  most_recent   = true
  instance_type = var.instance_type
}

# 从 VSwitch 获取可用区（当 availability_zone 为空时）
data "alicloud_vswitches" "existing" {
  count = var.availability_zone == "" ? 1 : 0
  ids   = [var.vswitch_id]
}

locals {
  image_id = length(data.alicloud_images.ubuntu_22_04.images) > 0 ? data.alicloud_images.ubuntu_22_04.images[0].id : var.image_id

  # 如果 availability_zone 为空，从 VSwitch 获取
  availability_zone = var.availability_zone != "" ? var.availability_zone : (
    length(data.alicloud_vswitches.existing) > 0 && length(data.alicloud_vswitches.existing[0].vswitches) > 0 ?
    data.alicloud_vswitches.existing[0].vswitches[0].zone_id : ""
  )
}

resource "alicloud_instance" "spot" {
  count = var.enable_spot ? 1 : 0

  instance_name     = "${var.project_name}-spot-${var.env_id}"
  instance_type     = var.instance_type
  image_id          = local.image_id
  availability_zone = local.availability_zone
  security_groups   = [var.security_group_id]
  vswitch_id        = var.vswitch_id
  password          = var.instance_password
  spot_strategy     = var.spot_strategy
  spot_price_limit  = var.spot_price_limit

  system_disk_category = var.disk_category
  system_disk_size     = var.disk_size

  # RAM Role：用于访问 OSS 等资源（如果指定）
  role_name = var.ram_role_name != "" ? var.ram_role_name : null

  # User Data：支持传入 user_data 脚本路径（用于 K3s 自动点火）
  # 合并 user_data_vars 和 EIP 地址（如果 EIP 已创建）
  user_data = var.user_data != "" ? base64encode(templatefile(var.user_data, merge(
    var.user_data_vars,
    {
      public_ip = var.enable_spot ? try(alicloud_eip_address.spot[0].ip_address, "") : ""
    }
  ))) : ""

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-spot-instance-${var.env_id}"
  })
}

# EIP：按量付费（PayByTraffic）+ 带宽上限（Mbps）
resource "alicloud_eip_address" "spot" {
  count                = var.enable_spot ? 1 : 0
  bandwidth            = var.eip_bandwidth
  internet_charge_type = "PayByTraffic" # 按流量计费（按量付费）
  payment_type         = "PostPaid"

  lifecycle {
    ignore_changes = [payment_type]
  }
}

resource "alicloud_eip_association" "spot" {
  count         = var.enable_spot ? 1 : 0
  allocation_id = alicloud_eip_address.spot[0].id
  instance_id   = alicloud_instance.spot[0].id
}

# 按量 ECS（enable_spot = false 时使用）
resource "alicloud_eip_address" "on_demand" {
  count                = var.enable_spot ? 0 : 1
  bandwidth            = var.eip_bandwidth
  internet_charge_type = "PayByTraffic"
  payment_type         = "PostPaid"

  lifecycle {
    ignore_changes = [payment_type]
  }
}

resource "alicloud_instance" "on_demand" {
  count = var.enable_spot ? 0 : 1

  instance_name     = "${var.project_name}-on-demand-${var.env_id}"
  instance_type     = var.instance_type
  image_id          = local.image_id
  availability_zone = local.availability_zone
  security_groups   = [var.security_group_id]
  vswitch_id        = var.vswitch_id
  password          = var.instance_password

  system_disk_category = var.disk_category
  system_disk_size     = var.disk_size

  role_name = var.ram_role_name != "" ? var.ram_role_name : null

  user_data = var.user_data != "" ? base64encode(templatefile(var.user_data, merge(
    var.user_data_vars,
    {
      public_ip = try(alicloud_eip_address.on_demand[0].ip_address, "")
    }
  ))) : ""

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-on-demand-instance-${var.env_id}"
  })

  depends_on = [alicloud_eip_address.on_demand]
}

resource "alicloud_eip_association" "on_demand" {
  count         = var.enable_spot ? 0 : 1
  allocation_id = alicloud_eip_address.on_demand[0].id
  instance_id   = alicloud_instance.on_demand[0].id
}

