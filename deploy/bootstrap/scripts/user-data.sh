#cloud-config
packages:
  - nfs-common
  - curl
  - wget
  - fuse

write_files:
  - path: /usr/local/bin/k3s-init-log
    permissions: "0755"
    content: |
      #!/bin/bash
      log() {
        echo "[$$(date +'%Y-%m-%d %H:%M:%S')] $$*" | tee -a /var/log/k3s-init.log
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
    LOG_FILE="/var/log/k3s-init.log"
    mkdir -p "$(dirname "$LOG_FILE")"

    log() {
      echo "[$$(date +'%Y-%m-%d %H:%M:%S')] $$*" | tee -a "$LOG_FILE"
    }

    err_exit() {
      log "❌ 错误: $$1"
      log "退出码 1"
      exit 1
    }

    log "=== K3s 集群初始化开始 ==="

    # 检查 K3s 是否已部署，已部署则跳过脚本下载与初始化
    if systemctl is-active --quiet k3s 2>/dev/null || [ -f /etc/rancher/k3s/k3s.yaml ]; then
      log "K3s 已部署，跳过初始化脚本下载与执行"
      log "=== K3s 集群初始化完成（跳过）==="
      exit 0
    fi

    OSS_BUCKET_NAME="${oss_bucket_name}"
    OSS_REGION="${oss_region}"
    SCRIPT_PATH="scripts/k3s-init.sh"
    OSS_URL="https://$${OSS_BUCKET_NAME}.oss-$${OSS_REGION}.aliyuncs.com/$${SCRIPT_PATH}"

    log "K3s 未部署，从 OSS 下载初始化脚本: oss://$${OSS_BUCKET_NAME}/$${SCRIPT_PATH}"

    # 安装 ossutil（如果未安装）
    if ! command -v ossutil >/dev/null 2>&1; then
      log "安装 ossutil..."
      wget -q http://gosspublic.alicdn.com/ossutil/1.7.14/ossutil64 -O /usr/local/bin/ossutil 2>/dev/null || \
        curl -sL http://gosspublic.alicdn.com/ossutil/1.7.14/ossutil64 -o /usr/local/bin/ossutil 2>/dev/null || \
        err_exit "ossutil 下载失败"
      chmod +x /usr/local/bin/ossutil
      log "✅ ossutil 安装完成"
    fi

    # 优先 HTTP 下载
    log "尝试 HTTP 下载: $${OSS_URL}"
    DOWNLOAD_OK=false
    if curl -f -s "$${OSS_URL}" -o /tmp/k3s-init.sh 2>/dev/null || wget -q "$${OSS_URL}" -O /tmp/k3s-init.sh 2>/dev/null; then
      DOWNLOAD_OK=true
      log "✅ 脚本下载成功（HTTP）"
    fi

    # HTTP 失败则尝试 ossutil（RAM Role）
    if [ "$${DOWNLOAD_OK}" != "true" ]; then
      log "HTTP 下载失败，尝试 ossutil（RAM Role）..."
      RAM_ROLE_NAME=$(curl -s --max-time 5 http://100.100.100.200/latest/meta-data/ram/security-credentials/ 2>/dev/null | head -1 || echo "")
      if [ -n "$${RAM_ROLE_NAME}" ]; then
        if ossutil cp "oss://$${OSS_BUCKET_NAME}/$${SCRIPT_PATH}" /tmp/k3s-init.sh --endpoint "oss-$${OSS_REGION}.aliyuncs.com" 2>/dev/null; then
          DOWNLOAD_OK=true
          log "✅ 脚本下载成功（ossutil）"
        fi
      fi
    fi

    if [ "$${DOWNLOAD_OK}" != "true" ]; then
      err_exit "OSS 脚本下载失败。请检查：1) 存储桶 ${oss_bucket_name} 中是否存在 $${SCRIPT_PATH}；2) make deploy 是否已执行并成功上传脚本；3) 若桶为私有，ECS 是否已绑定 ram_role_name 且 Role 有 OSS 读权限。上传/下载失败时请直接报错退出。"
    fi

    if [ ! -f /tmp/k3s-init.sh ] || [ ! -s /tmp/k3s-init.sh ]; then
      err_exit "下载的脚本文件为空或不存在"
    fi

    chmod +x /tmp/k3s-init.sh
    log "执行初始化脚本..."
    /tmp/k3s-init.sh || err_exit "初始化脚本执行失败，请查看 /var/log/k3s-init.log"

    log "=== K3s 集群初始化完成 ==="
