#!/usr/bin/env bash
# NAS AlreadyAttached 恢复脚本
# 当 Terraform 报 InvalidAccessGroup.AlreadyAttached 时，从 state 移除 Access Group 后重新导入
# 用法:
#   ./scripts/fix-nas-state.sh <project_name> <env_id> [tf_dir]
#   ./scripts/fix-nas-state.sh <project> <env> [config_root]   # 从 <project>-<env>.yaml 读取 project_name
# 若只传 project 和 env，会尝试从 config/<project>-<env>.yaml 的 global.project_name 解析
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_ROOT="${3:-$ROOT_DIR/config}"
PROJECT_ARG="${1:-}"
ENV_ARG="${2:-dev}"

if [[ -n "$PROJECT_ARG" ]] && [[ -f "$CONFIG_ROOT/${PROJECT_ARG}-${ENV_ARG}.yaml" ]]; then
  PROJECT_NAME=$(grep -m1 'project_name:' "$CONFIG_ROOT/${PROJECT_ARG}-${ENV_ARG}.yaml" 2>/dev/null | sed -E 's/.*project_name:[[:space:]]*"?([^"]+)"?.*/\1/' | tr -d ' ' || true)
  [[ -z "$PROJECT_NAME" ]] && PROJECT_NAME="$PROJECT_ARG"
  echo "从 $CONFIG_ROOT/${PROJECT_ARG}-${ENV_ARG}.yaml 解析 project_name=$PROJECT_NAME"
else
  PROJECT_NAME="${PROJECT_ARG:?请提供 project（如 myapp）}"
fi

TF_DIR="$(cd "$ROOT_DIR/deploy/terraform/alicloud" && pwd)"

AG_NAME="${PROJECT_NAME}_nas_group_${ENV_ARG}"
IMPORT_ID="${AG_NAME}:standard"

echo "修复 NAS Access Group state（project_name=$PROJECT_NAME, env=$ENV_ARG）"
echo "  Terraform 目录: $TF_DIR"
echo "  Access Group: $AG_NAME"
echo ""

# 清理可能残留的 terraform import/apply 进程（避免 state lock）
STALE_PIDS=$(pgrep -f "terraform import|terraform apply" 2>/dev/null || true)
if [[ -n "$STALE_PIDS" ]]; then
  echo "发现残留 Terraform 进程，正在清理以防 state lock: $STALE_PIDS"
  for pid in $STALE_PIDS; do kill -9 "$pid" 2>/dev/null; done
  sleep 2
fi

cd "$TF_DIR"

TFVARS="$CONFIG_ROOT/terraform-${PROJECT_ARG}-${ENV_ARG}.tfvars"
CONFIG_YAML_ABS="$(cd "$CONFIG_ROOT" 2>/dev/null && pwd)/${PROJECT_ARG}-${ENV_ARG}.yaml"
VAR_ARGS=(-var="env_id=$ENV_ARG" -var="config_file=$CONFIG_YAML_ABS")
[[ -f "$TFVARS" ]] && VAR_ARGS+=(-var-file="$TFVARS")

echo "1. 从 state 移除 module.nas.alicloud_nas_access_group.main ..."
terraform state rm 'module.nas.alicloud_nas_access_group.main' 2>/dev/null || echo "  （state 中不存在则忽略）"

echo "2. 重新导入 Access Group: $IMPORT_ID ..."
terraform import "${VAR_ARGS[@]}" 'module.nas.alicloud_nas_access_group.main[0]' "$IMPORT_ID"

echo ""
echo "完成。请确认 tfvars 中 nas_use_existing_access_group = false，然后执行 make deploy <project> <env>"
