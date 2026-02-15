#cloud-config
packages:
  - nfs-common
  - curl
  - wget
  - fuse

write_files:
  - path: /usr/local/bin/titan-log
    permissions: "0755"
    content: |
      #!/bin/bash
      log() {
        echo "[$$(date +'%Y-%m-%d %H:%M:%S')] $$*" | tee -a /var/log/titan-init.log
      }
      log "$$@"

  - path: /etc/systemd/system/k3s-backup-shutdown.service
    permissions: "0644"
    content: |
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

runcmd:
  - systemctl start ssh || systemctl start sshd || true
  - systemctl enable ssh || systemctl enable sshd || true
  - |
      set -euo pipefail
    LOG_FILE="/var/log/titan-init.log"
    mkdir -p "$(dirname "$LOG_FILE")"
    
      log() {
      echo "[$$(date +'%Y-%m-%d %H:%M:%S')] $$*" | tee -a "$LOG_FILE"
      }

    log "=== Titan Infra Hub 初始化开始（精简版）==="
    
    OSS_BUCKET_NAME="${oss_bucket_name}"
    OSS_REGION="${oss_region}"
    SCRIPT_PATH="scripts/titan-init.sh"
    
    log "从 OSS 下载初始化脚本: oss://${oss_bucket_name}/$SCRIPT_PATH"
    
    # 安装 ossutil（如果未安装）
    if ! command -v ossutil >/dev/null 2>&1; then
      log "安装 ossutil..."
      wget -q http://gosspublic.alicdn.com/ossutil/1.7.14/ossutil64 -O /usr/local/bin/ossutil || {
        log "⚠️  wget 失败，尝试 curl..."
        curl -sL http://gosspublic.alicdn.com/ossutil/1.7.14/ossutil64 -o /usr/local/bin/ossutil || {
          log "❌ ossutil 下载失败"
        exit 1
        }
      }
      chmod +x /usr/local/bin/ossutil
      log "✅ ossutil 安装完成"
      fi

    # 优先使用 HTTP 下载（如果文件是公网可读的）
    OSS_URL="https://${oss_bucket_name}.oss-${oss_region}.aliyuncs.com/$SCRIPT_PATH"
    log "尝试 HTTP 下载脚本: $${OSS_URL}"
    
    if curl -f -s "$${OSS_URL}" -o /tmp/titan-init.sh || wget -q "$${OSS_URL}" -O /tmp/titan-init.sh; then
      log "✅ 脚本下载成功（HTTP）"
    else
      log "⚠️  HTTP 下载失败，尝试使用 ossutil（RAM Role）..."
          
      # 获取 RAM Role 名称
      log "获取 RAM Role 名称..."
      RAM_ROLE_NAME=$(curl -s --max-time 5 http://100.100.100.200/latest/meta-data/ram/security-credentials/ 2>/dev/null | head -1 || echo "")
      
      if [ -z "$${RAM_ROLE_NAME}" ]; then
        log "❌ 无法获取 RAM Role 名称，且 HTTP 下载失败"
        log "   请检查："
        log "   1. OSS Bucket 是否配置为公开读取"
        log "   2. 或为 ECS 实例配置 RAM Role"
        exit 1
      fi

      log "RAM Role 名称: $${RAM_ROLE_NAME}"

      # 使用 ossutil 下载脚本（通过 RAM Role）
      # 注意：ossutil 会自动使用 ECS 实例的 RAM Role（如果配置了）
      log "使用 ossutil 下载脚本（RAM Role）..."
      ossutil cp "oss://${oss_bucket_name}/$SCRIPT_PATH" /tmp/titan-init.sh \
        --endpoint "oss-${oss_region}.aliyuncs.com" 2>/dev/null || {
        log "❌ 脚本下载失败（ossutil），尝试 HTTP 下载..."
        # 如果 ossutil 失败，尝试 HTTP 下载
        OSS_URL="https://${oss_bucket_name}.oss-${oss_region}.aliyuncs.com/$SCRIPT_PATH"
        curl -f -s "$${OSS_URL}" -o /tmp/titan-init.sh || wget -q "$${OSS_URL}" -O /tmp/titan-init.sh || {
          log "❌ 所有下载方式均失败"
          log "   请检查："
          log "   1. ECS 实例是否配置了 RAM Role"
          log "   2. RAM Role 是否有 OSS 读取权限"
          log "   3. OSS Bucket 是否存在: ${oss_bucket_name}"
        exit 1
        }
      }
    fi

    if [ ! -f /tmp/titan-init.sh ]; then
      log "❌ 脚本文件不存在"
        exit 1
      fi

    chmod +x /tmp/titan-init.sh
    
    log "执行初始化脚本..."
    /tmp/titan-init.sh || {
      log "❌ 初始化脚本执行失败"
                exit 1
    }
    
    log "=== Titan Infra Hub 初始化完成 ==="
