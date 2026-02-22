# 配置示例目录

本目录存放**示例配置文件**，可安全提交到 GitHub（不含敏感信息，使用占位符 `CHANGE_ME`）。

**使用方式**：将需要的示例**复制到 config/ 并重命名**后填写实际值，勿直接使用本目录中的 .example 文件。下表以**本目录实际存在的文件**为准。

| 示例文件（本目录实际存在） | 复制到 config/ 后 |
|----------------------------|-------------------|
| `deploy.yaml.example` | `deploy.yaml` |
| `terraform-dev.tfvars.example` | `terraform-<project>-<env>.tfvars`（有 project 时）或 `terraform-<env>.tfvars`（无 project 时） |
| `default-dev.yaml.example` | `<project>-<env>.yaml`（有 project 时）或 `default-<env>.yaml`（无 project 时） |

详细步骤见 [VERIFICATION.md](../../docs/VERIFICATION.md)。
