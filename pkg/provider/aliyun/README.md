# Aliyun Driver（Terraform 驱动、自包含）

阿里云 ECS + K3s 的驱动实现，**以模块内 Terraform 为唯一基础设施真相源**，不依赖外部 provisioner 仓库。

## 依赖

- 本地已安装 **Terraform**（>= 1.0），且 PATH 可用。
- **阿里云**：具备阿里云账号与 API 凭证。推荐使用环境变量 **`ALICLOUD_ACCESS_KEY`**、**`ALICLOUD_SECRET_KEY`**（阿里云 Terraform Provider 标准变量），或配置文件 `~/.alicloud/config.json`。账号需有权限创建 VPC、ECS、EIP、安全组、NAS、OSS 等资源。
- **instance_password**：ECS root 密码，用于创建实例与 get-kubeconfig 的 SSH。推荐设置环境变量 **`TF_VAR_instance_password`**，否则引擎从 `config/environments/<env>/terraform.tfvars` 中解析。
- **拉取 kubeconfig**：需安装 **sshpass**；ECS 22 端口对当前 IP 开放。
- **模块根目录**：包含 `deploy/terraform/alicloud`、`deploy/scripts`、`config/environments/<env>/`。通过 Driver.Root、`-root` 或环境变量 `DEPLOY_ENGINE_ROOT` 指定；未指定时使用当前工作目录。
- 在 `config/environments/<EnvID>/` 下已准备 `terraform.tfvars`（可从 `terraform.tfvars.example` 复制并填写；若使用 `TF_VAR_instance_password`，tfvars 中可省略或占位）。

## 行为说明

| 方法 | 实现 |
|------|------|
| **Up** | 在 `deploy/terraform/alicloud` 执行 `terraform init`、`terraform apply`，再调用 `get-kubeconfig.sh <EnvID> [Project]` 拉取 kubeconfig。输出路径：**带 project 时为 `~/.kube/config-<project>-<env>`**，否则 `~/.kube/config-<env>`。 |
| **Down** | 执行 `terraform destroy -target=module.ecs`，并删除上述 kubeconfig 文件。 |
| **GetKubeConfig** | 执行脚本并读取与 Up 时相同的 kubeconfig 路径。 |

## 成本与幂等

- **竞价策略**：由 tfvars 中的 `spot_strategy`、`spot_price_limit` 控制。
- **幂等**：对同一 EnvID 重复执行 Up 时，Terraform 会检测现有状态，不会重复创建 ECS。

## 故障排查

- **Terraform 报错**：进入 `deploy/terraform/alicloud` 执行 `terraform plan -var-file=../../config/environments/<env>/terraform.tfvars -var=env_id=<env>` 查看完整错误。常见原因：凭证无效或过期、地域/可用区不可用、资源配额不足、tfvars 语法错误。
- **Kubeconfig 拉取失败**：确认 ECS 已就绪（Terraform output 有 public_ip）、`instance_password` 与 tfvars 中一致、已安装 `sshpass`、安全组允许当前出口 IP 访问 22 端口；可在 ECS 上手动用 root + 密码 SSH 验证。

### 失败时检查顺序

1. **Terraform apply 是否成功**：终端是否有 `terraform apply` 完成且无报错；`terraform output -raw public_ip` 是否返回有效 IP（非空且非 "Instance Released"）。
2. **ECS 是否 Running**：阿里云控制台或 CLI 确认实例状态为运行中。
3. **安全组 22 端口**：当前出口 IP 是否被安全组放行 22（SSH）；可在 ECS 控制台安全组规则中查看。
4. **user-data / OSS 脚本**：若未使用 public-read，确认 ECS 已绑定 RAM Role 且该 Role 具备目标 OSS Bucket 的读权限；可在 ECS 上 `curl -s http://100.100.100.200/latest/meta-data/ram/security-credentials/` 查看是否返回 Role 名。
5. **SSH 登录后查看初始化日志**：`ssh root@<public_ip>`（密码同 tfvars 中 instance_password），执行 `cat /var/log/titan-init.log` 查看 user-data 及 K3s 安装进度与报错。
6. **K3s 服务与端口**：在 ECS 上执行 `systemctl status k3s`、`ss -tlnp | grep 6443`，确认 K3s 已启动且 6443 端口监听。若 K3s 未就绪，可等待数分钟后在本地再次执行 `make kubeconfig <project> <env>`。
