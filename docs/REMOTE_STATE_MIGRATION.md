# Terraform Remote State 迁移实践

> 将 Terraform state 从 local backend 迁移到 OSS backend，实现多机器共享、多环境隔离。

## 背景

local backend 下，`terraform.tfstate` 存储在本地磁盘。每台机器各自维护一份 state，
导致在不同机器执行 `make deploy` 时出现 state 不一致（资源漂移、provider 地址错位、
误删资源等）。改用 OSS backend 后，所有机器读写同一份远程 state，彻底消除此类问题。

---

## 多环境隔离方案

deploy-engine 通过 `terraform init -backend-config=prefix=<project>/<env>` 动态注入
OSS 路径前缀，实现同一个 Bucket 下不同环境的 state 隔离。

```
oss://deploy-engine-k3s-storage/
├── diting/prod/terraform.tfstate    ← make deploy diting prod
├── diting/dev/terraform.tfstate     ← make deploy diting dev
├── lighthouse/dev/terraform.tfstate ← make deploy lighthouse dev
└── ...
```

`provider.tf` 中只固定 `bucket` 和 `region`（不变的部分），`prefix` 由 Go 代码根据
`-project` 和 `-env` 参数在 `terraform init` 时注入：

```hcl
# provider.tf
backend "oss" {
  bucket = "deploy-engine-k3s-storage"
  region = "cn-hongkong"
}
```

```go
// driver.go — terraformInit
args := []string{"init", "-backend-config=prefix=" + project + "/" + env}
```

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

> 单独创建一个 bucket，不与应用数据混用。

```bash
# 使用 aliyun CLI
aliyun oss mb oss://deploy-engine-k3s-storage --region cn-hongkong

# 开启版本控制（防误删，可回溯历史 state）
aliyun oss bucket-versioning --method put oss://deploy-engine-k3s-storage enabled
```

也可以在阿里云控制台 → OSS → 创建 Bucket：
- 名称：`deploy-engine-k3s-storage`
- 地域：`cn-hongkong`（与部署资源同区域）
- 存储类型：标准
- 版本控制：开启

### 2. 在有完整 state 的机器上迁移（家里的 Mac）

代码已经把 `provider.tf` 改为 `backend "oss"`，拉取最新代码后迁移：

```bash
export ALICLOUD_ACCESS_KEY="你的AK"
export ALICLOUD_SECRET_KEY="你的SK"

cd deploy-engine/deploy/terraform/alicloud

# 备份本地 state
cp terraform.tfstate terraform.tfstate.backup-before-migration

# 迁移：terraform 会提示是否拷贝现有 state 到新 backend
# -backend-config=prefix 指定该环境的 state 路径
terraform init \
  -migrate-state \
  -backend-config=prefix=diting/prod
```

Terraform 提示：

```
Do you want to copy existing state to the new backend?
  Enter a value: yes
```

输入 `yes`。

### 3. 验证远程 State

```bash
# 验证 state 可正常读取
terraform state list

# 验证 OSS 上文件存在
aliyun oss ls oss://deploy-engine-k3s-storage/diting/prod/
```

预期输出包含 `terraform.tfstate`。

### 4. 在其他机器同步（公司服务器）

```bash
export ALICLOUD_ACCESS_KEY="你的AK"
export ALICLOUD_SECRET_KEY="你的SK"

# 更新代码
cd /mnt/.diting/diting-infra
git submodule update --init --remote deploy-engine

# 清理旧的本地 state 和缓存
cd deploy-engine/deploy/terraform/alicloud
rm -f terraform.tfstate terraform.tfstate.backup
rm -rf .terraform .terraform.lock.hcl

# 初始化（自动连接远程 state）
terraform init -backend-config=prefix=diting/prod

# 验证
terraform state list
```

### 5. 日常使用

迁移完成后，`make deploy` / `make down` 无需额外操作。deploy-engine Go 代码会自动
根据 project 和 env 参数注入正确的 prefix：

```bash
# 部署 prod — state 写入 oss://deploy-engine-k3s-storage/diting/prod/
make deploy diting prod

# 部署 dev — state 写入 oss://deploy-engine-k3s-storage/diting/dev/
make deploy diting dev

# 销毁 prod — 读取 oss://deploy-engine-k3s-storage/diting/prod/
make down diting prod
```

---

## State 锁（可选但推荐）

OSS backend 默认不支持 state 锁。如果有多人同时执行 `terraform apply` 的可能，
建议配置 TableStore 实现锁机制：

1. 在阿里云控制台 → 表格存储 → 创建实例（如 `diting-tf-lock`）
2. 创建表：名称 `terraform-state-lock`，主键 `LockID`（String 类型）
3. 修改 `provider.tf` 中的 backend：

```hcl
backend "oss" {
  bucket              = "deploy-engine-k3s-storage"
  region              = "cn-hongkong"
  tablestore_endpoint = "https://diting-tf-lock.cn-hongkong.ots.aliyuncs.com"
  tablestore_table    = "terraform-state-lock"
}
```

> 如果当前只有你一个人操作，可以先不配锁，后续按需添加。

---

## 回滚（如需退回 local backend）

```bash
# 将 provider.tf 中 backend 改回 "local" { path = "terraform.tfstate" }，然后：
terraform init -migrate-state
# 输入 yes，远程 state 会下载到本地
```

---

## 常见问题

**Q：迁移后旧的 terraform.tfstate 能删吗？**
A：确认远程 state 正常后（`terraform state list` 输出正确），旧文件可安全删除。
建议保留一段时间作为备份。

**Q：deploy-engine Go 代码做了什么？**
A：`driver.go` 中的 `terraformInit` 方法在 `terraform init` 时自动传入
`-backend-config=prefix=<project>/<env>`，`Up()` 和 `Down()` 都会调用，
确保每个环境读写自己的 state。

**Q：凭证从哪来？**
A：OSS backend 使用与 alicloud provider 相同的凭证链：
环境变量 `ALICLOUD_ACCESS_KEY` / `ALICLOUD_SECRET_KEY` → `~/.alicloud/config.json` → ECS RAM Role。

**Q：新增环境需要额外操作吗？**
A：不需要。首次 `make deploy <project> <env>` 时，`terraform init` 会在 OSS 上
自动创建 `<project>/<env>/terraform.tfstate`，无需手动干预。
