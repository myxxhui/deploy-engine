#cloud-config
# Cloud-Init 配置：精简版 - 从 OSS 下载并执行完整初始化脚本
# 注意：完整的初始化脚本存储在 OSS 中，此文件只负责下载和执行

# 安装基础包
packages:
  - nfs-common
  - curl
  - wget
  - fuse

# 执行初始化脚本（从 OSS 下载）
runcmd:
  - |
    set -euo pipefail
    LOG_FILE="/var/log/titan-init.log"
    mkdir -p "$(dirname "$LOG_FILE")"
    
    log() {
      echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
    }
    
    log "=== Titan Infra Hub 初始化开始（精简版）==="
    
    # 配置变量（由 Terraform 传入）
    OSS_BUCKET_NAME="${oss_bucket_name}"
    OSS_REGION="${oss_region}"
    SCRIPT_PATH="scripts/titan-init.sh"
    
    # 尝试从 OSS 下载初始化脚本
    log "从 OSS 下载初始化脚本: oss://${oss_bucket_name}/$SCRIPT_PATH"
    
    # 使用阿里云 CLI 或直接 HTTP 下载（如果 Bucket 是公开的）
    # 优先尝试使用 ossutil（如果已安装）
    if command -v ossutil >/dev/null 2>&1; then
      log "使用 ossutil 下载脚本..."
      ossutil cp "oss://${oss_bucket_name}/$SCRIPT_PATH" /tmp/titan-init.sh || {
        log "⚠️  ossutil 下载失败，尝试 HTTP 下载..."
        # 如果 ossutil 失败，尝试 HTTP 下载（需要 Bucket 是公开的或使用签名 URL）
        curl -f "https://${oss_bucket_name}.oss-${oss_region}.aliyuncs.com/$SCRIPT_PATH" -o /tmp/titan-init.sh || {
          log "❌ 脚本下载失败，尝试从 metadata 获取临时凭证..."
          # 如果使用 RAM Role，尝试获取临时凭证
          TOKEN=$(curl -X PUT "http://100.100.100.200/latest/api/token" -H "X-aliyun-ecs-metadata-token-ttl-seconds:180" 2>/dev/null || echo "")
          if [ -n "$TOKEN" ]; then
            # 使用临时凭证下载（需要配置 RAM Policy 允许 OSS 访问）
            curl -H "X-aliyun-ecs-metadata-token:$TOKEN" \
              "https://${oss_bucket_name}.oss-${oss_region}.aliyuncs.com/$SCRIPT_PATH" \
              -o /tmp/titan-init.sh || {
              log "❌ 所有下载方式均失败"
              exit 1
            }
          else
            log "❌ 无法获取临时凭证"
            exit 1
          fi
        }
      }
    else
      # 如果没有 ossutil，尝试 HTTP 下载
      log "ossutil 未安装，尝试 HTTP 下载..."
      curl -f "https://${oss_bucket_name}.oss-${oss_region}.aliyuncs.com/$SCRIPT_PATH" -o /tmp/titan-init.sh || {
        log "❌ HTTP 下载失败"
        exit 1
      }
    fi
    
    # 验证脚本文件
    if [ ! -f /tmp/titan-init.sh ]; then
      log "❌ 脚本文件不存在"
      exit 1
    fi
    
    # 设置执行权限
    chmod +x /tmp/titan-init.sh
    
    # 执行脚本
    log "执行初始化脚本..."
    /tmp/titan-init.sh || {
      log "❌ 初始化脚本执行失败"
      exit 1
    }
    
    log "=== Titan Infra Hub 初始化完成 ==="
