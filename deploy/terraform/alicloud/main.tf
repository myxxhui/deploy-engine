# ==============================================================================
# Deploy Engine - 阿里云基础设施部署入口（自包含，path.root = 本目录）
# ==============================================================================
# config_file 由引擎传入绝对路径，不在此处拼接 path.root。
# path.root = deploy/terraform/alicloud；bootstrap 在 ../../bootstrap。

locals {
  config_file_path = var.config_file

  raw_config = try(
    var.config_file != "" ? yamldecode(file(local.config_file_path)) : {},
    {}
  )

  project_name = try(local.raw_config.global.project_name, local.raw_config.project_name, "deploy-engine")
  # region 仅从 var.region（tfvars）取，不受 config_file YAML 影响，确保 tfvars 的 region 生效
  region                = var.region
  env_id_for_bucket     = try(local.raw_config.global.env, var.env_id)
  acr_server            = try(local.raw_config.registry.server, var.acr_server, "")
  acr_namespace         = try(local.raw_config.registry.namespace, var.acr_namespace, "")
  k3s_api_server_domain = try(local.raw_config.global.k3s.apiServer.domain, "")

  common_tags = {
    Project     = local.project_name
    Owner       = try(local.raw_config.global.owner, local.raw_config.owner, "platform-team")
    Environment = try(local.raw_config.global.environment, local.raw_config.environment, var.env_id)
    ManagedBy   = "Terraform"
  }

  # 有 existing_* ID 即复用，无需再设 use_existing_* = true；兼容旧用法
  use_existing_vpc     = var.vpc_use_existing || var.vpc_existing_id != ""
  use_existing_vswitch = var.vswitch_use_existing || var.vswitch_existing_id != ""
  use_existing_sg      = var.security_group_use_existing || var.security_group_existing_id != ""
  use_existing_nas_fs  = var.nas_use_existing_file_system || var.nas_existing_file_system_id != ""
  use_existing_nas_ag  = var.nas_use_existing_access_group || var.nas_existing_access_group_name != ""
  use_existing_nas_mt  = var.nas_use_existing_mount_target || var.nas_existing_mount_target_domain != ""
}

module "vpc" {
  source = "./vpc"

  project_name         = local.project_name
  env_id               = var.env_id
  instance_type        = var.instance_type
  vpc_cidr             = var.vpc_cidr
  vswitch_cidr         = var.vswitch_cidr
  use_existing_vpc     = local.use_existing_vpc
  existing_vpc_id      = var.vpc_existing_id
  existing_vpc_cidr    = local.use_existing_vpc && var.vpc_existing_cidr != "" ? var.vpc_existing_cidr : var.vpc_cidr
  use_existing_vswitch = local.use_existing_vswitch
  existing_vswitch_id  = var.vswitch_existing_id
}

module "security" {
  source = "./security"

  project_name                = local.project_name
  env_id                      = var.env_id
  vpc_id                      = module.vpc.vpc_id
  vpc_cidr                    = module.vpc.vpc_cidr
  use_existing_security_group = local.use_existing_sg
  existing_security_group_id  = var.security_group_existing_id
  ssh_allowed_cidr            = var.ssh_allowed_cidr
}

module "nas" {
  source = "./nas"

  project_name                 = local.project_name
  env_id                       = var.env_id
  vpc_cidr                     = module.vpc.vpc_cidr
  vswitch_id                   = module.vpc.vswitch_id
  use_existing_file_system     = local.use_existing_nas_fs
  existing_file_system_id      = var.nas_existing_file_system_id
  use_existing_access_group    = local.use_existing_nas_ag
  existing_access_group_name   = var.nas_existing_access_group_name
  use_existing_mount_target    = local.use_existing_nas_mt
  existing_mount_target_domain = var.nas_existing_mount_target_domain
}

locals {
  init_script_content = templatefile("${path.root}/../../bootstrap/scripts/k3s-init-full.sh", {
    nas_mount_domain = module.nas.nas_mount_domain
    project_name     = local.project_name
    oss_bucket_name  = ""
    oss_endpoint     = ""
    oss_region       = var.region
    acr_server       = var.acr_server != "" ? var.acr_server : local.acr_server
    acr_namespace    = var.acr_namespace != "" ? var.acr_namespace : local.acr_namespace
  })
}

module "oss" {
  source = "./oss"

  project_name         = local.project_name
  force_destroy_bucket = var.force_destroy_bucket
  env_id               = local.env_id_for_bucket
  vpc_id               = module.vpc.vpc_id
  region               = var.region
  common_tags          = local.common_tags
  oss_bucket_name      = var.oss_bucket_name
  bucket_acl           = var.oss_bucket_acl
  nas_mount_domain     = module.nas.nas_mount_domain
  acr_server           = var.acr_server != "" ? var.acr_server : local.acr_server
  acr_namespace        = var.acr_namespace != "" ? var.acr_namespace : local.acr_namespace
  init_script_content  = local.init_script_content
  init_script_acl      = var.init_script_acl
}

# ---------- Stage2-06 生产数据环境：独立数据盘（根级资源，Down 时 -target=module.ecs 不销毁此盘）----------
data "alicloud_vswitches" "data_disk_zone" {
  count = var.enable_prod_data_disk && var.use_existing_data_disk_id == "" ? 1 : 0
  ids   = [module.vpc.vswitch_id]
}

resource "alicloud_disk" "prod_data" {
  count = var.enable_prod_data_disk && var.use_existing_data_disk_id == "" ? 1 : 0

  zone_id              = data.alicloud_vswitches.data_disk_zone[0].vswitches[0].zone_id
  category             = var.data_disk_category
  size                 = var.data_disk_size
  disk_name            = "${local.project_name}-prod-data-disk-${var.env_id}"
  description          = "Stage2-06 生产数据环境独立数据盘（Down 保留）"
  delete_with_instance = false

  tags = merge(local.common_tags, {
    Name = "${local.project_name}-prod-data-disk-${var.env_id}"
  })

  # v2: prevent_destroy 保护永驻数据盘；仅 FULL_DESTROY 时由 Makefile state rm 后销
  lifecycle {
    prevent_destroy = true
  }
}

locals {
  # 数据盘 ID：已有则用已有，否则用新建盘；未启用则为空
  data_disk_id = var.enable_prod_data_disk ? (var.use_existing_data_disk_id != "" ? var.use_existing_data_disk_id : try(alicloud_disk.prod_data[0].id, "")) : ""
}

locals {
  # v2 多 stack：若 tfvars/config 未提供 stacks，则根据旧变量合成单一 "base" stack（向后兼容）。
  # 旧 enable_spot=true → spot_strategy；enable_spot=false → "NoSpot"。
  legacy_base_stack = {
    instance_type        = var.instance_type
    spot_strategy        = var.enable_spot ? var.spot_strategy : "NoSpot"
    spot_price_limit     = var.spot_price_limit
    image_family         = "ubuntu_22_04"
    system_disk_gb       = var.disk_size
    system_disk_category = var.disk_category
    attach_data_disk     = true
    k3s_role             = "server"
    node_labels          = { "stack.diting/node" = "base" }
    enable_eip           = true
    count                = 1
  }

  effective_stacks = length(var.stacks) > 0 ? var.stacks : { base = local.legacy_base_stack }
}

module "ecs" {
  source = "./ecs"

  project_name      = local.project_name
  env_id            = var.env_id
  instance_password = var.instance_password
  availability_zone = try(module.vpc.selected_zone, "")
  security_group_id = module.security.security_group_id
  vswitch_id        = module.vpc.vswitch_id
  common_tags       = local.common_tags
  eip_bandwidth     = var.eip_bandwidth
  ram_role_name     = var.ram_role_name
  data_disk_id      = local.data_disk_id
  stacks            = local.effective_stacks
  user_data         = "${path.root}/../../bootstrap/scripts/user-data.sh"
  user_data_vars = {
    nas_mount_domain      = module.nas.nas_mount_domain
    project_name          = local.project_name
    oss_bucket_name       = module.oss.bucket_name
    oss_endpoint          = module.oss.bucket_endpoint
    oss_region            = module.oss.bucket_region
    acr_server            = var.acr_server != "" ? var.acr_server : local.acr_server
    acr_namespace         = var.acr_namespace != "" ? var.acr_namespace : local.acr_namespace
    k3s_api_server_domain = local.k3s_api_server_domain
  }
}
