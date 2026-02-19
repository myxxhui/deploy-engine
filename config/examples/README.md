# 配置示例目录

本目录存放**示例配置文件**，可安全提交到 GitHub（不含敏感信息，使用占位符 `CHANGE_ME`）。

**使用方式**：将需要的示例复制到 `config/` 并重命名后填写实际值，勿直接使用本目录中的文件。

| 示例文件 | 复制到 config/ 后 |
|----------|-------------------|
| `deploy.yaml.example` | `deploy.yaml` |
| `terraform-lighthouse-dev.tfvars.example` | `terraform-<project>-<env>.tfvars` |
| `terraform-dev.tfvars.example` | `terraform-<env>.tfvars`（无 project 时） |
| `lighthouse-dev.yaml.example` | `<project>-<env>.yaml` |
| `default-dev.yaml.example` | `default-<env>.yaml`（无 project 时） |

详细步骤见 [VERIFICATION.md](../../docs/VERIFICATION.md)。
