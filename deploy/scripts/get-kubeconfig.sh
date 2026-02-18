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
    CONFIG_OUT="$KUBE_DIR/config-$PROJECT-$ENV"
else
    CONFIG_OUT="$KUBE_DIR/config-$ENV"
fi
TF_LIVE_DIR="$PROJECT_ROOT/deploy/terraform/alicloud"
# 与 deploy-engine 扁平命名一致：优先 terraform-<project>-<env>.tfvars，否则 terraform-<env>.tfvars，最后回退旧路径
if [ -n "$PROJECT" ]; then
    FLAT_TFVARS="$PROJECT_ROOT/config/terraform-${PROJECT}-${ENV}.tfvars"
else
    FLAT_TFVARS="$PROJECT_ROOT/config/terraform-${ENV}.tfvars"
fi
if [ -f "$FLAT_TFVARS" ]; then
    TFVARS_FILE="$FLAT_TFVARS"
else
    TFVARS_FILE="$PROJECT_ROOT/config/environments/${ENV}/terraform.tfvars"
fi

# 颜色输出
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[KUBECONFIG]${NC} $*" >&2
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

warning() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
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

# 清除本机对该 IP 的旧 SSH 主机密钥，避免新集群复用 IP 时与旧 ECS 凭证冲突
if [ -f "$HOME/.ssh/known_hosts" ]; then
    ssh-keygen -R "$IP" -f "$HOME/.ssh/known_hosts" 2>/dev/null || true
fi

# 注意：脚本内 SSH 使用 -o UserKnownHostsFile=/dev/null，不读写 known_hosts；上述清理便于本机后续手动 ssh 时也不冲突

# 2. 获取密码（从 TFVARS_FILE：扁平 terraform-<project>-<env>.tfvars 或旧路径，或环境变量）
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

# 3. 等待 K3s 就绪并下载 kubeconfig（轮询检测，就绪后立即继续；可通过 KUBECONFIG_MAX_RETRIES、KUBECONFIG_SLEEP_SEC 调整）
log "等待 K3s API Server 就绪..."
MAX_RETRIES="${KUBECONFIG_MAX_RETRIES:-60}"
KUBECONFIG_SLEEP="${KUBECONFIG_SLEEP_SEC:-3}"
RETRY_COUNT=0

# 每若干次重试输出一次诊断，便于排查「一直等不到就绪」的原因
diagnose_k3s() {
    local diag
    if ! sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 root@"$IP" "exit 0" 2>/dev/null; then
        diag="SSH 连接失败。请检查: (1) 安全组放行 22 且来源含本机 IP (2) config/terraform-* tfvars 中 instance_password 正确 (3) 本机执行: ssh -o ConnectTimeout=5 root@$IP"
    else
        local has_yaml
        has_yaml=$(sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 root@"$IP" "test -f /etc/rancher/k3s/k3s.yaml && echo 1 || echo 0" 2>/dev/null)
        if [ "$has_yaml" != "1" ]; then
            diag="ECS 上未发现 K3s（/etc/rancher/k3s/k3s.yaml 不存在）。可能原因: (1) OSS 上的初始化脚本未下载成功（需 ECS 绑定 RAM Role 且角色具备 OSS 读权限）(2) 实例为旧资源或 cloud-init 未跑完。建议: make down 再 make deploy 重建，或 SSH 上机查看 /var/log/titan-init.log"
        else
            if ! sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 root@"$IP" 'kubectl cluster-info --request-timeout=5' >/dev/null 2>&1; then
                diag="K3s 已安装但 API 未就绪（可能仍在启动），请稍候"
            else
                diag="检查通过但主流程未命中，将重试"
            fi
        fi
    fi
    warning "诊断: $diag"
}

while [ "$RETRY_COUNT" -lt "$MAX_RETRIES" ]; do
    # 尝试通过 SSH 获取 kubeconfig
    if sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 root@"$IP" \
        'test -f /etc/rancher/k3s/k3s.yaml && kubectl cluster-info --request-timeout=5 >/dev/null 2>&1' 2>/dev/null; then
        log "K3s 已就绪"
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $((RETRY_COUNT % 3)) -eq 0 ]; then
        log "等待中... (${RETRY_COUNT}/${MAX_RETRIES})，约 $((RETRY_COUNT * KUBECONFIG_SLEEP))s"
    fi
    if [ $((RETRY_COUNT % 6)) -eq 0 ] && [ "$RETRY_COUNT" -gt 0 ]; then
        diagnose_k3s
    fi
    sleep "$KUBECONFIG_SLEEP"
done

if [ "$RETRY_COUNT" -eq "$MAX_RETRIES" ]; then
    diagnose_k3s
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
