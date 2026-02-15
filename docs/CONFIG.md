# 配置说明

## 两种配置的职责

- **terraform.tfvars**：驱动 Terraform，管**基础设施**（VPC、ECS、EIP、安全组等）。位于 `config/environments/<env>/terraform.tfvars`，必填如 `instance_password`，可选如 `region`、`instance_type`、`enable_spot`、`spot_price_limit`。部署时由引擎传入 `-var-file` 给 Terraform。
- **deploy.json**：引擎侧**部署配置**，描述资源偏好（BaseResourceSpec）、环境（BaseEnvSpec）、应用（DeploymentSpec）。当前阿里云实现以 tfvars 为主，deploy.json 用于生成 state、CLI 入参及后续扩展（如 Helm 部署）。按项目可放置为 `deploy/config/<project>.json` 或使用根目录 `deploy.json.example`。

## 配置结构体（输入抽象层）

- **BaseResourceSpec**：基础资源规格（instance_type、region、enable_spot、spot_strategy、spot_price_limit、disk_*、eip_bandwidth、vpc/vswitch/security_group 等）。
- **BaseEnvSpec**：基础环境（k3s_version、cni、acr_server、acr_namespace、config_file）。
- **DeploymentSpec**：应用部署（chart_path、chart_repo_url、chart_name、release_name、namespace、values、values_files）。
- **DeploymentConfig**：顶层配置，包含 `deployment_id`、`provider_name` 以及三层：`default`、`env`、`user_override`。

## 三层合并策略

合并顺序：**Default ← Env ← User Override**。每一层可只填写需要覆盖的字段。调用 `DeploymentConfig.Merge()` 后，结果写入 `DeploymentConfig.Merged`。

### 合并结果示例

例如 default 中设置 `region: cn-hongkong`、`instance_type: ecs.u1-c1m4.xlarge`，user_override 中仅设置 `release_name: my-release`、`namespace: default`。合并后 Merged 中：`region`、`instance_type` 来自 default，`release_name`、`namespace` 来自 user_override，其余未填写字段保持 default 或零值。即「只填覆盖项」即可，无需重复填写整份配置。

## 按项目准备配置

- **Make 使用的配置顺序**：若存在 `deploy/config/<project>.json` 则使用该文件，否则使用根目录 `deploy.json.example`。
- **建议步骤**：复制 `deploy.json.example` 为 `deploy/config/<project>.json`，按项目修改 `deployment_id`、`default`/`user_override`；若不需要按项目区分，可一直使用根目录 `deploy.json.example`。
- **示例**（`deploy/config/lighthouse.json`）：与根目录 `deploy.json.example` 结构一致，将 `deployment_id` 改为 `lighthouse`，按需填写 `default.resource`（如 region、instance_type）、`default.env`（如 acr_server、acr_namespace）、`user_override.deployment`（如 release_name、namespace）即可。

## Terraform 变量（阿里云）

`pkg/config/terraform.go` 提供 `ToAliyunTerraformVars(merged, envID, instancePassword)`，将 Merged 映射为 Terraform 变量。实际部署时，tfvars 由用户在 `config/environments/<env>/terraform.tfvars` 中维护（可从 `terraform.tfvars.example` 复制）。

## 示例 deploy.json

```json
{
  "deployment_id": "my-app-001",
  "provider_name": "aliyun",
  "default": {
    "resource": {
      "region": "cn-hongkong",
      "instance_type": "ecs.u1-c1m4.xlarge",
      "spot_price_limit": 0.5
    },
    "env": {
      "acr_server": "registry.cn-hongkong.aliyuncs.com",
      "acr_namespace": "my-ns"
    }
  },
  "user_override": {
    "deployment": {
      "release_name": "my-release",
      "namespace": "default"
    }
  }
}
```

部署前需在 `config/environments/<env>/` 下准备好 `terraform.tfvars`（含 `instance_password` 等）。同时可参考 README 中「按项目准备配置」使用 `deploy/config/<project>.json`。
