# Aliyun Driver（Terraform 驱动、自包含）

阿里云 ECS + K3s 的驱动实现，**以模块内 Terraform 为唯一基础设施真相源**，不依赖外部 provisioner 仓库。

## 依赖

- 本地已安装 **Terraform**（>= 1.0），且 PATH 可用。
- **阿里云**：具备阿里云账号与 API 凭证（环境变量或 `~/.alicloud/config.json` 等），且账号有权限创建 VPC、ECS、EIP、安全组、NAS、OSS 等资源。
- **拉取 kubeconfig**：需安装 **sshpass**（脚本通过 SSH 从 ECS 拉取 kubeconfig）；ECS 22 端口对当前 IP 开放，且 `terraform.tfvars` 中的 `instance_password` 与实例 root 密码一致。
- **模块根目录**：包含 `deploy/terraform/alicloud`、`deploy/scripts`、`config/environments/<env>/`。通过 Driver.Root、`-root` 或环境变量 `DEPLOY_ENGINE_ROOT` 指定；未指定时使用当前工作目录。
- 在 `config/environments/<EnvID>/` 下已准备 `terraform.tfvars`（可从 `terraform.tfvars.example` 复制并填写）。

## 行为说明

| 方法 | 实现 |
|------|------|
| **Up** | 在 `deploy/terraform/alicloud` 执行 `terraform init`、`terraform apply`，再调用 `get-kubeconfig.sh <EnvID> [Project]` 拉取 kubeconfig。输出路径：**带 project 时为 `~/.kube/kubeconfig-<project>-<env>`**，否则 `~/.kube/kubeconfig-<env>`。 |
| **Down** | 执行 `terraform destroy -target=module.ecs`，并删除上述 kubeconfig 文件。 |
| **GetKubeConfig** | 执行脚本并读取与 Up 时相同的 kubeconfig 路径。 |

## 成本与幂等

- **竞价策略**：由 tfvars 中的 `spot_strategy`、`spot_price_limit` 控制。
- **幂等**：对同一 EnvID 重复执行 Up 时，Terraform 会检测现有状态，不会重复创建 ECS。

## 故障排查

- **Terraform 报错**：进入 `deploy/terraform/alicloud` 执行 `terraform plan -var-file=../../config/environments/<env>/terraform.tfvars -var=env_id=<env>` 查看完整错误。常见原因：凭证无效或过期、地域/可用区不可用、资源配额不足、tfvars 语法错误。
- **Kubeconfig 拉取失败**：确认 ECS 已就绪（Terraform output 有 public_ip）、`instance_password` 与 tfvars 中一致、已安装 `sshpass`、安全组允许当前出口 IP 访问 22 端口；可在 ECS 上手动用 root + 密码 SSH 验证。
