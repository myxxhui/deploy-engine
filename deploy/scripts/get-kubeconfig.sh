#!/bin/bash
# ============================================================
# 获取 K3s Kubeconfig（deploy-engine 自包含布局）
# ============================================================
# 脚本位于 deploy/scripts/；PROJECT_ROOT = 仓库根目录

set -euo pipefail

ENV="${1:-dev}"
PROJECT="${2:-}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KUBE_DIR="${KUBECONFIG_DIR:-$HOME/.kube}"
if [ -n "$PROJECT" ]; then
    CONFIG_OUT="$KUBE_DIR/kubeconfig-$PROJECT-$ENV"
else
    CONFIG_OUT="$KUBE_DIR/kubeconfig-$ENV"
fi
TF_LIVE_DIR="$PROJECT_ROOT/deploy/terraform/alicloud"
TFVARS_FILE="$PROJECT_ROOT/config/environments/${ENV}/terraform.tfvars"

# 颜色输出
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[KUBECONFIG]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

warning() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

if [ -n "$PROJECT" ]; then
    log "获取 K3s Kubeconfig (项目: $PROJECT, 环境: $ENV)..."
else
    log "获取 K3s Kubeconfig (环境: $ENV)..."
fi
# 确保 ~/.kube 目录存在
mkdir -p "$KUBE_DIR"

# 1. 从 Terraform 获取 ECS IP（从 live 目录读取状态）
cd "$TF_LIVE_DIR"
if [ ! -f terraform.tfstate ]; then
    error "Terraform 状态文件不存在，请先执行 deploy-engine 部署或 terraform apply"
    exit 1
fi

IP=$(terraform output -raw public_ip 2>/dev/null || echo "")
if [ -z "$IP" ] || [ "$IP" = "Instance Released" ]; then
    error "无法获取 ECS IP，请检查 Terraform 状态"
    exit 1
fi

log "ECS 公网 IP: $IP"

# 注意：所有 SSH 命令都使用 -o UserKnownHostsFile=/dev/null，不需要清理 known_hosts

# 2. 获取密码（从 config/environments/<env>/terraform.tfvars 或环境变量）
PASSWORD=""
if [ -f "$TFVARS_FILE" ]; then
    PASSWORD=$(grep '^instance_password' "$TFVARS_FILE" 2>/dev/null | sed 's/.*= *"\(.*\)".*/\1/' || echo "")
fi

if [ -z "$PASSWORD" ]; then
    PASSWORD="${INSTANCE_PASSWORD:-}"
fi

if [ -z "$PASSWORD" ]; then
    error "无法获取实例密码"
    error "请设置 INSTANCE_PASSWORD 环境变量，或在 $TFVARS_FILE 中配置 instance_password"
    exit 1
fi

# 3. 等待 K3s 就绪并下载 kubeconfig
log "等待 K3s API Server 就绪..."
MAX_RETRIES=60
RETRY_COUNT=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    # 尝试通过 SSH 获取 kubeconfig
    if sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 root@"$IP" \
        "test -f /etc/rancher/k3s/k3s.yaml && kubectl cluster-info --request-timeout=5s >/dev/null 2>&1" 2>/dev/null; then
        log "K3s 已就绪"
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $((RETRY_COUNT % 10)) -eq 0 ]; then
        log "等待中... ($RETRY_COUNT/$MAX_RETRIES)"
    fi
    sleep 5
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    error "K3s 未在预期时间内就绪"
    exit 1
fi

# 4. 下载 kubeconfig
log "下载 Kubeconfig..."
sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"$IP" \
    "cat /etc/rancher/k3s/k3s.yaml" > "$CONFIG_OUT" || {
    error "下载 Kubeconfig 失败"
    exit 1
}

# 5. 替换 server 地址为公网 IP（必须替换，确保远程访问）
log "替换 server 地址为公网 IP: $IP"
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS 使用 sed -i ''
    sed -i '' "s|server: https://127.0.0.1:6443|server: https://$IP:6443|g" "$CONFIG_OUT"
else
    sed -i.bak "s|server: https://127.0.0.1:6443|server: https://$IP:6443|g" "$CONFIG_OUT"
    rm -f "${CONFIG_OUT}.bak"
fi

# 验证替换是否成功
if ! grep -q "server: https://$IP:6443" "$CONFIG_OUT"; then
    error "替换 server 地址失败"
    exit 1
fi
log "✅ Server 地址已替换为公网 IP"

# 6. 设置权限
chmod 600 "$CONFIG_OUT"

# 7. 验证连接
log "验证 Kubeconfig 连接..."
export KUBECONFIG="$CONFIG_OUT"
if kubectl cluster-info --request-timeout=10s >/dev/null 2>&1; then
    log "✅ Kubeconfig 验证成功"
    log "配置文件: $CONFIG_OUT"
    echo ""
    echo "使用方法："
    echo "   export KUBECONFIG=$CONFIG_OUT"
    echo "   kubectl get nodes"
else
    warning "Kubeconfig 连接验证失败，但文件已保存"
fi
