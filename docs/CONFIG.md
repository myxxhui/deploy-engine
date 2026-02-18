# 配置说明

## 配置根（ConfigRoot）与契约

- **ConfigRoot**：所有 deploy 相关配置（deploy.json、tfvars、环境 YAML）的唯一起源目录。默认 **ConfigRoot = dir(-config)**（即 `-config` 指定文件所在目录）；可通过 **-config-root** 覆盖。引擎**仅从 ConfigRoot 读取配置**，**不向模块根（Root）写入任何配置**；临时生成的 tfvars 写系统临时目录。
- **推荐**：从业务仓使用时，在应用仓维护 `config/`，通过 `-config=./config/deploy.json` 或环境变量 `CONFIG_ROOT` 指定，避免在 deploy-engine 目录下放业务配置，便于安全拉取部署模块更新。

## 两种配置的职责

- **deploy 配置（Merged）**：执行 deploy 时传入 `-config=<文件>`，支持 **.yaml/.yml/.json**；配置经 `Merge()` 后 **Merged 作为 Terraform 变量来源**。引擎调用 `ToAliyunTerraformVars(...)` 生成变量（含 project、config_file 绝对路径）并先于 tfvars 传入 Terraform。文件中的 default/env/user_override 驱动基础设施（region、instance_type、enable_spot 等）。按项目可放置为 ConfigRoot 下的 `<project>.yaml`/`<project>.json` 或 `deploy.yaml`/`deploy.json`。仓库提供 **config/deploy.yaml.example** 作为默认示例。
- **terraform tfvars**：位于 **ConfigRoot 下**，用于本地覆盖或敏感项占位。**扁平命名**：`terraform-<project>-<env>.tfvars`（无 project 时为 `terraform-<env>.tfvars`）。部署时在 Merged 生成的变量之后作为 `-var-file` 传入，tfvars 中同名变量会覆盖 Merged。必填项如 `instance_password`（建议通过环境变量 `TF_VAR_instance_password` 注入）。兼容旧路径：若扁平文件不存在，会回退到 `config/environments/<env>/terraform.tfvars` 并打 deprecation 提示。
- **环境 YAML（config_file）**：未指定时由引擎按 project+env 推导**绝对路径**并传入 Terraform。**扁平命名**：有 project 时为 ConfigRoot 下的 `<project>-<env>.yaml`，无 project 时为 `default-<env>.yaml`。本模块仅使用该 YAML 中 global/registry 等 Terraform 所需字段；其他组件由外部 titan-stack 等消费。

## 扁平命名规则（均在 ConfigRoot 下）

| 类型 | 有 project | 无 project |
|------|------------|------------|
| tfvars | `terraform-<project>-<env>.tfvars` | `terraform-<env>.tfvars` |
| 环境 YAML | `<project>-<env>.yaml` | `default-<env>.yaml` |

示例：`make deploy lighthouse dev` 时，引擎在 ConfigRoot 下查找 `terraform-lighthouse-dev.tfvars` 与 `lighthouse-dev.yaml`。

## 配置结构体（输入抽象层）

- **BaseResourceSpec**：基础资源规格（instance_type、region、enable_spot、spot_strategy、spot_price_limit、disk_*、eip_bandwidth、vpc/vswitch/security_group 等）。
- **BaseEnvSpec**：基础环境（k3s_version、cni、acr_server、acr_namespace、config_file）。
- **DeploymentSpec**：应用部署（chart_path、chart_repo_url、chart_name、release_name、namespace、values、values_files）。
- **DeploymentConfig**：顶层配置，包含 `deployment_id`、`provider_name` 以及三层：`default`、`env`、`user_override`。

## 三层合并策略

合并顺序：**Default ← Env ← User Override**。每一层可只填写需要覆盖的字段。调用 `DeploymentConfig.Merge()` 后，结果写入 `DeploymentConfig.Merged`。

### 合并结果示例

例如 default 中设置 `region: cn-hongkong`、`instance_type: ecs.u1-c1m4.xlarge`，user_override 中仅设置 `release_name: my-release`、`namespace: default`。合并后 Merged 中：`region`、`instance_type` 来自 default，`release_name`、`namespace` 来自 user_override。

## 按项目准备配置（在 ConfigRoot 下）

- **Make**：若设置 `CONFIG_ROOT`，则 `-config` 按优先级使用 `$(CONFIG_ROOT)/$(PROJECT).yaml`、`$(PROJECT).json` 或 `deploy.yaml`/`deploy.json`；否则本仓默认使用 **config/** 下 `config/$(PROJECT).yaml`/`.yml`/`.json` 或 `config/deploy.yaml`/`config/deploy.yml`/`config/deploy.json`（请从 **config/deploy.yaml.example** 复制为 config/deploy.yaml 后使用）。
- **建议步骤**：在 ConfigRoot 下放置 `deploy.yaml`/`deploy.json` 或 `<project>.yaml`/`<project>.json`，复制 `config/terraform-<project>-<env>.tfvars.example` 为 `terraform-<project>-<env>.tfvars` 并填写；复制 `config/<project>-<env>.yaml.example` 为 `<project>-<env>.yaml`。

## Terraform 变量（阿里云）

`pkg/config/terraform.go` 提供 `ToAliyunTerraformVars` 与 `WriteAliyunTerraformVarsToFile`。**config_file 由引擎解析为绝对路径**后写入临时 tfvars 并传入 Terraform，Terraform 仅通过 `file(var.config_file)` 读取 YAML。用户维护的 tfvars 在 ConfigRoot 下按扁平命名放置，部署时作为 `-var-file` 传入，覆盖 Merged 中同名字段。

## 从旧路径迁移

旧布局（deprecated，下一大版本将仅支持扁平路径）：

- `config/environments/<env>/terraform.tfvars` → 新：ConfigRoot 下 `terraform-<project>-<env>.tfvars` 或 `terraform-<env>.tfvars`
- `config/environments/<env>/terraform.<project>.tfvars` → 新：合并为单一文件 `terraform-<project>-<env>.tfvars`
- `config/environments/<env>/default.yaml` → 新：ConfigRoot 下 `default-<env>.yaml`
- `config/environments/<env>/<project>-<env>.yaml` → 新：ConfigRoot 下 `<project>-<env>.yaml`

一次性重命名示例（在应用仓 config 或 deploy-engine config 下执行）：

```bash
# 以 project=lighthouse, env=dev 为例
cp config/environments/dev/terraform.tfvars config/terraform-lighthouse-dev.tfvars
cp config/environments/dev/default.yaml config/default-dev.yaml
cp config/environments/dev/lighthouse-dev.yaml config/lighthouse-dev.yaml
```

迁移后通过 `-config` 或 `CONFIG_ROOT` 指定该目录为 ConfigRoot 即可。

## 示例 deploy 配置

YAML 示例见 **config/deploy.yaml.example**（推荐）；等价的 JSON 见 **config/deploy.json.example**。结构包含 `deployment_id`、`provider_name`、`default`（resource/env/deployment）、`user_override` 等。

部署前在 ConfigRoot 下准备好 `terraform-<project>-<env>.tfvars`（含 `instance_password` 等）与 `<project>-<env>.yaml`（或 `default-<env>.yaml`）。
