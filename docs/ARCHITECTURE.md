# 架构设计：基础设施即插即用型部署编排引擎

## 定位：云原生 IaC、自包含

deploy-engine 采用**云原生 IaC 模式**，**主要使用 Terraform 实现**基础设施的创建与销毁，且**模块自包含**：

- **基础设施生命周期**：由内嵌的 `deploy/terraform/alicloud` 管理（`terraform apply` / `terraform destroy`），无需外部 provisioner 仓库。
- **编排引擎职责**：提供统一配置契约、原子化步骤编排、状态锚定（State File）与 CLI；Aliyun Driver 在模块根下执行 Terraform 并调用 `deploy/scripts/` 中的脚本。
- **无侵入**：不要求业务修改 Chart 结构，只需提供标准 Helm Chart。

## 三层边界

### 1. 输入抽象层 (Input Abstraction Layer)

- **统一配置契约**：`BaseResourceSpec`、`BaseEnvSpec`、`DeploymentSpec`，与云厂商解耦。
- **三层合并**：Default ← Env ← User Override，结果写入 `DeploymentConfig.Merged`。
- **与 Terraform 的衔接**：`ToAliyunTerraformVars()` 将 Merged 映射为阿里云 Terraform 变量。

### 2. 核心编排层 (Core Orchestrator Layer)

- **原子化作业流**：Init → Provision → Config → Deploy → HealthCheck。Provision 即调用 `Provider.Up()`（内部执行 Terraform apply）。**Deploy** 已实现：在 Provision 成功后若 `Merged.Deployment` 配置了 chart_path 或 chart_repo_url+chart_name，则执行 `helm upgrade --install`（见 `pkg/helm`）。**HealthCheck** 当前未实现，计划对指定 Deployment/Service 做就绪探测或 `kubectl cluster-info` 校验；Config 为预留扩展点。
- **状态锚定**：State File 记录 DeploymentID、ProviderName、Project、EnvID、ClusterContext，作为「一条命令回收环境」的凭证；kubeconfig 写入 `~/.kube/config-<project>-<env>`（当传入 project 时）。
- **幂等**：同一 DeploymentID/EnvID 下，由 Provider（及 Terraform）保证不重复创建资源。

### 3. 基础设施适配层 (Infrastructure Adapter Layer)

- **驱动接口**：`Provider`（Up / Down / GetKubeConfig）。
- **默认实现**：Aliyun Driver 在模块内 `deploy/terraform/alicloud` 执行 Terraform，并调用 `deploy/scripts/get-kubeconfig.sh` 获取 kubeconfig。

## 数据流概览

Deploy 时传入 **project** 与 **env**；State 持久化 Project、EnvID、ClusterContext 等；kubeconfig 写入 `~/.kube/config-<project>-<env>`。Destroy 时从 State 读回 project/env，调用 Provider.Down 并删除同一 kubeconfig 文件。

```
用户配置 (deploy.json) + project + env
    → Merge → DeploymentConfig.Merged
    → Engine.Deploy()
        → Provider.Up() → terraform apply（deploy/terraform/alicloud）
        → terraform output → get-kubeconfig.sh <env> [project]
        → State (Project, EnvID, InstanceID, PublicIP, KubeConfig, ...)
    → StepDeploy（若配置了 Chart）：helm upgrade --install
    → 持久化 State File（.deploy/state-<project>-<env>.json）
    → kubeconfig 写入 ~/.kube/config-<project>-<env>

回收：State File → 读回 Project/EnvID → Engine.Destroy() → Provider.Down()
    → terraform destroy -target=module.ecs → 删除 ~/.kube/config-<project>-<env>
```

## 模块根与路径约定

- **模块根（Root）**：deploy-engine 仓库根目录，包含 `deploy/`、`pkg/`、`cmd/`。**仅用于** Terraform 工作目录与脚本路径；引擎**不向 Root 写入任何配置**（临时 tfvars 写系统临时目录）。
- **配置根（ConfigRoot）**：所有 deploy 相关配置（deploy.json、terraform tfvars、环境 YAML）的唯一起源。默认 **ConfigRoot = dir(-config)**（即 `-config` 指定文件所在目录）；可通过 **-config-root** 覆盖（如从 stdin 读 config 或需指定独立配置目录时）。tfvars、环境 YAML、deploy.json 仅从 ConfigRoot 解析，保证「配置归属应用仓、部署模块只读」。
- CLI 可通过 `-root` 或环境变量 `DEPLOY_ENGINE_ROOT` 指定模块根；未指定时使用当前工作目录。
- Terraform 工作目录：`<模块根>/deploy/terraform/alicloud`。
- 配置文件（扁平命名，均在 ConfigRoot 下）：tfvars 为 `terraform-<project>-<env>.tfvars`（无 project 时 `terraform-<env>.tfvars`）；环境 YAML 为 `<project>-<env>.yaml`（无 project 时 `default-<env>.yaml`）。兼容旧路径见《配置说明》迁移小节。

## 扩展新 Provider

- 实现 `provider.Provider` 接口（Up / Down / GetKubeConfig），见 `pkg/provider/provider.go`。
- 在 `cmd/deploy-engine/main.go` 的 provider switch 中注册新驱动（如 `case "aws": p = &aws.Driver{...}`）。
- 若需新 flag（如 region、profile），在 main 中解析并传入 Driver 结构体。
- 应用部署（Helm）、镜像同步等为编排层扩展点，当前由 Terraform 完成基础设施，应用层可在后续接入。

**进阶与扩展**：公司级默认配置可通过共享的 deploy.json 作为 default 层、各项目仅维护 user_override 实现；若需「外部 default 文件」目前可先复制一份再改（规划中支持）。Helm / 镜像同步见 CONFIG 与编排层扩展点。
