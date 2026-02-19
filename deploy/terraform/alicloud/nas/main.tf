# ==============================================================================
# NAS 模块：存储资源
# ==============================================================================

locals {
  access_group_name_lookup = "${var.project_name}_nas_group_${var.env_id}"
}

# 查找已存在的 NAS Access Group（若存在则复用，不重复创建）
data "alicloud_nas_access_groups" "existing" {
  name_regex        = "^${local.access_group_name_lookup}$"
  access_group_type = "Vpc"
}

# 创建新的 NAS File System（当 use_existing_file_system=false 时）
resource "alicloud_nas_file_system" "main" {
  count = var.use_existing_file_system ? 0 : 1

  protocol_type    = "NFS"
  storage_type     = "Performance"
  description      = "${var.project_name}_nas_${var.env_id}"
  file_system_type = "standard"
  encrypt_type     = 0
}

# 创建新的 NAS Access Group（仅当 use_existing_access_group=false 且不存在同名组时）
resource "alicloud_nas_access_group" "main" {
  count = (var.use_existing_access_group || length(data.alicloud_nas_access_groups.existing.groups) > 0) ? 0 : 1

  access_group_name = local.access_group_name_lookup
  access_group_type = "Vpc"
  description       = "${var.project_name}_nas_${var.env_id}"
}

# 本地值：统一 File System ID 和 Access Group 名称引用
locals {
  file_system_id   = var.use_existing_file_system ? var.existing_file_system_id : alicloud_nas_file_system.main[0].id
  access_group_name = var.use_existing_access_group ? var.existing_access_group_name : (
    length(data.alicloud_nas_access_groups.existing.groups) > 0 ? data.alicloud_nas_access_groups.existing.groups[0].access_group_name : alicloud_nas_access_group.main[0].access_group_name
  )
}

# NAS Access Rule（仅在用户显式 use_existing_access_group 时跳过；自动复用已有组时仍需创建规则）
resource "alicloud_nas_access_rule" "vpc" {
  count = var.use_existing_access_group ? 0 : 1

  access_group_name = local.access_group_name
  source_cidr_ip    = var.vpc_cidr
  rw_access_type    = "RDWR"
  user_access_type  = "no_squash"
  priority          = 1
}

resource "alicloud_nas_mount_target" "main" {
  file_system_id    = local.file_system_id
  access_group_name = local.access_group_name
  vswitch_id        = var.vswitch_id
}
