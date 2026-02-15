# ==============================================================================
# Deploy Engine - 阿里云基础设施部署入口（自包含，path.root = 本目录）
# ==============================================================================
# 配置通过 -var-file 从 config/environments/{env}/terraform.tfvars 加载
# path.root = deploy/terraform/alicloud；bootstrap 在 ../../bootstrap；config 在 ../../../config

locals {
  config_file_path = var.config_file != "" ? (
    startswith(var.config_file, "/") ? var.config_file : "${path.root}/../../../${var.config_file}"
  ) : "${path.root}/../../../config/environments/${var.env_id}/titan.yaml"

  raw_config = try(
    yamldecode(file(local.config_file_path)),
    {}
  )

  project_name          = try(local.raw_config.global.project_name, local.raw_config.project_name, "deploy-engine")
  region                = try(local.raw_config.global.infrastructure.region, local.raw_config.infrastructure.region, var.region)
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
}

module "vpc" {
  source = "./vpc"

  project_name         = local.project_name
  env_id               = var.env_id
  instance_type        = var.instance_type
  vpc_cidr             = var.vpc_cidr
  vswitch_cidr         = var.vswitch_cidr
  use_existing_vpc     = var.vpc_use_existing
  existing_vpc_id      = var.vpc_existing_id
  existing_vpc_cidr    = var.vpc_existing_cidr
  use_existing_vswitch = var.vswitch_use_existing
  existing_vswitch_id  = var.vswitch_existing_id
}

module "security" {
  source = "./security"

  project_name                = local.project_name
  env_id                      = var.env_id
  vpc_id                      = module.vpc.vpc_id
  vpc_cidr                    = module.vpc.vpc_cidr
  use_existing_security_group = var.security_group_use_existing
  existing_security_group_id  = var.security_group_existing_id
}

module "nas" {
  source = "./nas"

  project_name               = local.project_name
  env_id                     = var.env_id
  vpc_cidr                   = module.vpc.vpc_cidr
  vswitch_id                 = module.vpc.vswitch_id
  use_existing_file_system   = var.nas_use_existing_file_system
  existing_file_system_id    = var.nas_existing_file_system_id
  use_existing_access_group  = var.nas_use_existing_access_group
  existing_access_group_name = var.nas_existing_access_group_name
}

locals {
  init_script_content = templatefile("${path.root}/../../bootstrap/scripts/titan-init-full.sh", {
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
  use_existing_bucket  = var.oss_use_existing_bucket
  existing_bucket_name = var.oss_existing_bucket_name
  nas_mount_domain     = module.nas.nas_mount_domain
  acr_server           = var.acr_server != "" ? var.acr_server : local.acr_server
  acr_namespace        = var.acr_namespace != "" ? var.acr_namespace : local.acr_namespace
  init_script_content  = local.init_script_content
}

module "ecs" {
  source = "./ecs"

  project_name      = local.project_name
  env_id            = var.env_id
  enable_spot       = var.enable_spot
  instance_type     = var.instance_type
  instance_password = var.instance_password
  availability_zone = try(module.vpc.selected_zone, "")
  security_group_id = module.security.security_group_id
  vswitch_id        = module.vpc.vswitch_id
  spot_strategy     = var.spot_strategy
  spot_price_limit  = var.spot_price_limit
  disk_category     = var.disk_category
  disk_size         = var.disk_size
  image_id          = var.image_id
  common_tags       = local.common_tags
  eip_bandwidth     = var.eip_bandwidth
  ram_role_name     = var.ram_role_name
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
