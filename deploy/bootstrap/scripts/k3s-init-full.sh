#!/bin/bash
set -euo pipefail

# 配置变量（由 Terraform 传入）
NAS_MOUNT_DOMAIN="${nas_mount_domain}"
PROJECT_NAME="${project_name}"
NAS_MOUNT_POINT="/mnt/titan-data"
K3S_TOKEN_FILE="$${NAS_MOUNT_POINT}/k3s-token"
OSS_BUCKET_NAME="${oss_bucket_name}"
OSS_ENDPOINT="${oss_endpoint}"
OSS_REGION="${oss_region}"
K3S_STORAGE_PATH="/var/lib/rancher/k3s/storage"
ACR_SERVER="${acr_server}"
ACR_NAMESPACE="${acr_namespace}"

# 日志函数（统一日志路径，中文输出；用反引号避免 $$ 被误解析为 PID）
log() {
  echo "[`date +'%Y-%m-%d %H:%M:%S'`] $${*}" | tee -a /var/log/k3s-init.log
}

log "=== K3s 集群初始化开始 ==="

# 注意：SSH 服务启动已移至 runcmd 的第一项，确保即使初始化失败也能远程登录

# ==============================================================================
# 第一优先级：彻底禁用 apt-daily 服务，防止磁盘锁竞争
# ==============================================================================
log "[优先级 1] 禁用 apt-daily 服务，防止系统更新干扰..."
systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
systemctl disable apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl disable apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl mask apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
systemctl mask apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
log "✅ apt-daily 服务已彻底禁用"

# ==============================================================================
# 第二优先级：NAS 挂载和目录创建（不依赖网络下载，优先完成）
# ==============================================================================
log "[优先级 2] 挂载 NAS 存储并创建必要目录（不依赖网络）..."

# 确保 NFS 工具已安装
if ! command -v mount.nfs >/dev/null 2>&1 && [ ! -f /sbin/mount.nfs ]; then
  log "安装 nfs-common 包..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y -qq nfs-common >/dev/null 2>&1 || {
    log "⚠️  nfs-common 安装失败，尝试继续..."
  }
  log "✅ nfs-common 安装完成"
fi

# 创建挂载点
mkdir -p "$${NAS_MOUNT_POINT}"

# 重试挂载逻辑（至少重试 15 次）
MOUNT_RETRY_COUNT=0
MOUNT_MAX_RETRIES=15
MOUNT_SUCCESS=false

while [ $${MOUNT_RETRY_COUNT} -lt $${MOUNT_MAX_RETRIES} ]; do
  if mount -t nfs -o vers=4.0,noresvport "$${NAS_MOUNT_DOMAIN}:/" "$${NAS_MOUNT_POINT}" 2>&1 | tee -a /var/log/k3s-init.log; then
    log "✅ NAS 挂载成功！"
    MOUNT_SUCCESS=true
    break
  fi
  MOUNT_RETRY_COUNT=$((MOUNT_RETRY_COUNT + 1))
  log "NAS 挂载失败，重试 $${MOUNT_RETRY_COUNT}/$${MOUNT_MAX_RETRIES}... (可能因为网络初始化未完成)"
  sleep 3
done

if [ "$${MOUNT_SUCCESS}" != "true" ]; then
  log "❌ 错误: NAS 挂载失败，已达到最大重试次数"
  exit 1
fi

# 确保挂载点在重启后自动挂载
if ! grep -q "$${NAS_MOUNT_DOMAIN}" /etc/fstab 2>/dev/null; then
  echo "$${NAS_MOUNT_DOMAIN}:/ $${NAS_MOUNT_POINT} nfs vers=4.0,noresvport,auto,soft,timeo=30,retrans=3 0 0" >> /etc/fstab
fi

# 创建必要目录（不依赖网络）
mkdir -p "$${NAS_MOUNT_POINT}/k3s-backup"
log "✅ NAS 备份目录已创建"

# 检查并恢复 K3s Token（防数据丢失：Token 持久化）
log "[优先级 2] 检查 K3s Token 持久化..."
K3S_TOKEN=""
if [ -f "$${K3S_TOKEN_FILE}" ]; then
  K3S_TOKEN=$(cat "$${K3S_TOKEN_FILE}")
  log "✅ 从 NAS 恢复 K3s Token: $${K3S_TOKEN}..."
else
  K3S_TOKEN=$(openssl rand -hex 32)
  echo "$${K3S_TOKEN}" > "$${K3S_TOKEN_FILE}"
  log "✅ 生成新的 K3s Token 并保存到 NAS: $${K3S_TOKEN}..."
fi

# ==============================================================================
# 第三优先级：极速模式安装 K3s（使用国内镜像加速）
# ==============================================================================
log "[优先级 3] 开始极速安装 K3s（系统磁盘运行，不依赖 OSS）..."

# 获取公网 IP（用于 TLS SAN）
log "获取公网 IP 地址（用于 K3s TLS 证书）..."
PUBLIC_IP=""
RETRY_COUNT=0
MAX_RETRIES=10

while [ -z "$${PUBLIC_IP}" ] && [ $${RETRY_COUNT} -lt $${MAX_RETRIES} ]; do
  PUBLIC_IP=$(curl -s --max-time 5 https://api.ipify.org || true)
  if [ -n "$${PUBLIC_IP}" ]; then
    log "✅ 成功获取公网 IP: $${PUBLIC_IP}"
    break
  fi
  RETRY_COUNT=$((RETRY_COUNT + 1))
  log "获取公网 IP 失败，重试 $${RETRY_COUNT}/$${MAX_RETRIES}..."
  sleep 2
done

if [ -z "$${PUBLIC_IP}" ]; then
  log "⚠️ 警告: 无法获取公网 IP，使用 127.0.0.1"
  PUBLIC_IP="127.0.0.1"
fi

# ==============================================================================
# [新增步骤] 自动恢复逻辑：检查是否有"前世记忆"
# ==============================================================================
log "[中间步骤] 检查是否存在历史快照，准备恢复..."

# 确保 NAS 挂载点可用
if [ -d "$${NAS_MOUNT_POINT}" ] && mountpoint -q "$${NAS_MOUNT_POINT}" 2>/dev/null; then
  # 寻找 NAS 中最新的快照文件（优先 on-demand-*，然后是 snapshot-shutdown-*）
  LATEST_SNAPSHOT=""
  
  # 优先查找定时快照（命名格式：on-demand-* 或其他 K3s 自动生成的快照）
  if ls "$${NAS_MOUNT_POINT}/k3s-backup"/on-demand-* 1>/dev/null 2>&1; then
    LATEST_SNAPSHOT=$(ls -t "$${NAS_MOUNT_POINT}/k3s-backup"/on-demand-* 2>/dev/null | head -n1)
  fi
  
  # 如果找不到定时快照，找关机快照（临终遗言）
  if [ -z "$${LATEST_SNAPSHOT}" ]; then
    if ls "$${NAS_MOUNT_POINT}/k3s-backup"/snapshot-shutdown-* 1>/dev/null 2>&1; then
      LATEST_SNAPSHOT=$(ls -t "$${NAS_MOUNT_POINT}/k3s-backup"/snapshot-shutdown-* 2>/dev/null | head -n1)
    fi
  fi
  
  # 如果还是找不到，尝试查找任何快照文件（K3s 默认命名格式）
  if [ -z "$${LATEST_SNAPSHOT}" ]; then
    if ls "$${NAS_MOUNT_POINT}/k3s-backup"/*-etcd-snapshot* 1>/dev/null 2>&1; then
      LATEST_SNAPSHOT=$(ls -t "$${NAS_MOUNT_POINT}/k3s-backup"/*-etcd-snapshot* 2>/dev/null | head -n1)
    fi
  fi

  # 只有当本地没有数据（全新实例）且 NAS 有快照时，才执行恢复
  if [ ! -d "/var/lib/rancher/k3s/server/db" ] && [ -n "$${LATEST_SNAPSHOT}" ] && [ -f "$${LATEST_SNAPSHOT}" ]; then
    log "♻️ 检测到历史快照: $${LATEST_SNAPSHOT}，开始执行集群状态恢复..."
    
    # 1. 先下载 K3s 二进制文件（但不启动服务）
    log "下载 K3s 二进制文件（用于恢复）..."
    export INSTALL_K3S_MIRROR=cn
    export INSTALL_K3S_VERSION=v1.31.4+k3s1
    curl -sfL https://rancher-mirror.rancher.cn/k3s/k3s-install.sh | INSTALL_K3S_SKIP_ENABLE=true sh -
    
    if [ $$? -eq 0 ] && [ -f /usr/local/bin/k3s ]; then
      log "✅ K3s 二进制文件下载成功"
      
      # 2. 执行恢复命令（关键！）
      log "执行集群状态恢复..."
      /usr/local/bin/k3s server \
        --cluster-reset \
        --cluster-reset-restore-path "$${LATEST_SNAPSHOT}" \
        --token "$${K3S_TOKEN}" \
        --data-dir /var/lib/rancher/k3s 2>&1 | tee -a /var/log/k3s-init.log
      
      RESTORE_EXIT_CODE=$$?
      
      if [ $${RESTORE_EXIT_CODE} -eq 0 ]; then
        log "✅ 集群状态已成功从快照恢复！"
        pkill -f "k3s server" 2>/dev/null || true
        sleep 2
      else
        log "⚠️ 警告：快照恢复失败（退出码: $${RESTORE_EXIT_CODE}），将尝试作为全新集群启动..."
        rm -rf /var/lib/rancher/k3s/server/db/partial 2>/dev/null || true
      fi
    else
      log "⚠️ 警告：K3s 二进制下载失败，将作为全新集群启动..."
    fi
  else
    if [ -d "/var/lib/rancher/k3s/server/db" ]; then
      log "🔄 检测到本地已有集群数据，将继续使用现有集群"
    elif [ -z "$${LATEST_SNAPSHOT}" ]; then
      log "🆕 未检测到历史快照，将作为全新集群启动"
    else
      log "⚠️ 警告：检测到快照但文件不存在或不可读，将作为全新集群启动"
    fi
  fi
else
  log "⚠️ 警告：NAS 挂载点不可用，跳过快照恢复检查"
fi

# 极速模式安装 K3s（本地运行 + NAS 备份）
log "使用极速模式安装 K3s（本地 SSD 运行，NAS 存储备份）..."

# 验证 NAS 挂载点可用（用于快照备份）
if [ ! -d "$${NAS_MOUNT_POINT}" ] || ! mountpoint -q "$${NAS_MOUNT_POINT}" 2>/dev/null; then
  log "❌ 错误: NAS 挂载点 $${NAS_MOUNT_POINT} 不可用，无法存储快照"
  exit 1
fi

# 确保备份目录存在
if [ ! -d "$${NAS_MOUNT_POINT}/k3s-backup" ]; then
  mkdir -p "$${NAS_MOUNT_POINT}/k3s-backup"
  log "✅ 创建 K3s 备份目录: $${NAS_MOUNT_POINT}/k3s-backup"
fi

# 验证备份目录可写
if ! touch "$${NAS_MOUNT_POINT}/k3s-backup/.write-test" 2>/dev/null; then
  log "❌ 错误: K3s 备份目录不可写: $${NAS_MOUNT_POINT}/k3s-backup"
  exit 1
fi
rm -f "$${NAS_MOUNT_POINT}/k3s-backup/.write-test"
log "✅ NAS 备份目录可用且可写"

# ==============================================================================
# K3s 使用默认镜像源（不再配置 ACR 重定向）
# ==============================================================================
# 注意：K3s 将使用默认的 rancher.io 镜像源，不进行任何镜像重定向配置

export INSTALL_K3S_SKIP_DOWNLOAD=false
export INSTALL_K3S_MIRROR=cn
export INSTALL_K3S_VERSION=v1.31.4+k3s1
export K3S_TOKEN="$${K3S_TOKEN}"

# ============================================================================
# v2 多 stack：加载 STACK_ID / K3S_ROLE / NODE_LABELS（由 user-data.sh 写入）
# - K3S_ROLE = server | agent；未设默认 server（向后兼容）
# - NODE_LABELS = "k1=v1,k2=v2"；按逗号拆为多个 --node-label
# - agent 需 join master（启动期单节点暂不展开 · agent 模式待 P-step_04/05 实现）
# ============================================================================
STACK_ID=""
K3S_ROLE="server"
NODE_LABELS=""
if [ -f /etc/diting/stack.env ]; then
  # shellcheck disable=SC1091
  . /etc/diting/stack.env
fi
[ -z "$${K3S_ROLE}" ] && K3S_ROLE="server"
log "[stack] STACK_ID=$${STACK_ID:-<empty>} K3S_ROLE=$${K3S_ROLE} NODE_LABELS=$${NODE_LABELS:-<empty>}"

# 组装 --node-label 参数
NODE_LABEL_ARGS=""
if [ -n "$${NODE_LABELS}" ]; then
  for label in $$(echo "$${NODE_LABELS}" | tr ',' ' '); do
    NODE_LABEL_ARGS="$${NODE_LABEL_ARGS} --node-label $${label}"
  done
fi

# 启动期 P 轨：仅 server 模式落地（agent join master 待 P-step_04/05 实现）
if [ "$${K3S_ROLE}" = "agent" ]; then
  log "⚠️ K3s agent 模式暂未实现 join 逻辑（P-step_04/05 完成后引入）· 当前 stack=$${STACK_ID} 退出"
  exit 0
fi

log "执行 K3s 安装脚本（server 模式，本地 IO 运行，NAS 存储备份，30 分钟快照策略，镜像 GC 调优，stack=$${STACK_ID:-base}）..."
K3S_INSTALL_EXIT_CODE=0

# 注意：不再使用 --system-default-registry，K3s 将使用默认镜像源

# shellcheck disable=SC2086
curl -sfL https://rancher-mirror.rancher.cn/k3s/k3s-install.sh | sh -s - server \
  --token "$${K3S_TOKEN}" \
  --tls-san "$${PUBLIC_IP}" \
  --tls-san "$$(hostname)" \
  --disable traefik \
  --disable servicelb \
  --write-kubeconfig-mode 644 \
  --etcd-snapshot-dir "$${NAS_MOUNT_POINT}/k3s-backup" \
  --etcd-snapshot-schedule-cron "*/30 * * * *" \
  --etcd-snapshot-retention 48 \
  --kubelet-arg="image-gc-high-threshold=70" \
  --kubelet-arg="image-gc-low-threshold=50" \
  $${NODE_LABEL_ARGS} || K3S_INSTALL_EXIT_CODE=$$?

if [ $${K3S_INSTALL_EXIT_CODE} -ne 0 ]; then
  log "❌ 错误: K3s 安装脚本执行失败 (退出码: $${K3S_INSTALL_EXIT_CODE})"
  exit 1
fi

log "✅ K3s 安装脚本执行完成，等待服务启动..."

# 等待 K3s 服务启动（最多等待 3 分钟）
log "等待 K3s 服务启动..."
SERVICE_STARTED=false
for i in {1..36}; do
  if systemctl is-active --quiet k3s 2>/dev/null; then
    if curl -k -s https://127.0.0.1:6443/healthz >/dev/null 2>&1; then
      log "✅ K3s 服务已启动且 API 服务器就绪（等待了 $((i * 5)) 秒）"
      SERVICE_STARTED=true
      break
    else
      log "K3s 服务已启动，但 API 服务器尚未就绪，继续等待..."
    fi
  fi
  if [ $((i % 6)) -eq 0 ]; then
    log "等待 K3s 服务启动... ($${i}/36) - 已等待 $((i * 5)) 秒"
    systemctl status k3s --no-pager -l | tail -5 || true
    if systemctl is-failed --quiet k3s 2>/dev/null; then
      log "⚠️ 警告: K3s 服务失败，尝试重新启动..."
      systemctl reset-failed k3s 2>/dev/null || true
      systemctl start k3s 2>/dev/null || true
    fi
  fi
  sleep 5
done

if [ "$${SERVICE_STARTED}" != "true" ]; then
  log "❌ 错误: K3s 服务在 3 分钟内未能启动或 API 服务器未就绪"
  log "诊断信息:"
  systemctl status k3s --no-pager -l | head -30 || true
  journalctl -u k3s --no-pager -n 50 || true
  ps aux | grep k3s || true
  curl -k -v https://127.0.0.1:6443/healthz 2>&1 | head -10 || true
  exit 1
fi

# 额外等待一段时间，确保 kubeconfig 文件生成
log "K3s 服务已就绪，等待配置文件生成..."
sleep 10

mkdir -p /etc/rancher/k3s
chmod 755 /etc/rancher/k3s

# 等待 K3s 配置文件生成（最多等待 3 分钟）
log "等待 K3s 配置文件生成..."
CONFIG_GENERATED=false
KUBECONFIG_PATH=""
for i in {1..36}; do
  if [ -f /etc/rancher/k3s/k3s.yaml ]; then
    KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"
    log "✅ K3s 配置文件已生成: $${KUBECONFIG_PATH}（等待了 $((i * 5)) 秒）"
    CONFIG_GENERATED=true
    break
  fi
  if [ $((i % 6)) -eq 0 ]; then
    log "等待配置文件生成... ($${i}/36) - 已等待 $((i * 5)) 秒"
    ls -la /etc/rancher/ 2>/dev/null || true
    ls -la /etc/rancher/k3s/ 2>/dev/null || true
  fi
  sleep 5
done

if [ "$${CONFIG_GENERATED}" != "true" ]; then
  log "❌ 错误: K3s 配置文件在 3 分钟内未能生成"
  log "诊断信息:"
  ls -la /etc/rancher/ 2>/dev/null || true
  systemctl status k3s --no-pager -l | head -30 || true
  journalctl -u k3s --no-pager -n 50 | tail -30 || true
  ls -la /var/lib/rancher/k3s/ 2>/dev/null || true
  exit 1
fi

# 增加一步：启动后立即执行一次快照测试，确保 NAS 写入正常
log "测试 NAS 快照写入..."
sleep 15
if /usr/local/bin/k3s etcd-snapshot save --dir "$${NAS_MOUNT_POINT}/k3s-backup" 2>/dev/null; then
  log "✅ 初始集群状态已成功备份到 NAS！"
else
  log "⚠️ 警告：初始备份失败，请检查 NAS 权限（不影响集群运行）"
fi

# 激活 Spot 实例"临终备份"服务
log "激活 Spot 实例防抢占备份服务..."
# 如果服务文件不存在，则创建它（兼容从 OSS 下载的脚本场景）
if [ ! -f /etc/systemd/system/k3s-backup-shutdown.service ]; then
  log "创建 k3s-backup-shutdown.service 文件..."
  cat > /etc/systemd/system/k3s-backup-shutdown.service <<'EOFSERVICE'
[Unit]
Description=Backup K3s Etcd Snapshot on Shutdown
Requires=k3s.service
After=k3s.service
Before=halt.target poweroff.target reboot.target shutdown.target

[Service]
Type=oneshot
RemainAfterExit=true
ExecStop=/bin/bash -c '/usr/local/bin/k3s etcd-snapshot save --dir /mnt/titan-data/k3s-backup --name snapshot-shutdown-$$(date +%%Y%%m%%d-%%H%%M%%S) && echo "[$$(date +%%Y-%%m-%%d\ %%H:%%M:%%S)] ✅ 关机备份成功" || echo "[$$(date +%%Y-%%m-%%d\ %%H:%%M:%%S)] ⚠️ 关机备份失败"'
StandardOutput=journal
StandardError=journal
TimeoutStopSec=300

[Install]
WantedBy=multi-user.target
EOFSERVICE
  log "✅ k3s-backup-shutdown.service 文件已创建"
fi
systemctl daemon-reload
systemctl enable k3s-backup-shutdown.service || log "⚠️ 警告: 启用 k3s-backup-shutdown.service 失败（可能服务文件不存在）"
log "✅ 防抢占备份服务已就绪！当实例被抢占或重启时，将自动执行最后一次备份"

# 确保 kubectl 可以找到 kubeconfig（复制到 ~/.kube/config）
log "配置 kubectl 使用正确的 kubeconfig..."
mkdir -p ~/.kube

if [ -z "$${KUBECONFIG_PATH}" ]; then
  KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"
fi

if [ -f "$${KUBECONFIG_PATH}" ]; then
  cp "$${KUBECONFIG_PATH}" ~/.kube/config
  chmod 600 ~/.kube/config
  export KUBECONFIG=~/.kube/config
  
  KUBECONFIG_EXPORT='export KUBECONFIG=~/.kube/config'
  
  if ! grep -q "KUBECONFIG" ~/.bashrc 2>/dev/null; then
    echo "$${KUBECONFIG_EXPORT}" >> ~/.bashrc
  fi
  
  if ! grep -q "KUBECONFIG" ~/.profile 2>/dev/null; then
    echo "$${KUBECONFIG_EXPORT}" >> ~/.profile
  fi
  
  mkdir -p /etc/profile.d
  echo "$${KUBECONFIG_EXPORT}" > /etc/profile.d/k3s.sh
  chmod 644 /etc/profile.d/k3s.sh
  
  export KUBECONFIG=~/.kube/config
  
  log "✅ Kubeconfig 已配置到 ~/.kube/config（来源: $${KUBECONFIG_PATH}）"
  log "✅ KUBECONFIG 已添加到 ~/.bashrc, ~/.profile, /etc/profile.d/k3s.sh"
else
  log "❌ 错误: kubeconfig 文件不存在 ($${KUBECONFIG_PATH})，尝试其他方法..."
  
  log "等待 K3s API 服务器完全就绪..."
  for i in {1..12}; do
    if curl -k -s https://127.0.0.1:6443/healthz >/dev/null 2>&1; then
      log "✅ K3s API 服务器已就绪（等待了 $((i * 5)) 秒）"
      break
    fi
    sleep 5
  done
  
  if command -v k3s >/dev/null 2>&1; then
    log "尝试使用 k3s kubectl config view 生成 kubeconfig..."
    if k3s kubectl config view --raw > ~/.kube/config 2>/dev/null; then
      chmod 600 ~/.kube/config
      export KUBECONFIG=~/.kube/config
      echo "export KUBECONFIG=~/.kube/config" >> ~/.bashrc
      echo "export KUBECONFIG=~/.kube/config" >> ~/.profile
      echo "export KUBECONFIG=~/.kube/config" > /etc/profile.d/k3s.sh
      chmod 644 /etc/profile.d/k3s.sh
      log "✅ 从 k3s kubectl 生成 kubeconfig"
    else
      log "⚠️ 警告: 无法从 k3s kubectl 生成 kubeconfig，继续尝试..."
      if [ -f /etc/rancher/k3s/k3s.yaml ]; then
        cp /etc/rancher/k3s/k3s.yaml ~/.kube/config 2>/dev/null || true
        chmod 600 ~/.kube/config 2>/dev/null || true
        if [ -f ~/.kube/config ]; then
          export KUBECONFIG=~/.kube/config
          echo "export KUBECONFIG=~/.kube/config" >> ~/.bashrc
          echo "export KUBECONFIG=~/.kube/config" >> ~/.profile
          echo "export KUBECONFIG=~/.kube/config" > /etc/profile.d/k3s.sh
          chmod 644 /etc/profile.d/k3s.sh
          log "✅ 通过直接复制找到 kubeconfig"
        else
          log "❌ 错误: 所有方法都失败，无法配置 kubectl"
          exit 1
        fi
      else
        log "❌ 错误: 所有方法都失败，无法配置 kubectl"
        exit 1
      fi
    fi
  else
    log "❌ 错误: k3s 命令不存在，无法生成 kubeconfig"
    exit 1
  fi
fi

# 验证 kubectl 连接（最多重试 6 次）
log "验证 kubectl 连接..."
KUBECTL_WORKING=false
for i in {1..6}; do
  if kubectl cluster-info --request-timeout=10s >/dev/null 2>&1; then
    log "✅ kubectl 连接 K3s 成功（重试 $${i} 次）"
    KUBECTL_WORKING=true
    break
  fi
  if [ $${i} -lt 6 ]; then
    log "kubectl 连接失败，重试 $${i}/6..."
    sleep 10
  fi
done

if [ "$${KUBECTL_WORKING}" != "true" ]; then
  log "⚠️ 警告: kubectl 连接 K3s 失败，但继续执行"
  kubectl cluster-info 2>&1 || true
  systemctl status k3s --no-pager -l | head -10 || true
fi

# 保存 kubeconfig 到 NAS（可选）
if [ -n "$${KUBECONFIG_PATH}" ] && [ -f "$${KUBECONFIG_PATH}" ]; then
  cp "$${KUBECONFIG_PATH}" "$${NAS_MOUNT_POINT}/k3s-backup/k3s.yaml.$$(date +%Y%m%d_%H%M%S)"
  log "✅ Kubeconfig 已备份到 NAS（来源: $${KUBECONFIG_PATH}）"
elif [ -f ~/.kube/config ]; then
  cp ~/.kube/config "$${NAS_MOUNT_POINT}/k3s-backup/k3s.yaml.$$(date +%Y%m%d_%H%M%S)"
  log "✅ Kubeconfig 已备份到 NAS（来源: ~/.kube/config）"
else
  log "⚠️ 警告: 无法备份 kubeconfig 到 NAS，文件不存在"
fi

# ==============================================================================
# 第五优先级：OSS 挂载（K3s 数据持久化 - 延迟到 K3s 启动后）
# ==============================================================================
log "[优先级 5] 配置 OSS 挂载（K3s PVC 数据持久化）..."

goto_oss_mount_end=false

# 安装 ossfs（阿里云 OSS 文件系统）
if ! command -v ossfs >/dev/null 2>&1; then
  log "安装 ossfs..."
  
  # 先安装 libfuse2（ossfs 需要 libfuse.so.2，但 Ubuntu 22.04 默认只有 libfuse3）
  log "安装 libfuse2（ossfs 依赖）..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y -qq libfuse2 >/dev/null 2>&1 || {
    log "⚠️  libfuse2 安装失败，尝试继续安装 ossfs..."
  }
  
  OSSFS_VERSION="1.91.1"
  OSS_INTERNAL_URL=""
  if [ -n "$${OSS_REGION}" ]; then
    OSS_INTERNAL_URL="https://oss-$${OSS_REGION}-internal.aliyuncs.com/ossfs/ossfs_$${OSSFS_VERSION}_ubuntu22.04_amd64.deb"
  fi
  
  OSSFS_DOWNLOADED=false
  if [ -n "$${OSS_INTERNAL_URL}" ]; then
    log "尝试从内网 OSS 地址下载 ossfs: $${OSS_INTERNAL_URL}"
    wget -q --timeout=10 "$${OSS_INTERNAL_URL}" -O /tmp/ossfs.deb && OSSFS_DOWNLOADED=true || {
      log "⚠️  内网 OSS 地址下载失败，尝试公网地址..."
    }
  fi
  
  if [ "$${OSSFS_DOWNLOADED}" != "true" ]; then
    wget -q --timeout=30 "https://gosspublic.alicdn.com/ossfs/ossfs_$${OSSFS_VERSION}_ubuntu22.04_amd64.deb" -O /tmp/ossfs.deb && OSSFS_DOWNLOADED=true || {
      log "⚠️  阿里云公网地址下载失败，尝试从 GitHub 下载..."
      wget -q --timeout=30 "https://github.com/aliyun/ossfs/releases/download/v$${OSSFS_VERSION}/ossfs_$${OSSFS_VERSION}_ubuntu22.04_amd64.deb" -O /tmp/ossfs.deb && OSSFS_DOWNLOADED=true || {
        log "⚠️  警告: ossfs 安装失败，PVC 数据将使用本地存储（不影响 K3s 运行）"
        log "   可以稍后手动安装 ossfs 并挂载 OSS"
        rm -f /tmp/ossfs.deb
        goto_oss_mount_end=true
      }
    }
  fi
  if [ "$${goto_oss_mount_end}" != "true" ]; then
    dpkg -i /tmp/ossfs.deb || {
      log "⚠️  dpkg 安装失败，尝试修复依赖..."
      apt-get update -qq && apt-get install -y -f && dpkg -i /tmp/ossfs.deb || {
        log "⚠️  警告: ossfs 安装失败，PVC 数据将使用本地存储（不影响 K3s 运行）"
        rm -f /tmp/ossfs.deb
        goto_oss_mount_end=true
      }
    }
    rm -f /tmp/ossfs.deb
    log "✅ ossfs 安装完成"
  fi
else
  log "✅ ossfs 已安装"
fi

if [ "$${goto_oss_mount_end}" != "true" ]; then
  OSS_ACCESS_KEY_ID="$${ALICLOUD_ACCESS_KEY:-}"
  OSS_ACCESS_KEY_SECRET="$${ALICLOUD_SECRET_KEY:-}"
  
  if [ -z "$${OSS_ACCESS_KEY_ID}" ] || [ -z "$${OSS_ACCESS_KEY_SECRET}" ]; then
    log "⚠️  警告: OSS 访问凭证未设置，尝试使用实例 RAM Role"
    OSS_ACCESS_KEY_ID=""
    OSS_ACCESS_KEY_SECRET=""
  fi
  
  mkdir -p "$${K3S_STORAGE_PATH}"
  
  if [ -n "$${OSS_ACCESS_KEY_ID}" ] && [ -n "$${OSS_ACCESS_KEY_SECRET}" ]; then
    echo "$${OSS_BUCKET_NAME}:$${OSS_ACCESS_KEY_ID}:$${OSS_ACCESS_KEY_SECRET}" > /etc/passwd-ossfs
    chmod 640 /etc/passwd-ossfs
    log "✅ OSS 访问凭证已配置"
  fi
  
  log "挂载 OSS Bucket: $${OSS_BUCKET_NAME} -> $${K3S_STORAGE_PATH}"
  MOUNT_OPTIONS="url=oss-$${OSS_REGION}.aliyuncs.com,allow_other,use_cache=/tmp/ossfs-cache"
  
  if [ -f "/etc/passwd-ossfs" ]; then
    if ossfs "$${OSS_BUCKET_NAME}" "$${K3S_STORAGE_PATH}" -o "$${MOUNT_OPTIONS}" 2>&1; then
      log "✅ OSS 挂载成功（AccessKey）"
    else
      log "⚠️  警告: OSS 挂载失败（AccessKey），PVC 数据将使用本地存储"
      log "   可以稍后手动挂载 OSS"
    fi
  else
    if ossfs "$${OSS_BUCKET_NAME}" "$${K3S_STORAGE_PATH}" -o "$${MOUNT_OPTIONS},iam_role" 2>&1; then
      log "✅ OSS 挂载成功（RAM Role）"
    else
      log "⚠️  警告: OSS 挂载失败（RAM Role），PVC 数据将使用本地存储"
      log "   请检查 ECS 实例是否配置了 RAM Role 和相应的 RAM Policy"
    fi
  fi
  
  if mountpoint -q "$${K3S_STORAGE_PATH}" 2>/dev/null; then
    if ! grep -q "$${OSS_BUCKET_NAME}" /etc/fstab 2>/dev/null; then
      if [ -f "/etc/passwd-ossfs" ]; then
        echo "ossfs#$${OSS_BUCKET_NAME} $${K3S_STORAGE_PATH} fuse _netdev,url=oss-$${OSS_REGION}.aliyuncs.com,allow_other,use_cache=/tmp/ossfs-cache 0 0" >> /etc/fstab
      else
        echo "ossfs#$${OSS_BUCKET_NAME} $${K3S_STORAGE_PATH} fuse _netdev,url=oss-$${OSS_REGION}.aliyuncs.com,allow_other,use_cache=/tmp/ossfs-cache,iam_role 0 0" >> /etc/fstab
      fi
      log "✅ OSS 挂载点已添加到 /etc/fstab"
    fi
    
    if mountpoint -q "$${K3S_STORAGE_PATH}" 2>/dev/null; then
      log "✅ OSS 挂载验证成功: $${K3S_STORAGE_PATH}"
      if touch "$${K3S_STORAGE_PATH}/.write-test" 2>/dev/null; then
        rm -f "$${K3S_STORAGE_PATH}/.write-test"
        log "✅ OSS 写入测试通过"
      else
        log "⚠️  警告: OSS 写入测试失败，但继续执行"
      fi
    fi
  else
    log "⚠️  警告: OSS 挂载验证失败，PVC 数据将使用本地存储"
    log "   不影响 K3s 运行，可以稍后手动挂载 OSS"
  fi
fi

# ==============================================================================
# 健康检查：验证 K3s 集群状态并写入成功标记
# ==============================================================================
log "[健康检查] 验证 K3s 集群状态..."

K3S_READY=false
for i in {1..30}; do
  if kubectl get nodes >/dev/null 2>&1; then
    K3S_READY=true
    log "✅ K3s 集群已就绪（等待了 $${i} 次检查）"
    break
  fi
  sleep 2
done

if [ "$${K3S_READY}" = "true" ]; then
  NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
  log "✅ K3s 集群健康检查通过，节点数量: $${NODE_COUNT}"
  
  mkdir -p /var/lib/titan
  echo "$$(date +'%Y-%m-%d %H:%M:%S')" > /var/lib/titan/SUCCESS
  echo "NODE_COUNT=$${NODE_COUNT}" >> /var/lib/titan/SUCCESS
  log "✅ 成功标记文件已创建: /var/lib/titan/SUCCESS"
else
  log "⚠️  警告: K3s 集群健康检查失败，但初始化流程已完成"
  log "   可以稍后手动检查: kubectl get nodes"
fi

log "=== K3s 集群初始化完成 ==="
