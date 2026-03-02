#!/bin/bash
# ============================================================
# 获取 K3s Kubeconfig（deploy-engine 自包含布局）
# ============================================================
# 脚本位于 deploy/scripts/；PROJECT_ROOT = 仓库根目录

set -euo pipefail
set +H
# 禁用历史展开，避免密码中的 !! 等被展开；且优先使用环境变量避免 tfvars 解析问题

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
# 与 deploy-engine 扁平命名一致：① 若调用方传入 CONFIG_ROOT 或 TFVARS_FILE（如从 diting-infra 调用时），优先使用；② 否则 PROJECT_ROOT/config 下 terraform-<project>-<env>.tfvars 等
if [ -n "${TFVARS_FILE:-}" ] && [ -f "$TFVARS_FILE" ]; then
    : # 调用方已指定且文件存在，直接使用
elif [ -n "${CONFIG_ROOT:-}" ] && [ -d "$CONFIG_ROOT" ]; then
    if [ -n "$PROJECT" ]; then
        FLAT_TFVARS="$CONFIG_ROOT/terraform-${PROJECT}-${ENV}.tfvars"
        FALLBACK_TFVARS="$CONFIG_ROOT/terraform-${ENV}.tfvars"
    else
        FLAT_TFVARS="$CONFIG_ROOT/terraform-${ENV}.tfvars"
        FALLBACK_TFVARS=""
    fi
    if [ -f "$FLAT_TFVARS" ]; then
        TFVARS_FILE="$FLAT_TFVARS"
    elif [ -n "${FALLBACK_TFVARS:-}" ] && [ -f "$FALLBACK_TFVARS" ]; then
        TFVARS_FILE="$FALLBACK_TFVARS"
    else
        TFVARS_FILE="$CONFIG_ROOT/environments/${ENV}/terraform.tfvars"
    fi
else
    if [ -n "$PROJECT" ]; then
        FLAT_TFVARS="$PROJECT_ROOT/config/terraform-${PROJECT}-${ENV}.tfvars"
        FALLBACK_TFVARS="$PROJECT_ROOT/config/terraform-${ENV}.tfvars"
    else
        FLAT_TFVARS="$PROJECT_ROOT/config/terraform-${ENV}.tfvars"
        FALLBACK_TFVARS=""
    fi
    if [ -f "$FLAT_TFVARS" ]; then
        TFVARS_FILE="$FLAT_TFVARS"
    elif [ -n "${FALLBACK_TFVARS:-}" ] && [ -f "$FALLBACK_TFVARS" ]; then
        TFVARS_FILE="$FALLBACK_TFVARS"
    else
        TFVARS_FILE="$PROJECT_ROOT/config/environments/${ENV}/terraform.tfvars"
    fi
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

# 2. 获取密码（优先环境变量，避免 tfvars 中含 ! 等字符时解析错误；与「本机可 SSH 脚本却失败」时用 export INSTANCE_PASSWORD 重试）
PASSWORD="${INSTANCE_PASSWORD:-}"
if [ -z "$PASSWORD" ] && [ -f "$TFVARS_FILE" ]; then
    PASSWORD=$(grep '^[[:space:]]*instance_password' "$TFVARS_FILE" 2>/dev/null | sed -n 's/.*= *"\([^"]*\)".*/\1/p' | head -n1)
fi

if [ -z "$PASSWORD" ]; then
    error "无法获取实例密码"
    error "请设置 INSTANCE_PASSWORD 环境变量，或在 $TFVARS_FILE 中配置 instance_password"
    exit 1
fi

if ! command -v sshpass >/dev/null 2>&1; then
    error "未找到 sshpass，脚本需其自动传密。请安装（如 yum install sshpass 或 apt install sshpass）或在本机执行: export INSTANCE_PASSWORD='你的密码' 后单独运行 ./deploy/scripts/get-kubeconfig.sh $ENV ${PROJECT:-}"
    exit 1
fi

# 调试：密码长度与来源（不输出明文），便于排查「本机可 SSH 脚本失败」
if [ -n "${INSTANCE_PASSWORD:-}" ]; then
    PASSWORD_SOURCE="INSTANCE_PASSWORD"
else
    PASSWORD_SOURCE="tfvars"
fi
log "密码长度: ${#PASSWORD}，来源: $PASSWORD_SOURCE"

# 3. 若 ECS 已存在但 K3s 未部署，远程下载并执行初始化脚本（无需重建 ECS）
MAX_RETRIES="${KUBECONFIG_MAX_RETRIES:-60}"
KUBECONFIG_SLEEP="${KUBECONFIG_SLEEP_SEC:-3}"
RETRY_COUNT=0

# 使用 SSHPASS 环境变量传密（sshpass -e），避免 -p 与含 ! 等字符时的解析问题
run_ssh() {
    SSHPASS="$PASSWORD" sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 root@"$IP" "$@"
}

# 等待 ECS SSH 就绪（Terraform 创建 ECS 后首次执行时 sshd 可能尚未启动，避免首次 OSS 下载因 SSH 未就绪而失败）
wait_for_ssh() {
    local max_attempts="${SSH_WAIT_MAX_ATTEMPTS:-30}"
    local sleep_sec="${SSH_WAIT_SLEEP_SEC:-5}"
    local attempt=1
    while [ "$attempt" -le "$max_attempts" ]; do
        if run_ssh 'exit 0' 2>/dev/null; then
            log "SSH 已就绪 (尝试 $attempt/$max_attempts)"
            return 0
        fi
        log "等待 ECS SSH 就绪... ($attempt/$max_attempts)，${sleep_sec}s 后重试"
        sleep "$sleep_sec"
        attempt=$((attempt + 1))
    done
    error "ECS SSH 在 ${max_attempts} 次尝试后仍不可用，请检查实例状态与安全组"
    return 1
}

# 远程执行 K3s 初始化脚本：SSH 到 ECS，从 OSS 下载 k3s-init.sh 并执行（用于 ECS 已存在但 user-data 未成功执行的场景）
remote_run_init_script() {
    local oss_bucket oss_region oss_url
    oss_bucket=$(terraform output -raw oss_bucket_name 2>/dev/null || echo "")
    oss_region=$(terraform output -raw oss_region 2>/dev/null || echo "")
    if [ -z "$oss_bucket" ] || [ -z "$oss_region" ]; then
        error "无法获取 oss_bucket_name / oss_region，请检查 Terraform 输出"
        return 1
    fi
    oss_url="https://${oss_bucket}.oss-${oss_region}.aliyuncs.com/scripts/k3s-init.sh"
    log "ECS 已存在但 K3s 未部署，正在远程下载并执行初始化脚本: $oss_url"
    local max_dl_attempts="${OSS_DOWNLOAD_MAX_ATTEMPTS:-3}"
    local dl_sleep="${OSS_DOWNLOAD_RETRY_SLEEP_SEC:-10}"
    local dl_attempt=1
    while [ "$dl_attempt" -le "$max_dl_attempts" ]; do
        if run_ssh "curl -f -s '$oss_url' -o /tmp/k3s-init.sh || wget -q '$oss_url' -O /tmp/k3s-init.sh" 2>/dev/null; then
            break
        fi
        if [ "$dl_attempt" -eq "$max_dl_attempts" ]; then
            error "远程下载 OSS 脚本失败。请检查：1) 桶 $oss_bucket 权限（public-read 或 ram_role_name）；2) ECS 能否访问 OSS；3) 对象 scripts/k3s-init.sh 是否存在且可读"
            log "ECS 上诊断（HTTP 状态）："
            run_ssh "curl -s -o /dev/null -w '%{http_code}' '$oss_url' 2>/dev/null || echo 'curl 不可用'" 2>/dev/null | sed 's/^/  HTTP 状态: /' >&2
            error "详见 docs/VERIFICATION.md 1.11 脚本未下载常见原因与处理建议"
            return 1
        fi
        log "下载未成功，${dl_sleep}s 后重试 ($dl_attempt/$max_dl_attempts)..."
        sleep "$dl_sleep"
        dl_attempt=$((dl_attempt + 1))
    done
    if ! run_ssh "test -s /tmp/k3s-init.sh" 2>/dev/null; then
        error "下载后 /tmp/k3s-init.sh 为空或不存在，请检查 OSS 对象 scripts/k3s-init.sh 是否已由 Terraform 上传"
        return 1
    fi
    run_ssh "chmod +x /tmp/k3s-init.sh && /tmp/k3s-init.sh" 2>/dev/null || {
        error "远程执行初始化脚本失败，请 SSH 查看 /var/log/k3s-init.log"
        return 1
    }
    log "初始化脚本执行完成，等待 K3s 就绪..."
    return 0
}

# 在等待循环前：先确保 ECS SSH 就绪，再判断是否需远程执行 init 脚本（避免首次 deploy 因 SSH 未就绪导致 OSS 下载报错）
wait_for_ssh || exit 1
if ! run_ssh 'test -f /etc/rancher/k3s/k3s.yaml' 2>/dev/null; then
    if ! remote_run_init_script; then
        exit 1
    fi
fi

# 4. 等待 K3s 就绪并下载 kubeconfig（轮询检测，就绪后立即继续）
log "等待 K3s API Server 就绪..."

# 每若干次重试输出一次诊断，便于排查「一直等不到就绪」的原因
# 注意：以 SSH 退出码判断成败，不能以 stderr 非空判断（SSH 会把 "Permanently added ... to known_hosts" 打到 stderr，连接仍成功）
diagnose_k3s() {
    local err
    err=$(SSHPASS="$PASSWORD" sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 root@"$IP" "exit 0" 2>&1)
    local ret=$?
    if [ $ret -ne 0 ]; then
        local diag
        if echo "$err" | grep -q "Permission denied"; then
            diag="SSH 认证失败（Permission denied），多为密码错误。请执行: export INSTANCE_PASSWORD='你的密码' 后重试"
        elif echo "$err" | grep -qi "timed out\|Connection refused"; then
            diag="SSH 连接超时或拒绝。若本机可通而脚本不通，可能是运行环境无法访问 ECS，请在本机执行: ./deploy/scripts/get-kubeconfig.sh $ENV ${PROJECT:-}"
        else
            diag="SSH 连接失败（exit $ret）。原始错误: $(echo "$err" | grep -v "Permanently added" | head -1)"
        fi
        warning "诊断: $diag"
    else
        local has_yaml
        has_yaml=$(run_ssh "test -f /etc/rancher/k3s/k3s.yaml && echo 1 || echo 0" 2>/dev/null)
        if [ "$has_yaml" != "1" ]; then
            # 若尚未尝试过远程执行 init，则尝试一次（ECS 已存在但 user-data 未成功执行时补救）
            if [ "${REMOTE_INIT_TRIED:-0}" = "0" ]; then
                REMOTE_INIT_TRIED=1
                if remote_run_init_script; then
                    :
                fi
            fi
            # 检查 init 是否因 OSS 下载失败而退出
            local init_log
            init_log=$(run_ssh "cat /var/log/k3s-init.log 2>/dev/null || true" 2>/dev/null)
            if echo "$init_log" | grep -qE "OSS 脚本下载失败|下载失败|err_exit|脚本文件为空"; then
                error "ECS 初始化失败：OSS 脚本下载或执行失败。请检查："
                error "  1) 存储桶权限与 init_script_acl（public-read / ram_role_name）"
                error "  2) /var/log/k3s-init.log 完整日志"
                exit 1
            fi
            warning "诊断: ECS 上未发现 K3s。若 user-data 未执行，脚本会尝试远程下载并执行初始化。"
        else
            if ! run_ssh 'kubectl cluster-info --request-timeout=5' >/dev/null 2>&1; then
                warning "诊断: K3s 已安装但 API 未就绪（可能仍在启动），请稍候"
            fi
        fi
    fi
}

while [ "$RETRY_COUNT" -lt "$MAX_RETRIES" ]; do
    # 尝试通过 SSH 获取 kubeconfig
    if run_ssh 'test -f /etc/rancher/k3s/k3s.yaml && kubectl cluster-info --request-timeout=5 >/dev/null 2>&1' 2>/dev/null; then
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

# 5. 下载 kubeconfig
log "下载 Kubeconfig..."
run_ssh "cat /etc/rancher/k3s/k3s.yaml" > "$CONFIG_OUT" || {
    error "下载 Kubeconfig 失败"
    exit 1
}

# 6. 替换 server 地址为公网 IP（必须替换，确保远程访问）
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

# 7. 设置权限
chmod 600 "$CONFIG_OUT"

# 8. 验证连接
log "验证 Kubeconfig 连接..."
export KUBECONFIG="$CONFIG_OUT"
if kubectl cluster-info --request-timeout=10s >/dev/null 2>&1; then
    log "✅ Kubeconfig 验证成功"
    log "配置文件: $CONFIG_OUT"
    
    # 9. 设置 KUBECONFIG 环境变量指向新文件（不合并）
    log "正在配置 KUBECONFIG 环境变量..."
    
    # 添加到 shell 配置文件（bash/zsh 均支持；文件不存在则创建，保证新开终端默认可用）
    KUBECONFIG_EXPORT="export KUBECONFIG=\"$CONFIG_OUT\""
    
    for RC_FILE in ~/.bashrc ~/.zshrc ~/.profile; do
        [ -f "$RC_FILE" ] || touch "$RC_FILE"
        # 移除旧的 KUBECONFIG 设置
        sed -i.bak '/export KUBECONFIG.*config-.*-/d' "$RC_FILE" 2>/dev/null || \
            sed -i '' '/export KUBECONFIG.*config-.*-/d' "$RC_FILE" 2>/dev/null || true
        if ! grep -q "export KUBECONFIG=\"$CONFIG_OUT\"" "$RC_FILE" 2>/dev/null; then
            echo "$KUBECONFIG_EXPORT" >> "$RC_FILE"
            log "已添加到 $RC_FILE"
        fi
    done
    
    log "✅ KUBECONFIG 已配置为: $CONFIG_OUT（已写入 .bashrc / .zshrc / .profile，新开终端默认生效）"
    echo ""
    echo "使用方法："
    echo "   1. 当前终端立即生效："
    echo "      export KUBECONFIG=\"$CONFIG_OUT\""
    echo ""
    echo "   2. 新终端自动生效（已写入 shell 配置文件）"
    echo ""
    echo "   3. 验证连接："
    echo "      kubectl get nodes"
    echo "      kubectl get pods -A"
    echo ""
    echo "配置文件位置: $CONFIG_OUT"
else
    warning "Kubeconfig 连接验证失败，但文件已保存"
fi
