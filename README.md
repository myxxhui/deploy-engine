# Deploy Engine

**基础设施即插即用型（Infra-Agnostic）部署编排引擎**：基于云原生 IaC（Terraform），将「标准化的应用定义（Chart/Values）」与「动态选定的基础设施（Provider）」结合，实现全生命周期原子化管理。本模块**自包含** Terraform 与脚本，无需依赖外部 provisioner 仓库。

## 核心目标

- **独立、轻量级状态**：部署 SDK/CLI 核心库，不绑定具体业务。
- **Terraform 为基础设施主实现**：资源创建/销毁由内嵌的 `deploy/terraform/alicloud` 完成，无需额外仓库。
- **标准化输入 + 可插拔基础设施**：统一配置契约 + Provider 接口，当前内置阿里云 ECS + K3s。

## 架构分层

| 层 | 职责 |
|----|------|
| **输入抽象层** | 统一 Configuration（BaseResourceSpec / BaseEnvSpec / DeploymentSpec），三层合并（Default / Env / User Override） |
| **核心编排层** | 原子化作业流（Init → Provision → Config → Deploy → HealthCheck）、状态锚定（State File） |
| **基础设施适配层** | Provider 接口（Up / Down / GetKubeConfig）；默认实现：Terraform 驱动的阿里云 ECS + K3s |

## 目录结构

```
deploy-engine/
├── deploy/
│   ├── terraform/alicloud/   # 阿里云 Terraform（VPC、安全组、NAS、OSS、ECS）
│   ├── bootstrap/scripts/    # user-data、K3s 引导脚本
│   └── scripts/             # get-kubeconfig.sh 等
├── config/
│   └── environments/dev/    # terraform.tfvars.example、titan.yaml.example
├── cmd/deploy-engine/       # CLI
├── pkg/                     # config、orchestrator、state、provider
└── docs/
```

## 前置条件

- **必装**：Go 1.22+、Terraform（>= 1.0，PATH 可用）、阿里云 API 凭证（环境变量或 `~/.alicloud/config.json` 等）。
- **拉取 kubeconfig**：需安装 `sshpass`（脚本通过 SSH 从 ECS 取 kubeconfig）。macOS 可执行 `brew install sshpass`；Linux 按发行版安装对应包。
- **网络**：本机可访问阿里云 API 与目标地域；若使用 ACR 镜像仓库，需确保网络可访问对应 registry。

## 概念说明

- **project**：项目/应用名（如 `lighthouse`），用于区分不同部署。对应 state 文件 `.deploy/state-<project>-<env>.json` 与 kubeconfig 文件 `~/.kube/kubeconfig-<project>-<env>`。
- **env**：环境名（如 `dev`、`prod`），对应目录 `config/environments/<env>/`，该目录下的 `terraform.tfvars` 被 Terraform 使用。
- **state 文件**：记录本次部署的集群/实例信息，执行 `make down` 时依赖该文件；路径为 `.deploy/state-<project>-<env>.json`。
- **模块根**：deploy-engine 仓库根目录（含 `deploy/`、`config/`）。CLI 通过 `-root` 或环境变量 `DEPLOY_ENGINE_ROOT` 指定；未指定时使用当前工作目录。

## 安全与敏感信息

- **terraform.tfvars**：内含 `instance_password` 等敏感信息，仅限本地使用，**请勿提交到仓库**。本仓库已通过 `.gitignore` 忽略 `config/environments/*/terraform.tfvars`，请勿移除该规则。
- **State 文件**：可能包含集群/实例信息，建议仅保存在本机或受控目录，勿提交至公开仓库。
- **生产环境**：建议通过环境变量（如 `TF_VAR_instance_password`）或 CI/密钥管理服务注入密码，避免在 tfvars 中明文写入。

## 资源与成本

- **会创建的资源**：执行部署后，Terraform 将创建（或复用）VPC、vSwitch、安全组、NAS 文件系统、OSS Bucket、ECS 实例（含系统盘）、EIP 等。具体以 `deploy/terraform/alicloud` 中模块为准，便于做成本与权限预估。
- **竞价实例**：默认使用竞价实例（`enable_spot`、`spot_price_limit` 在 tfvars 中配置）。若当前市场价格超过 `spot_price_limit`，可能创建失败或实例被回收，请合理设置限价。
- **销毁范围**：`make down` 对应 `terraform destroy -target=module.ecs`，仅销毁 ECS 及相关 EIP 等，VPC、NAS、OSS 等资源保留，以便复用或后续手动清理。

## 快速开始

**第一步**：克隆本仓库并进入 deploy-engine 根目录。

**第二步**：为某环境准备 Terraform 变量。例如 dev 环境：

```bash
cp config/environments/dev/terraform.tfvars.example config/environments/dev/terraform.tfvars
```

编辑 `config/environments/dev/terraform.tfvars`，**必填** `instance_password`（至少 8 位）；其余如 `region`、`instance_type`、`enable_spot`、`spot_price_limit` 等可选，不填则使用 example 中的默认值。

**第三步**：在**模块根目录**执行部署（首次会编译二进制并生成 state，可能耗时数分钟）：

```bash
make deploy lighthouse dev
```

**第四步**：使用集群。kubeconfig 已写入 `~/.kube/kubeconfig-<project>-<env>`：

```bash
export KUBECONFIG=~/.kube/kubeconfig-lighthouse-dev
kubectl get nodes
```

销毁环境：

```bash
make down lighthouse dev
```

### Make 命令速查

| 命令 | 说明 |
|------|------|
| `make help` | 打印用法与 kubeconfig 路径说明 |
| `make deploy <project> <env>` | 部署；无二进制时自动 go build |
| `make down <project> <env>` | 销毁并删除对应 kubeconfig |
| `make kubeconfig <project> <env>` | 将 kubeconfig 输出到 stdout |

配置优先使用 `deploy/config/<project>.json`，若不存在则使用根目录 `deploy.json.example`。

### 示例场景

- **场景 1：本仓快速试跑**——在 deploy-engine 根目录完成第二步（准备 dev 的 tfvars），执行 `make deploy myapp dev`，使用 `export KUBECONFIG=~/.kube/kubeconfig-myapp-dev` 连接集群。
- **场景 2：业务仓引用**——将 deploy-engine 作为 submodule 或 clone 到业务仓（如 lighthouse-deploy）；在 deploy-engine 内提供 `deploy/config/lighthouse.json`（或使用根目录 `deploy.json.example`），在 deploy-engine 根目录执行 `make deploy lighthouse dev`。
- **场景 3：同一项目多环境**——复制 `config/environments/dev` 为 `config/environments/prod` 并修改 `terraform.tfvars`（如 region、实例规格），分别执行 `make deploy lighthouse dev` 与 `make deploy lighthouse prod`，使用不同的 kubeconfig 文件连接。

### 多环境与多项目

- **新增环境（如 prod）**：复制 `config/environments/dev` 为 `config/environments/prod`，编辑 `terraform.tfvars`（region、实例规格、密码等），然后执行 `make deploy <project> prod`。
- **同一项目多环境**：例如 lighthouse 的 dev 与 prod，共用同一套 deploy 配置（或同一 `deploy.json.example`），通过不同 env 的 tfvars 区分；state 与 kubeconfig 按 `<project>-<env>` 自动区分。
- **多项目同环境**：例如 lighthouse dev 与 other dev 共用 `config/environments/dev/terraform.tfvars`，但 state 与 kubeconfig 按 project 分离（`.deploy/state-lighthouse-dev.json` 与 `.deploy/state-other-dev.json`）。注意：当前 Terraform 状态为单 env 单套基础设施资源，同一 env 下多 project 共享同一套 VPC/ECS 等，仅 state 与 kubeconfig 按 project 区分。

### 在非根目录或作为子模块使用

- 若在**其他目录**执行 CLI（不通过 make）：需设置环境变量 `DEPLOY_ENGINE_ROOT=/path/to/deploy-engine` 或传入 `-root=/path/to/deploy-engine`。
- **Make 约定**：Makefile 以当前工作目录为模块根，因此**必须在 deploy-engine 根目录执行 make**。若从业务仓调用，可写包装脚本先 `cd` 到 deploy-engine 再执行 `make deploy <project> <env>`。
- **子项目建议**：将 deploy-engine 作为 submodule 放在业务仓子目录；业务仓提供 `deploy-engine/deploy/config/<project>.json`（或使用 `deploy.json.example`）；执行时进入 deploy-engine 根目录再运行 make。

### 输出与可观测性

- **部署过程**：终端会输出 Terraform init/apply 日志、get-kubeconfig 脚本日志，以及最终的「deploy ok, state: ...」。
- **确认成功**：① 存在 `.deploy/state-<project>-<env>.json`；② 存在 `~/.kube/kubeconfig-<project>-<env>`；③ 执行 `export KUBECONFIG=~/.kube/kubeconfig-<project>-<env> && kubectl get nodes` 能看到节点。
- **排错**：Terraform 报错时可进入 `deploy/terraform/alicloud` 执行 `terraform plan -var-file=../../config/environments/<env>/terraform.tfvars -var=env_id=<env>` 查看差异；脚本失败时查看终端 stderr。

### 常见问题与排错

- **State 文件丢失**：需凭 project/env 与 tfvars 路径，在 `deploy/terraform/alicloud` 下手动执行 `terraform destroy -var-file=... -var=env_id=<env> -target=module.ecs`；建议定期备份 `.deploy/state-*.json`。
- **terraform apply 失败**：检查阿里云凭证、地域、资源配额及 tfvars 语法；到 `deploy/terraform/alicloud` 执行 `terraform plan` 查看完整错误。
- **get-kubeconfig 失败**：确认 ECS 已就绪、22 端口可达、`instance_password` 与 tfvars 中一致、已安装 `sshpass`，以及安全组允许当前 IP 访问 22 端口。

### 直接调用 CLI（可选）

传入 `-project` 与 `-env` 以与 Make 行为一致：

```bash
go build -o bin/deploy-engine ./cmd/deploy-engine
./bin/deploy-engine -cmd=deploy -config=deploy.json.example -state=.deploy/state-lighthouse-dev.json -env=dev -project=lighthouse
./bin/deploy-engine -cmd=destroy -state=.deploy/state-lighthouse-dev.json -env=dev -project=lighthouse
```

## 交付物

**用户视角**：一键部署/销毁（Make）、按 project/env 隔离的 state 与 kubeconfig、可被其他项目通过 submodule 或 clone 引用。

**技术视角**：Core Library（`pkg/`：config、orchestrator、state、provider）、Provider Interface（`pkg/provider/provider.go`）、Default Aliyun Driver（`pkg/provider/aliyun/`）、Schema（`pkg/config/spec.go`）、CLI（`cmd/deploy-engine/`）。扩展新 Provider 或二次开发请参阅 `pkg/` 与 `docs/`。

## 术语表

| 术语 | 说明 |
|------|------|
| **project** | 项目/应用名，用于区分部署与命名 state、kubeconfig |
| **env** | 环境名（如 dev、prod），对应 `config/environments/<env>/` |
| **state 文件** | `.deploy/state-<project>-<env>.json`，记录本次部署信息，destroy 时依赖 |
| **模块根** | deploy-engine 仓库根目录，CLI 通过 `-root` 或 `DEPLOY_ENGINE_ROOT` 指定 |
| **Provider** | 基础设施实现（当前为 aliyun），负责 Terraform 与 kubeconfig 拉取 |

## 版本与兼容性

- 本文档适用于 deploy-engine 当前版本。前置条件：Go 1.22+、Terraform >= 1.0。
- 若未来 State 结构发生变更，大版本升级时请查看 Changelog，必要时迁移或备份 state 文件。

## 文档索引

| 想做什么 | 看哪篇 |
|----------|--------|
| 快速上手、前置条件、概念、排错 | 本文（README） |
| 配置含义、deploy.json 与 tfvars 分工、三层合并 | [配置说明](docs/CONFIG.md) |
| 架构、数据流、扩展新 Provider | [架构设计](docs/ARCHITECTURE.md) |
| 阿里云驱动细节、依赖、故障排查 | [Aliyun 驱动](pkg/provider/aliyun/README.md) |
