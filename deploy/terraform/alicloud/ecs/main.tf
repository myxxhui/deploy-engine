# ==============================================================================
# ECS 模块（v2 · 多 stack for_each）
# ==============================================================================
# 设计要点（与 03_/共享平台基础/.../02_deploy-engine扩展规约.md §2.2 一致）：
#   - 用 for_each 按 stack_id 分组创建 ECS + EIP + 系统盘
#   - count > 0 才纳入 local.active_stacks → 实际创建
#   - GPU 镜像分支：image_family == "ubuntu_22_04_gpu" → 阿里云 GPU 预装镜像
#   - data_disk 仅挂 attach_data_disk = true 的 stack（避免 train/infer 误挂业务盘）
#   - tier-1 释放：terraform destroy -target='alicloud_instance.stack["<id>"]' ...
# ==============================================================================

locals {
  # 仅保留 count > 0 的 stack（实际要创建）
  active_stacks = { for k, s in var.stacks : k => s if s.count > 0 }
}

# 按 stack 选镜像：ubuntu_22_04 vs ubuntu_22_04_gpu
data "alicloud_images" "by_family" {
  for_each      = local.active_stacks
  owners        = "system"
  status        = "Available"
  most_recent   = true
  instance_type = each.value.instance_type
  name_regex = (
    each.value.image_family == "ubuntu_22_04_gpu"
    ? "^ubuntu_22_04_x64_100G_with_gpu_driver_and_cuda_alibase"
    : "^ubuntu_22_04_x64"
  )
}

# 从 VSwitch 获取可用区（当 availability_zone 为空时）
data "alicloud_vswitches" "existing" {
  count = var.availability_zone == "" ? 1 : 0
  ids   = [var.vswitch_id]
}

locals {
  resolved_availability_zone = var.availability_zone != "" ? var.availability_zone : (
    length(data.alicloud_vswitches.existing) > 0 && length(data.alicloud_vswitches.existing[0].vswitches) > 0
    ? data.alicloud_vswitches.existing[0].vswitches[0].zone_id
    : ""
  )
}

# ============================================================================
# EIP（先于 ECS 创建，user-data 模板可注入 public_ip）
# ============================================================================
resource "alicloud_eip_address" "stack" {
  for_each             = { for k, s in local.active_stacks : k => s if s.enable_eip }
  bandwidth            = var.eip_bandwidth
  internet_charge_type = "PayByTraffic"
  payment_type         = "PostPaid"
  lifecycle {
    ignore_changes = [payment_type]
  }
}

# ============================================================================
# ECS 实例（按 stack_id for_each）
# ============================================================================
resource "alicloud_instance" "stack" {
  for_each = local.active_stacks

  instance_name        = "${var.project_name}-${each.key}-${var.env_id}"
  instance_type        = each.value.instance_type
  image_id             = data.alicloud_images.by_family[each.key].images[0].id
  availability_zone    = local.resolved_availability_zone
  security_groups      = [var.security_group_id]
  vswitch_id           = var.vswitch_id
  password             = var.instance_password
  spot_strategy        = each.value.spot_strategy
  spot_price_limit     = each.value.spot_price_limit
  system_disk_category = each.value.system_disk_category
  system_disk_size     = each.value.system_disk_gb
  role_name            = var.ram_role_name != "" ? var.ram_role_name : null

  user_data = var.user_data != "" ? base64encode(templatefile(
    var.user_data,
    merge(var.user_data_vars, {
      stack_id    = each.key
      k3s_role    = each.value.k3s_role
      node_labels = join(",", [for k, v in each.value.node_labels : "${k}=${v}"])
      public_ip   = each.value.enable_eip ? try(alicloud_eip_address.stack[each.key].ip_address, "") : ""
    })
  )) : ""

  tags = merge(var.common_tags, {
    Name    = "${var.project_name}-${each.key}-${var.env_id}"
    StackId = each.key
  })
}

# ============================================================================
# EIP <-> Instance 绑定
# ============================================================================
resource "alicloud_eip_association" "stack" {
  for_each      = { for k, s in local.active_stacks : k => s if s.enable_eip }
  allocation_id = alicloud_eip_address.stack[each.key].id
  instance_id   = alicloud_instance.stack[each.key].id
}

# ============================================================================
# 独立数据盘挂载（仅 attach_data_disk = true 的 stack 且 data_disk_id 非空）
# 用 attachment 资源 + 根级 prevent_destroy 保护，确保 Down 时 detach 但盘不被销
# ============================================================================
resource "alicloud_disk_attachment" "stack" {
  for_each    = { for k, s in local.active_stacks : k => s if s.attach_data_disk && var.data_disk_id != "" }
  instance_id = alicloud_instance.stack[each.key].id
  disk_id     = var.data_disk_id
}
