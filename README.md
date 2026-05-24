# Deploy Engine

**基础设施即插即用型（Infra-Agnostic）部署编排引擎**：基于云原生 IaC（Terraform），将「标准化的应用定义（Chart/Values）」与「动态选定的基础设施（Provider）」结合，实现全生命周期原子化管理。本模块**自包含** Terraform 与脚本，无需依赖外部 provisioner 仓库。

## 核心目标

- **独立、轻量级状态**：部署 SDK/CLI 核心库，不绑定具体业务。
- **Terraform 为基础设施主实现**：资源创建/销毁由内嵌的 `deploy/terraform/alicloud` 完成，无需额外仓库。
- **标准化输入 + 可插拔基础设施**：统一配置契约 + Provider 接口，当前内置阿里云 ECS + K3s。

**设计契约**：部署引擎**仅从配置根（ConfigRoot）读取配置**，**不向模块根（Root，deploy-engine 目录）写入任何配置**；临时生成的 tfvars 写入系统临时目录。配置应放在应用仓的 config 目录或通过 `-config-root` 指定，便于子模块更新时不被业务配置污染。详见《配置说明》与《架构设计》。

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
├── config/                   # 实际配置目录；示例在 config/examples/（可安全提交 GitHub）
├── cmd/deploy-engine/       # CLI
├── pkg/                     # config、orchestrator、state、provider
└── docs/
```

**示例在 config/examples/**（可安全提交 GitHub）；**实际配置在 config/**。本仓验证时请从 `config/examples/` 复制示例到 `config/` 并填写实际值后执行 make，见《验证此模块逻辑》。配置应放在 **ConfigRoot**（本仓即 config/，或应用仓的 config/），不要求在 deploy-engine 根目录维护业务配置，见《配置说明》。

## 前置条件

- **必装**：Go 1.22+、Terraform（>= 1.0，PATH 可用）、阿里云 API 凭证（见下方「敏感配置与凭证」）。
- **拉取 kubeconfig**：需安装 `sshpass`（脚本通过 SSH 从 ECS 取 kubeconfig）。macOS 可执行 `brew install sshpass`；Linux 按发行版安装对应包。
- **网络**：本机可访问阿里云 API 与目标地域；若使用 ACR 镜像仓库，需确保网络可访问对应 registry。

## 概念说明

- **project**：项目/应用名（如 `lighthouse`），用于区分不同部署。对应 state 文件 `.deploy/state-<project>-<env>.json` 与 kubeconfig 文件 `~/.kube/config-<project>-<env>`。
- **env**：环境名（如 `dev`、`prod`）。在 **ConfigRoot** 下对应扁平文件名：tfvars 为 `terraform-<project>-<env>.tfvars`（或 `terraform-<env>.tfvars`），环境 YAML 为 `<project>-<env>.yaml`（或 `default-<env>.yaml`）。Merged 配置先于 tfvars 驱动 Terraform，tfvars 中同名变量覆盖 Merged。本模块仅使用 YAML 中 global/registry 等 Terraform 所需字段，组件开关由外部 titan-stack 等消费。
- **state 文件**：记录本次部署的集群/实例信息，执行 `make down` 时依赖该文件；路径为 `.deploy/state-<project>-<env>.json`，建议放在应用仓。
- **模块根（Root）**：deploy-engine 仓库根目录（含 `deploy/`），仅用于 Terraform 与脚本；CLI 通过 `-root` 或 `DEPLOY_ENGINE_ROOT` 指定。
- **配置根（ConfigRoot）**：所有配置（deploy.json、tfvars、YAML）的唯一起源，默认由 `-config` 所在目录推导，可选 `-config-root` 覆盖；推荐在应用仓维护 config/。

## 安全与敏感信息

- **terraform.tfvars**：内含 `instance_password` 等敏感信息，仅限本地使用，**请勿提交到仓库**。`.gitignore` 已忽略 `config/environments/*/terraform*.tfvars` 与 `config/terraform-*.tfvars`，请勿移除。
- **State 文件**：可能包含集群/实例信息，建议仅保存在本机或受控目录，勿提交至公开仓库。
- **生产环境**：建议通过环境变量（如 `TF_VAR_instance_password`）或 CI/密钥管理服务注入密码，避免在 tfvars 中明文写入。
- **检查清单**：示例中敏感项已使用占位（如 `CHANGE_ME`）；上线前确认未提交真实密码、AKSK 与 tfvars，使用环境变量或密钥服务注入。

### 敏感配置与凭证

| 敏感项 | 说明与推荐注入方式 |
|--------|---------------------|
| **阿里云 AKSK** | Terraform 阿里云 Provider 通过环境变量读取：`ALICLOUD_ACCESS_KEY`、`ALICLOUD_SECRET_KEY`（或 `ALICLOUD_ACCESS_KEY_ID` / `ALICLOUD_ACCESS_KEY_SECRET`，视 Provider 版本而定）。也可使用配置文件 `~/.alicloud/config.json`。**生产/CI**：使用环境变量或密钥管理服务注入，勿提交到仓库。 |
| **instance_password** | ECS 实例 root 密码，用于 Terraform 创建实例及 get-kubeconfig 脚本 SSH 登录。**推荐**：设置环境变量 `TF_VAR_instance_password`，则无需在 tfvars 中写入明文；引擎会优先使用该环境变量，未设置时才从 `config/environments/<env>/terraform.tfvars` 中解析。 |

部署前请至少提供其一：阿里云凭证（AKSK 或 config 文件）、instance_password（环境变量或 tfvars）。

### OSS 初始化脚本与 RAM Role

ECS 首次启动时，user-data 会从 OSS 下载初始化脚本（`scripts/k3s-init.sh`）以安装 K3s。**当前默认**：该 OSS 对象配置为 `public-read`，ECS 可直接通过 HTTP 下载。若账号不允许 Bucket 公共读，请为 ECS 实例绑定 **RAM Role**，并为该 Role 授予 OSS 读权限（如 `oss:GetObject` 针对目标 Bucket）。user-data 中的 ossutil 会通过 ECS 实例元数据服务（`http://100.100.100.200/latest/meta-data/ram/security-credentials/`）自动获取临时凭证，无需在脚本内配置 AKSK。在 `terraform.tfvars` 中可设置 `ram_role_name` 指定已创建的 RAM Role 名称（需在控制台预先创建 Role 并附加 OSS 读权限策略）。

## 资源与成本

- **会创建的资源**：执行部署后，Terraform 将创建（或复用）VPC、vSwitch、安全组、NAS 文件系统、OSS Bucket、ECS 实例（含系统盘）、EIP 等。具体以 `deploy/terraform/alicloud` 中模块为准，便于做成本与权限预估。
- **竞价实例**：默认使用竞价实例（`enable_spot`、`spot_price_limit` 在 tfvars 中配置）。若当前市场价格超过 `spot_price_limit`，可能创建失败或实例被回收，请合理设置限价。
- **销毁范围**：`make down` 对应 `terraform destroy -target=module.ecs`，仅销毁 ECS 及相关 EIP 等，VPC、NAS、OSS 等资源保留，以便复用或后续手动清理。

## 快速开始

**第一步**：克隆本仓库并进入 deploy-engine 根目录。

**第二步**：从 **config/examples/** 复制示例到 **config/** 并填写（扁平命名）。例如 project=lighthouse、env=dev：

```bash
cp config/examples/deploy.yaml.example config/deploy.yaml
cp config/examples/terraform-lighthouse-dev.tfvars.example config/terraform-lighthouse-dev.tfvars
cp config/examples/lighthouse-dev.yaml.example config/lighthouse-dev.yaml
```

编辑 `config/terraform-lighthouse-dev.tfvars`，**必填** `instance_password`（至少 8 位）；建议使用环境变量 `TF_VAR_instance_password`。其余如 `region`、`instance_type`、`enable_spot`、`spot_price_limit` 等可选。

**第三步**：在**模块根目录**执行部署（首次会编译二进制并生成 state，可能耗时数分钟）：

```bash
make deploy lighthouse dev
```

**第四步**：使用集群。kubeconfig 已写入 `~/.kube/config-<project>-<env>`：

```bash
export KUBECONFIG=~/.kube/config-lighthouse-dev
kubectl get nodes
```

**第五步**：验证后回收。无论验证是否通过，均须执行 Down 释放资源：

```bash
make down lighthouse dev
```

完整端到端步骤（含凭证、tfvars、titan.yaml、排错）见 [验证此模块逻辑](docs/VERIFICATION.md)。

### Make 命令速查

| 命令 | 说明 |
|------|------|
| `make help` | 打印用法与 kubeconfig 路径说明 |
| `make deploy <project> <env>` | 部署；无二进制时自动 go build |
| `make down <project> <env>` | 销毁并删除对应 kubeconfig |
| `make kubeconfig <project> <env>` | 将 kubeconfig 输出到 stdout |

### v2 多 stack 命令（P 轨 · 按需起停）

| 命令 | 说明 |
|------|------|
| `make up-stack <project> <env> STACK=<id>` | 起单 stack（base/train/infer）· `-target` 该 stack ECS+EIP |
| `make down-stack <project> <env> STACK=<id>` | 销单 stack · 保留永驻 10 项 |
| `make down-platform-base <project> <env>` | 销所有 ECS+EIP · 保留永驻 10 项 |
| `make down-all <project> <env> FULL_DESTROY=1` | 完全销毁含永驻（需二次确认 `DESTROY-DATA`）|
| `make platform-status <project> <env>` | terraform output + helm list 总览 |

**永驻 10 项**（lifecycle `prevent_destroy = true`）：VPC + VSwitch + 安全组 + 路由 + 网关 + NAS 文件系统 + NAS 挂载点 + 独立 ESSD 数据盘 + OSS Bucket + ACR（云端控制台管理）。tier-1/tier-2 释放不动；仅 `make down-all FULL_DESTROY=1` 触发 `terraform state rm` 后销毁。

**配置入口**：在 `terraform-<project>-<env>.tfvars` 添加 `stacks = { base = {...}, train = {...}, infer = {...} }`（示例见 `config/examples/terraform-dev.tfvars.example` 末尾）。未配置时根级 `main.tf` 用旧 `enable_spot`/`instance_type` 合成单一 `base` stack（向后兼容）。

配置：若设置 `CONFIG_ROOT` 则使用 `$(CONFIG_ROOT)/<project>.yaml` 或 `deploy.yaml`/`deploy.json`；否则本仓默认使用 **config/** 下 `config/deploy.yaml` 等（请从 config/examples/ 复制示例到 config/ 并填写）。部署配置支持 .yaml/.yml/.json。

### 示例场景

- **场景 1：本仓快速试跑**——在 deploy-engine 根目录完成第二步（在 config/ 下准备扁平命名的 tfvars 与 YAML），执行 `make deploy myapp dev`，使用 `export KUBECONFIG=~/.kube/config-myapp-dev` 连接集群。
- **场景 2：业务仓引用**——将 deploy-engine 作为 submodule 或 clone 到业务仓子目录（如 `lighthouse-deploy/deploy-engine`）。**必须在应用仓维护 config/**（如 `lighthouse-deploy/config/`），放置 `deploy.json`（或 `<project>.json`）、`terraform-<project>-<env>.tfvars`、`<project>-<env>.yaml`；**禁止在 deploy-engine 目录下放业务配置**，以免拉取部署模块更新时冲突。在应用仓根执行：`CONFIG_ROOT=$$(pwd)/config make -C deploy-engine deploy lighthouse dev`；state 建议放在应用仓（如 `-state=./.deploy/state-lighthouse-dev.json`）。
- **场景 3：同一项目多环境**——在 ConfigRoot 下为各环境准备 `terraform-<project>-<env>.tfvars` 与 `<project>-<env>.yaml`（如 prod），分别执行 `make deploy lighthouse dev` 与 `make deploy lighthouse prod`。

### 多环境与多项目

- **新增环境（如 prod）**：在 ConfigRoot 下增加 `terraform-<project>-prod.tfvars` 与 `<project>-prod.yaml`，然后执行 `make deploy <project> prod`。
- **同一项目多环境**：例如 lighthouse 的 dev 与 prod，通过不同 env 的扁平文件区分；state 与 kubeconfig 按 `<project>-<env>` 自动区分。
- **多项目同环境**：在 ConfigRoot 下为各 project 准备 `terraform-<project>-<env>.tfvars` 与 `<project>-<env>.yaml`；state 与 kubeconfig 按 project 分离。注意：当前 Terraform 状态为单 env 单套基础设施资源，同一 env 下多 project 共享同一套 VPC/ECS 等，仅 state 与 kubeconfig 按 project 区分。

### 在非根目录或作为子模块使用

- 若在**其他目录**执行 CLI（不通过 make）：需设置 `DEPLOY_ENGINE_ROOT=/path/to/deploy-engine` 或 `-root=...`；配置从 `-config` 所在目录（或 `-config-root`）读取。
- **Make 约定**：Makefile 以当前工作目录为模块根，因此**必须在 deploy-engine 根目录执行 make**。从业务仓调用时：在**应用仓根目录**执行 `CONFIG_ROOT=$(pwd)/config make -C deploy-engine deploy <project> <env>`，确保配置全部来自应用仓 config，不修改 deploy-engine 内文件。
- **子模块建议**：deploy-engine 作为 submodule 放在业务仓子目录；**配置全部放在应用仓的 config/**（deploy.json、terraform-*-.tfvars、*-.yaml），通过 `CONFIG_ROOT` 传入；state 建议用 `-state=./.deploy/state-<project>-<env>.json` 放在应用仓。

### 输出与可观测性

- **部署过程**：终端会输出 Terraform init/apply 日志、get-kubeconfig 脚本日志，以及最终的「deploy ok, state: ...」。
- **确认成功**：① 存在 `.deploy/state-<project>-<env>.json`；② 存在 `~/.kube/config-<project>-<env>`；③ 执行 `export KUBECONFIG=~/.kube/config-<project>-<env> && kubectl get nodes` 能看到节点。
- **排错**：Terraform 报错时可进入 `deploy/terraform/alicloud` 执行 `terraform plan -var-file=...` 查看差异；脚本失败时查看终端 stderr。若 **deploy 因「K3s 未在预期时间内就绪」而失败**，说明 Terraform 与 ECS 已创建成功，仅 K3s 启动或网络较慢，可先确认 ECS 与 user-data 正常后，**单独执行 `make kubeconfig <project> <env>` 重试拉取 kubeconfig**，无需重新执行完整 deploy。拉取脚本支持环境变量 **`KUBECONFIG_MAX_RETRIES`**（默认 60）、**`KUBECONFIG_SLEEP_SEC`**（默认 5），在慢环境可适当增大以延长等待。

### 常见问题与排错

- **State 文件丢失**：需凭 project/env 与 tfvars 路径，在 `deploy/terraform/alicloud` 下手动执行 `terraform destroy -var-file=... -var=env_id=<env> -target=module.ecs`；建议定期备份 `.deploy/state-*.json`。
- **terraform apply 失败**：检查阿里云凭证、地域、资源配额及 tfvars 语法；到 `deploy/terraform/alicloud` 执行 `terraform plan` 查看完整错误。
- **get-kubeconfig 失败**：确认 ECS 已就绪、22 端口可达、`instance_password` 与 tfvars 中一致、已安装 `sshpass`，以及安全组允许当前 IP 访问 22 端口。若仅为 K3s 启动较慢，可增大 `KUBECONFIG_MAX_RETRIES` 或 `KUBECONFIG_SLEEP_SEC` 后再次执行 `make kubeconfig <project> <env>`。

### Terraform 状态与远程 Backend

默认使用 **local backend**（状态文件 `deploy/terraform/alicloud/terraform.tfstate`）。若需多人协作或避免 state 丢失，可改用 **远程 Backend**（如 OSS）。示例配置见 `deploy/terraform/alicloud/backend.example.tf`。**从 local 迁移到 OSS**：在 `deploy/terraform/alicloud` 下将 backend 块改为 oss 并填写 bucket、prefix、key 后，执行 `terraform init -migrate-state`，按提示确认迁移；迁移前建议备份本地 `terraform.tfstate`。

### 直接调用 CLI（可选）

传入 `-project`、`-env`，必要时 `-config-root` 以与 Make 行为一致：

```bash
go build -o bin/deploy-engine ./cmd/deploy-engine
./bin/deploy-engine -cmd=deploy -config=config/deploy.yaml -state=.deploy/state-lighthouse-dev.json -env=dev -project=lighthouse
./bin/deploy-engine -cmd=destroy -state=.deploy/state-lighthouse-dev.json -env=dev -project=lighthouse
# 从应用仓：-config=./config/deploy.json 或 -config-root=./config
```

## 交付物

**用户视角**：一键部署/销毁（Make）、按 project/env 隔离的 state 与 kubeconfig、可被其他项目通过 submodule 或 clone 引用。

**技术视角**：Core Library（`pkg/`：config、orchestrator、state、provider）、Provider Interface（`pkg/provider/provider.go`）、Default Aliyun Driver（`pkg/provider/aliyun/`）、Schema（`pkg/config/spec.go`）、CLI（`cmd/deploy-engine/`）。扩展新 Provider 或二次开发请参阅 `pkg/` 与 `docs/`。

## 术语表

| 术语 | 说明 |
|------|------|
| **project** | 项目/应用名，用于区分部署与命名 state、kubeconfig |
| **env** | 环境名（如 dev、prod），ConfigRoot 下扁平文件名含 `<env>` |
| **state 文件** | `.deploy/state-<project>-<env>.json`，记录本次部署信息，destroy 时依赖 |
| **模块根（Root）** | deploy-engine 仓库根目录，仅用于 Terraform 与脚本；`-root` 或 `DEPLOY_ENGINE_ROOT` |
| **配置根（ConfigRoot）** | 配置唯一起源目录，默认 `-config` 所在目录，可选 `-config-root` |
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
| 从 AKSK 到 kubectl get nodes、验证后回收的完整步骤 | [验证此模块逻辑](docs/VERIFICATION.md) |
| 阿里云驱动细节、依赖、故障排查 | [Aliyun 驱动](pkg/provider/aliyun/README.md) |
