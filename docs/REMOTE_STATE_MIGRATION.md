# Terraform Remote State 迁移实践

> 将 Terraform state 从 local backend 迁移到 OSS backend，实现多机器共享同一份 state。

## 背景

local backend 下，`terraform.tfstate` 存储在本地磁盘。每台机器各自维护一份 state，
导致在不同机器执行 `make deploy` 时出现 state 不一致（资源漂移、provider 地址错位、
误删资源等）。改用 OSS backend 后，所有机器读写同一份远程 state，彻底消除此类问题。

---

## 前置条件

| 条件 | 说明 |
|------|------|
| 阿里云 AccessKey | 需有 OSS 读写权限；即 `ALICLOUD_ACCESS_KEY` / `ALICLOUD_SECRET_KEY` |
| Terraform >= 1.0 | 已安装 |
| OSS Bucket | 用于存放 state 文件（下面会创建） |

---

## 步骤

### 1. 创建专用 State Bucket

> 建议单独创建一个 bucket，不与应用数据混用。

```bash
# 使用 aliyun CLI（已安装在服务器）
aliyun oss mb oss://diting-terraform-state --region cn-hongkong

# 开启版本控制（防误删，可回溯历史 state）
aliyun oss bucket-versioning --method put oss://diting-terraform-state enabled
```

如果不想用 CLI，也可以在阿里云控制台 → OSS → 创建 Bucket：
- 名称：`diting-terraform-state`
- 地域：`cn-hongkong`（与部署资源同区域）
- 存储类型：标准
- 版本控制：开启

### 2. 修改 provider.tf

在**源仓库** `/mnt/.diting/deploy-engine` 中修改：

```bash
cd /mnt/.diting/deploy-engine/deploy/terraform/alicloud
```

将 `provider.tf` 中的 `backend "local"` 替换为 `backend "oss"`：

```hcl
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

  backend "oss" {
    bucket = "diting-terraform-state"
    prefix = "deploy-engine/alicloud"
    key    = "terraform.tfstate"
    region = "cn-hongkong"
  }
}

provider "alicloud" {
  region = var.region
}
```

> **key 路径说明**：最终 state 文件存储在
> `oss://diting-terraform-state/deploy-engine/alicloud/terraform.tfstate`。
> 若后续有多个项目/环境，可调整 prefix 实现隔离（如 `diting/prod`）。

### 3. 迁移现有 State

在**有完整 state 的机器**上执行迁移（通常是家里的 Mac，因为那里的 state 最新最准确）。

```bash
# 确保凭证可用
export ALICLOUD_ACCESS_KEY="你的AK"
export ALICLOUD_SECRET_KEY="你的SK"

# 进入 terraform 目录
cd /path/to/deploy-engine/deploy/terraform/alicloud

# 备份本地 state（重要！）
cp terraform.tfstate terraform.tfstate.backup-before-migration

# 执行迁移（terraform 会自动将 local state 上传到 OSS）
terraform init -migrate-state
```

Terraform 会提示：

```
Do you want to copy existing state to the new backend?
  ...
  Enter a value: yes
```

输入 `yes` 确认。

### 4. 验证远程 State

```bash
# 检查远程 state 是否可正常读取
terraform state list

# 检查 OSS 上文件是否存在
aliyun oss ls oss://diting-terraform-state/deploy-engine/alicloud/
```

### 5. 在其他机器同步

在**公司服务器**（或任何其他机器）上：

```bash
# 确保凭证可用
export ALICLOUD_ACCESS_KEY="你的AK"
export ALICLOUD_SECRET_KEY="你的SK"

# 更新 deploy-engine 代码（拉取包含 backend "oss" 的新版本）
cd /mnt/.diting/diting-infra
git submodule update --init --remote deploy-engine

# 删除本地旧 state 和缓存（避免冲突）
cd deploy-engine/deploy/terraform/alicloud
rm -f terraform.tfstate terraform.tfstate.backup
rm -rf .terraform .terraform.lock.hcl

# 重新初始化（自动连接远程 state）
terraform init

# 验证
terraform state list
```

此后，任何机器上执行 `make deploy diting prod` 都会读写同一份远程 state。

---

## State 锁（可选但推荐）

OSS backend 默认**不支持 state 锁**。如果有多人同时执行 `terraform apply` 的可能，
建议配置 TableStore 实现锁机制：

1. 在阿里云控制台 → 表格存储 → 创建实例（如 `diting-tf-lock`）
2. 创建表：名称 `terraform-state-lock`，主键 `LockID`（String 类型）
3. 修改 backend 配置：

```hcl
backend "oss" {
  bucket              = "diting-terraform-state"
  prefix              = "deploy-engine/alicloud"
  key                 = "terraform.tfstate"
  region              = "cn-hongkong"
  tablestore_endpoint = "https://diting-tf-lock.cn-hongkong.ots.aliyuncs.com"
  tablestore_table    = "terraform-state-lock"
}
```

> 如果当前只有你一个人操作，可以先不配锁，后续按需添加。

---

## 回滚（如需退回 local backend）

```bash
# 将 provider.tf 中 backend 改回 "local"，然后：
terraform init -migrate-state
# 输入 yes，远程 state 会下载到本地
```

---

## 常见问题

**Q：迁移后旧的 terraform.tfstate 能删吗？**
A：确认远程 state 正常后（`terraform state list` 输出正确），旧文件可安全删除。
建议保留一段时间作为备份。

**Q：deploy-engine Go 代码需要改吗？**
A：不需要。Go 代码执行 `terraform init` + `terraform apply`，backend 配置由 .tf 文件控制，
代码无感知。

**Q：凭证从哪来？**
A：OSS backend 使用与 alicloud provider 相同的凭证链：
环境变量 `ALICLOUD_ACCESS_KEY` / `ALICLOUD_SECRET_KEY` → `~/.alicloud/config.json` → ECS RAM Role。
