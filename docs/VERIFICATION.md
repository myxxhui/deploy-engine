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

**目录与文件清单**

| 用途 | 文件名（ConfigRoot = config/ 下） | 来源 |
|------|-----------------------------------|------|
| Terraform 变量 | `terraform-<project>-<env>.tfvars`（无 project 时为 `terraform-<env>.tfvars`） | 从 `config/terraform-<project>-<env>.tfvars.example` **复制并重命名** |
| 环境 YAML | `<project>-<env>.yaml`（无 project 时为 `default-<env>.yaml`） | 从 `config/<project>-<env>.yaml.example` 或 `config/default-<env>.yaml.example` **复制并重命名** |
| 部署配置 | `deploy.yaml`/`deploy.json` 或 `<project>.yaml`/`<project>.json` | 从 **config/deploy.yaml.example**（或 config/deploy.json.example）**复制为 config/deploy.yaml**（或 config/deploy.json / config/<project>.yaml） |

**操作示例（以 myapp、dev 为例；仓库内示例以 lighthouse-dev 命名，复制后重命名为你的 project-env）**

```bash
# 在 deploy-engine 根目录执行；以下为首次本地验证必做步骤，目标均在 config/
cp config/deploy.yaml.example config/deploy.yaml
cp config/terraform-lighthouse-dev.tfvars.example config/terraform-myapp-dev.tfvars
cp config/lighthouse-dev.yaml.example config/myapp-dev.yaml
# 无 project 时：cp config/terraform-dev.tfvars.example config/terraform-dev.tfvars
# 无 project 时：cp config/default-dev.yaml.example config/default-dev.yaml
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

```bash
export KUBECONFIG=~/.kube/config-<project>-<env>
kubectl get nodes
```

**成功表现**：能看到节点且状态为 Ready，即表示集群可用。

### 1.6 验证后回收（必做）

无论验证是否通过，**均须执行 Down 释放资源**（含竞价实例 ECS）：

```bash
make down <project> <env>
```

执行后 ECS 与 EIP 等将被销毁，kubeconfig 文件会被删除；VPC、NAS、OSS 等按当前设计保留。

### 1.7 本仓验证成功标准

- 存在 `.deploy/state-<project>-<env>.json`。
- 存在 `~/.kube/config-<project>-<env>`。
- `kubectl get nodes` 能列出节点且为 Ready。
- 执行 `make down <project> <env>` 后，ECS/EIP 等资源释放，kubeconfig 被删除。

### 1.8 常见失败与排查

| 现象 | 可能原因 | 建议操作 |
|------|----------|----------|
| Terraform apply 报错 | 凭证、地域、配额、tfvars 语法 | 检查 AKSK、地域与配额；到 `deploy/terraform/alicloud` 执行 `terraform plan -var-file=...` 查看差异。详见 README「常见问题与排错」。 |
| get-kubeconfig 超时 | K3s 启动或网络较慢 | 增大 `KUBECONFIG_MAX_RETRIES`、`KUBECONFIG_SLEEP_SEC`；或稍后单独执行 `make kubeconfig <project> <env>`。 |
| instance_password 未设置 | tfvars 未填或环境变量未设 | 设置环境变量 `TF_VAR_instance_password` 或在 tfvars 中填写至少 8 位密码。 |
| 配置文件不存在 | 未在 ConfigRoot 下按扁平命名准备文件 | 确认 **config/** 下存在 `terraform-<project>-<env>.tfvars`、`<project>-<env>.yaml` 及 **config/deploy.yaml**，见 1.2。 |
| 网络/凭证失败 | 本机无法访问阿里云或 AKSK 错误 | 检查网络与 `ALICLOUD_ACCESS_KEY`、`ALICLOUD_SECRET_KEY` 或 `~/.alicloud/config.json`。 |

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

从 deploy-engine 的示例文件**复制到业务仓 config/ 并重命名**（不要直接使用 .example）。例如（以 myapp、dev 为例；仓库内示例为 lighthouse-dev，复制后重命名）：

```bash
# 在业务仓根目录执行，假设 deploy-engine 在子目录 deploy-engine
cp deploy-engine/config/terraform-lighthouse-dev.tfvars.example config/terraform-myapp-dev.tfvars
cp deploy-engine/config/lighthouse-dev.yaml.example config/myapp-dev.yaml
cp deploy-engine/config/deploy.yaml.example config/deploy.yaml
# 编辑 config/terraform-myapp-dev.tfvars（instance_password 等）、config/myapp-dev.yaml
```

### 2.3 执行步骤

在**业务仓根目录**执行（请将 `<project>`、`<env>` 替换为你的项目名与环境名）：

**部署**

```bash
export TF_VAR_instance_password="your_password"   # 建议用环境变量，避免写进文件
CONFIG_ROOT=$(pwd)/config make -C deploy-engine deploy <project> <env>
```

**验收集群**

```bash
export KUBECONFIG=~/.kube/config-<project>-<env>
kubectl get nodes
```

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
- 执行 deploy 后存在 state 与 `~/.kube/config-<project>-<env>`；`kubectl get nodes` 可见 Ready 节点。
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

- **配置与扁平命名**：见《配置说明》；示例文件在 deploy-engine 的 `config/terraform-*.tfvars.example`、`config/*-dev.yaml.example`。
- **失败诊断**：见 README「常见问题与排错」及 [Aliyun 驱动 README](pkg/provider/aliyun/README.md) 中「失败时检查顺序」。
