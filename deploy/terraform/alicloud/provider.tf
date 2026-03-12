terraform {
  required_version = ">= 1.0"

  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = "~> 1.200"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  # 多环境共享 state：bucket/region 固定，prefix 由 deploy-engine 在 terraform init 时
  # 通过 -backend-config=prefix=<project>/<env> 动态注入，实现 diting/prod、diting/dev 隔离。
  # 详见 docs/REMOTE_STATE_MIGRATION.md
  backend "oss" {
    bucket = "diting-terraform-state"
    region = "cn-hongkong"
  }
}

provider "alicloud" {
  region = var.region
}
