# 验证此模块逻辑（端到端步骤）

本文档面向两类场景：**① 在 deploy-engine 仓库内做一次完整验证**（不依赖业务仓）；**② 在任意业务仓中引用 deploy-engine 完成部署**（配置在业务仓、不修改部署模块）。配置均从 **ConfigRoot** 读取，详见《配置说明》。下文中请将 `<project>`、`<env>` 替换为你的项目名与环境名（如 myapp、dev）。

---

## 一、deploy-engine 本地验证

**目标**：不依赖业务仓，仅在 deploy-engine 根目录完成从「准备凭证与配置」到「验收集群并回收」的完整流程，确认模块行为符合预期。

### 1.1 前置条件

- **已安装**：Go 1.22+、Terraform（>= 1.0，PATH 可用）、sshpass（用于 get-kubeconfig 从 ECS 拉取 kubeconfig）。
- **阿里云凭证**：设置环境变量 **ALICLOUD_ACCESS_KEY**、**ALICLOUD_SECRET_KEY**，或使用配置文件 `~/.alicloud/config.json`。勿提交敏感信息到仓库；生产/CI 建议用环境变量或密钥服务注入。
- **网络**：本机可访问阿里云 API 与目标地域（如 cn-hongkong）。

### 1.2 准备配置（ConfigRoot = deploy-engine 的 config/）

当在 deploy-engine 根目录执行时，默认 `-config=config/deploy.yaml`，**ConfigRoot = deploy-engine 的 config/**，所有配置文件均在 **config/** 下。**必须先从示例复制为正式配置文件后再执行部署，勿直接使用 .example 文件**（引擎按扩展名 .yaml/.json 解析，.example 会导致解析错误）。请将 `<project>`、`<env>` 替换为你的项目名与环境名。

**目录与文件清单**（来源以 **config/examples/ 下实际存在的文件**为准）

| 用途 | 文件名（ConfigRoot = config/ 下） | 来源（config/examples/ 内实际存在） |
|------|-----------------------------------|--------------------------------------|
| 部署配置 | `deploy.yaml` 或 `<project>.yaml` | **deploy.yaml.example** → 复制为 config/deploy.yaml |
| Terraform 变量 | `terraform-<project>-<env>.tfvars`（无 project 时为 `terraform-<env>.tfvars`） | **terraform-dev.tfvars.example** → 复制为 config/terraform-<project>-<env>.tfvars（或 config/terraform-<env>.tfvars） |
| 环境 YAML | `<project>-<env>.yaml`（无 project 时为 `default-<env>.yaml`） | **default-dev.yaml.example** → 复制为 config/<project>-<env>.yaml（或 config/default-<env>.yaml） |

**操作示例（以 myapp、dev 为例；复制到 config/ 后填写实际值）**

```bash
# 在 deploy-engine 根目录执行；示例在 config/examples/，目标在 config/
cp config/examples/deploy.yaml.example config/deploy.yaml
cp config/examples/terraform-dev.tfvars.example config/terraform-myapp-dev.tfvars
cp config/examples/default-dev.yaml.example config/myapp-dev.yaml
# 编辑 config/terraform-myapp-dev.tfvars（instance_password、region 等）、config/myapp-dev.yaml（global.project_name、k3s.apiServer.domain）
# 无 project 时：cp config/examples/terraform-dev.tfvars.example config/terraform-dev.tfvars
# 无 project 时：cp config/examples/default-dev.yaml.example config/default-dev.yaml
```

- **tfvars 必填**：`instance_password`（至少 8 位）；建议使用环境变量 **TF_VAR_instance_password**，则 tfvars 中可写占位或省略。
- **YAML**：需包含 Terraform 所需字段（如 **global.project_name**、**global.k3s.apiServer.domain**）；本模块仅使用 global/registry 等字段，其余由外部消费。

### 1.3 执行部署

在 **deploy-engine 根目录** 执行：

```bash
make deploy <project> <env>
```

例如：`make deploy myapp dev`。

**预期输出**：终端输出 Terraform init/apply、get-kubeconfig 等日志；若成功，最后打印「deploy ok, state: .deploy/state-<project>-<env>.json」。state 文件生成于 `.deploy/state-<project>-<env>.json`，kubeconfig 生成于 `~/.kube/config-<project>-<env>`。

### 1.4 判断 K3s 是否就绪

- **成功**：get-kubeconfig 脚本正常退出，且存在 `~/.kube/config-<project>-<env>`。
- **超时**：若报「K3s 未在预期时间内就绪」，说明 ECS 与 Terraform 已成功，仅 K3s 启动或网络较慢。可稍等后执行 `make kubeconfig <project> <env>` 重试，或增大环境变量 **KUBECONFIG_MAX_RETRIES**、**KUBECONFIG_SLEEP_SEC** 后再次执行 deploy 或 kubeconfig。

### 1.5 验收集群

**推荐**：无需手动 export KUBECONFIG，直接执行（自动使用对应 kubeconfig）：

```bash
make nodes <project> <env>
```

例如：`make nodes myapp dev`。等价于 `KUBECONFIG=~/.kube/config-<project>-<env> kubectl get nodes`。

**成功表现**：能看到节点且状态为 Ready，即表示集群可用。若需在后续命令中继续使用该集群，可执行 `export KUBECONFIG=~/.kube/config-<project>-<env>` 后再执行其他 kubectl。

### 1.6 验证后回收（必做）

无论验证是否通过，**均须执行 Down 释放资源**（含竞价实例 ECS）：

```bash
make down <project> <env>
```

执行后 ECS 与 EIP 等将被销毁，kubeconfig 文件会被删除；VPC、NAS、OSS 等按当前设计保留。

### 1.7 本仓验证成功标准

- 存在 `.deploy/state-<project>-<env>.json`。
- 存在 `~/.kube/config-<project>-<env>`。
- `make nodes <project> <env>` 能列出节点且为 Ready（无需手动 export KUBECONFIG）。
- 执行 `make down <project> <env>` 后，ECS/EIP 等资源释放，kubeconfig 被删除。

### 1.8 常见失败与排查

| 现象 | 可能原因 | 建议操作 |
|------|----------|----------|
| Terraform apply 报错 | 凭证、地域、配额、tfvars 语法 | 检查 AKSK、地域与配额；到 `deploy/terraform/alicloud` 执行 `terraform plan -var-file=...` 查看差异。详见 README「常见问题与排错」。 |
| get-kubeconfig 超时 | K3s 启动或网络较慢 | 增大 `KUBECONFIG_MAX_RETRIES`、`KUBECONFIG_SLEEP_SEC`；或稍后单独执行 `make kubeconfig <project> <env>`。 |
| instance_password 未设置 | tfvars 未填或环境变量未设 | 设置环境变量 `TF_VAR_instance_password` 或在 tfvars 中填写至少 8 位密码。 |
| 配置文件不存在 | 未在 ConfigRoot 下按扁平命名准备文件 | 确认 **config/** 下存在 `terraform-<project>-<env>.tfvars`、`<project>-<env>.yaml` 及 **config/deploy.yaml**，见 1.2。 |
| 网络/凭证失败 | 本机无法访问阿里云或 AKSK 错误 | 检查网络与 `ALICLOUD_ACCESS_KEY`、`ALICLOUD_SECRET_KEY` 或 `~/.alicloud/config.json`。 |
| InvalidAccessGroup.AlreadyAttached | NAS Access Group 仍被 Mount Target 引用时 Terraform 尝试销毁 | 见下方 1.9 NAS AlreadyAttached 恢复。 |
| Error acquiring the state lock | 残留的 terraform import/apply 进程持有锁 | 执行 `pkill -9 -f "terraform import"` 后重试；或见下方 1.10。 |
| InvalidSystemDiskCategory.ValueNotSupported | 系统盘类型与实例/地域不匹配 | IoOptimized 实例可用 `cloud_essd`、`cloud_efficiency` 或 `cloud_ssd`；若报错可依次尝试。 |

### 1.9 NAS AlreadyAttached 恢复

若 Terraform apply 报错 `The specified Access Group is still attached by some MountTarget(s)`，说明 Terraform 在尝试销毁 Access Group，但 Mount Target 仍在使用它。可通过**一次性的 state 修复**恢复：

**方式一：使用 make 恢复（推荐）**

```bash
make fix-nas-state <project> <env>
# 示例：make fix-nas-state myapp dev
```

脚本会从 `config/<project>-<env>.yaml` 读取 `global.project_name`，自动执行 state rm 与 import。完成后执行 `make deploy <project> <env>`。

**方式二：手动执行**

1. 进入 Terraform 目录：`cd deploy/terraform/alicloud`
2. 从 state 移除：`terraform state rm 'module.nas.alicloud_nas_access_group.main'`
3. 重新导入（将 `deploy-engine-demo`、`dev` 替换为你的 project_name、env_id）：
   `terraform import 'module.nas.alicloud_nas_access_group.main[0]' 'deploy-engine-demo_nas_group_dev:standard'`
4. 确保 tfvars 中 `nas_use_existing_access_group = false`，然后执行 `make deploy <project> <env>`。

### 1.10 OSS 初始化脚本与 K3s 部署说明

**逻辑**：
- **新建 ECS**：user-data 在首次启动时从 OSS 下载 k3s-init.sh 并执行，部署 K3s
- **ECS 已存在**：get-kubeconfig 会检测 K3s 是否部署；若未部署则 SSH 远程下载 k3s-init.sh 并执行，无需重建 ECS
- **Chart 部署**：K3s 就绪后，deploy-engine 会按 deploy 配置执行 helm install/upgrade（若配置了 chart_path 或 chart_repo_url+chart_name）

### 1.11 OSS 脚本上传/下载说明

**桶与对象**（来自 Terraform 输出）：
- **桶名**：tfvars 中指定 `oss_bucket_name` 则检查存在性（存在复用、不存在创建）；不指定则创建 `{project_name}-{env_id}-{random}` 新桶
- **对象 key**：`scripts/k3s-init.sh`
- **下载 URL**：`https://{bucket}.oss-{region}.aliyuncs.com/scripts/k3s-init.sh`

**当前配置示例**（terraform-myapp-dev.tfvars 指定 `oss_bucket_name = "deploy-engine-k3s-storage"` 时）：
- 桶名：`deploy-engine-k3s-storage`
- 地域：`cn-hongkong`
- 下载 URL：`https://deploy-engine-k3s-storage.oss-cn-hongkong.aliyuncs.com/scripts/k3s-init.sh`

**脚本未下载常见原因**：
1. **桶级禁止公共读**：控制台开启「禁止公共读」后，即使 Bucket ACL 显示为「公共读」/「公共读写」，实际访问仍可能 403。需在 OSS 控制台 → 该桶 → 权限控制 → 读写权限 中确认未启用「禁止公共读」或 Bucket Policy 阻断；或改为使用 `ram_role_name` + 对象 private。
2. **对象不存在**：复用已有桶（tfvars 中指定 `oss_bucket_name`）时，Terraform 仍会上传 `scripts/k3s-init.sh`；若 apply 未成功完成 OSS 模块或对象被删，ECS 下载会 404。可在本机执行 `curl -s -o /dev/null -w '%{http_code}' https://<bucket>.oss-<region>.aliyuncs.com/scripts/k3s-init.sh` 检查（200=存在且可读）。
3. **对象 ACL 为 private**：tfvars 中 `init_script_acl = "private"` 时需 ECS 绑定 `ram_role_name` 并通过签名或 ossutil 下载；未配置则 403。
4. **无 RAM Role**：对象为 private 时需 ECS 绑定 RAM Role 并授予 OSS 读权限；未配置则失败。
5. **上传失败**：make deploy 会先执行 `terraform plan -target=...` 检查脚本是否存在且无更新；不存在或本地有更新时才执行 `terraform apply` 上传，存在且无更新则跳过。上传失败会直接报错退出。

**处理建议**：若桶已设为「公共读写」仍报下载失败，先在本机用 curl 测上述 URL 看返回 200/403/404；403 多为桶或对象被「禁止公共读」覆盖或对象 ACL 非 public。可：在 tfvars 中设置 `ram_role_name` 并为该 Role 授予 OSS 读权限、且 `init_script_acl = "private"`；或确认控制台未禁止公共读且 `init_script_acl = "public-read"` 或 `"public-read-write"`。

**首次执行防失败**：get-kubeconfig 会在使用 SSH 前先等待 ECS SSH 就绪（避免 Terraform 刚创建 ECS 后 sshd 未启动即尝试下载导致失败），并对 OSS 下载做有限次重试。可调环境变量：`SSH_WAIT_MAX_ATTEMPTS`（默认 30）、`SSH_WAIT_SLEEP_SEC`（默认 5）；`OSS_DOWNLOAD_MAX_ATTEMPTS`（默认 3）、`OSS_DOWNLOAD_RETRY_SLEEP_SEC`（默认 10）。

### 1.12 State Lock 恢复

若 `make deploy` 或 `fix-nas-state` 报错 `Error acquiring the state lock`：

1. 查找并终止残留的 Terraform 进程：`pkill -9 -f "terraform import"` 或 `pkill -9 -f "terraform apply"`
2. 等待数秒后重试；锁会随进程结束自动释放
3. `fix-nas-state` 脚本现已内置自动清理残留进程

更多排错见 README「常见问题与排错」及 [Aliyun 驱动 README](pkg/provider/aliyun/README.md) 中「失败时检查顺序」。

---

## 二、通用项目引用 deploy-engine 实现部署

**目标**：在任意业务仓中引用 deploy-engine（子模块或 clone），**配置全部放在业务仓的 config/**，不修改 deploy-engine 仓库内任何文件，完成一次部署与回收；便于后续安全拉取部署模块更新。

### 2.1 引用方式

- **子模块**：在业务仓根目录执行 `git submodule add <deploy-engine-repo-url> deploy-engine`（或你约定的目录名）。
- **或 clone**：将 deploy-engine 克隆到业务仓内某目录（如 `deploy-engine/`）。

**约定**：不在 deploy-engine 目录下放置业务配置；所有 deploy.json、tfvars、环境 YAML 均放在业务仓的 **config/** 下，通过 **CONFIG_ROOT** 传入。

### 2.2 业务仓目录与配置约定

- **ConfigRoot** = 业务仓的 `config/` 目录。
- **config/** 下需具备**正式配置文件**（勿直接使用 .example 文件；从示例复制并重命名后再使用）。请将 `<project>`、`<env>` 替换为你的项目名与环境名：

| 用途 | 文件名 |
|------|--------|
| 部署配置 | `deploy.yaml`/`deploy.json` 或 `<project>.yaml`/`<project>.json` |
| Terraform 变量 | `terraform-<project>-<env>.tfvars`（无 project 时为 `terraform-<env>.tfvars`） |
| 环境 YAML | `<project>-<env>.yaml`（无 project 时为 `default-<env>.yaml`） |

从 deploy-engine 的 **config/examples/** 复制到业务仓 config/ 并重命名（不要直接使用 .example）。**示例文件名以 config/examples/ 内实际存在的为准**（当前为 deploy.yaml.example、terraform-dev.tfvars.example、default-dev.yaml.example）。例如（以 myapp、dev 为例）：

```bash
# 在业务仓根目录执行，假设 deploy-engine 在子目录 deploy-engine
cp deploy-engine/config/examples/deploy.yaml.example config/deploy.yaml
cp deploy-engine/config/examples/terraform-dev.tfvars.example config/terraform-myapp-dev.tfvars
cp deploy-engine/config/examples/default-dev.yaml.example config/myapp-dev.yaml
# 编辑 config/terraform-myapp-dev.tfvars（instance_password、ram_role_name 等）、config/myapp-dev.yaml（global.project_name、k3s.apiServer.domain）
```

### 2.3 执行步骤

在**业务仓根目录**执行（请将 `<project>`、`<env>` 替换为你的项目名与环境名）：

**部署**

```bash
export TF_VAR_instance_password="your_password"   # 建议用环境变量，避免写进文件
CONFIG_ROOT=$(pwd)/config make -C deploy-engine deploy <project> <env>
```

**验收集群**（无需手动 export，直接执行）

```bash
CONFIG_ROOT=$(pwd)/config make -C deploy-engine nodes <project> <env>
```

例如：`CONFIG_ROOT=$(pwd)/config make -C deploy-engine nodes myapp dev`。该命令自动使用 `~/.kube/config-<project>-<env>` 执行 `kubectl get nodes`。

**回收**

```bash
CONFIG_ROOT=$(pwd)/config make -C deploy-engine down <project> <env>
```

**拉取 kubeconfig（若部署时 get-kubeconfig 超时）**

```bash
CONFIG_ROOT=$(pwd)/config make -C deploy-engine kubeconfig <project> <env>
```

- **state 位置**：建议将 state 放在业务仓，例如通过 Make 的 `STATE_FILE` 或 CLI 的 `-state` 指定为 `./.deploy/state-<project>-<env>.json`（需在业务仓根先建 `.deploy` 或由引擎创建）。当前 Makefile 默认 state 在 deploy-engine 目录下；若需 state 在业务仓，可在业务仓写包装脚本传入 `-state=./.deploy/state-<project>-<env>.json`。

### 2.4 多环境与多项目

同一业务仓下多环境（如 dev、prod）或多项目：仅在 **config/** 下按扁平命名增加对应文件（如 `terraform-<project>-prod.tfvars`、`<project>-prod.yaml`），然后执行 `CONFIG_ROOT=$(pwd)/config make -C deploy-engine deploy <project> prod` 等即可。state 与 kubeconfig 按 `<project>-<env>` 区分。

### 2.5 引用部署成功标准

- 在业务仓 config/ 下已放置所需配置，且未修改 deploy-engine 目录内文件。
- 执行 deploy 后存在 state 与 `~/.kube/config-<project>-<env>`；执行 `CONFIG_ROOT=$(pwd)/config make -C deploy-engine nodes <project> <env>` 可见 Ready 节点（无需手动 export KUBECONFIG）。
- 执行 down 后 ECS/EIP 等释放，kubeconfig 被删除。

**与本仓验证的差异**：本仓验证在 deploy-engine 根目录执行，ConfigRoot 默认为 deploy-engine 的 **config/**；引用部署在业务仓根目录执行，ConfigRoot 通过 `CONFIG_ROOT=$(pwd)/config` 指向业务仓的 config/，配置与（可选）state 均归属业务仓。

---

## 三、两种场景对照表

| 项 | 本仓验证 | 通用项目引用部署 |
|----|----------|------------------|
| **执行位置** | deploy-engine 根目录 | 业务仓根目录 |
| **ConfigRoot** | 默认 = deploy-engine 的 **config/**（`-config=config/deploy.yaml`） | 业务仓的 `config/`（通过 `CONFIG_ROOT` 传入） |
| **典型命令** | `make deploy <project> <env>` | `CONFIG_ROOT=$(pwd)/config make -C deploy-engine deploy <project> <env>` |
| **state 位置** | `.deploy/state-<project>-<env>.json`（在 deploy-engine 根下） | 可选业务仓 `.deploy/state-<project>-<env>.json`（需通过包装或 -state 指定） |
| **配置存放** | deploy-engine 的 **config/**（deploy、tfvars、env yaml 均在 config/ 下） | 业务仓 `config/`，不修改 deploy-engine 内文件 |

---

## 参考

- **配置与扁平命名**：见《配置说明》；示例文件在 deploy-engine 的 `config/examples/`（可安全提交 GitHub，不含敏感信息）。
- **失败诊断**：见 README「常见问题与排错」及 [Aliyun 驱动 README](pkg/provider/aliyun/README.md) 中「失败时检查顺序」。
