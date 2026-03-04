# ==============================================================================
# NAS 模块：存储资源
# ==============================================================================

locals {
  access_group_name_lookup = "${var.project_name}_nas_group_${var.env_id}"
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

# 创建新的 NAS Access Group（仅当 use_existing_access_group=false 时）
# 注意：不再根据 data 自动 count=0，否则会误销毁本模块已创建的 Access Group（导致 AlreadyAttached）
resource "alicloud_nas_access_group" "main" {
  count = var.use_existing_access_group ? 0 : 1

  access_group_name = local.access_group_name_lookup
  access_group_type = "Vpc"
  description       = "${var.project_name}_nas_${var.env_id}"
}

# 本地值：统一 File System ID 和 Access Group 名称引用
locals {
  file_system_id    = var.use_existing_file_system ? var.existing_file_system_id : alicloud_nas_file_system.main[0].id
  access_group_name = var.use_existing_access_group ? var.existing_access_group_name : alicloud_nas_access_group.main[0].access_group_name
}

# NAS Access Rule：复用已有访问组时也创建，确保 VPC 网段始终有权限挂载，避免「mount system call failed」
resource "alicloud_nas_access_rule" "vpc" {
  count = 1

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
