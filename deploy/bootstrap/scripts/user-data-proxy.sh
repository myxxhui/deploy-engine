#cloud-config
# Anthropic 出口 HTTP 代理（3proxy）· 新加坡等非香港地域 ECS
# 模板变量：proxy_user, proxy_password, proxy_port, public_ip, stack_id

packages:
  - curl

write_files:
  - path: /usr/local/bin/setup-anthropic-proxy.sh
    permissions: "0755"
    content: |
      #!/bin/bash
      set -euo pipefail
      LOG=/var/log/anthropic-proxy-init.log
      log() { echo "[$(date -Iseconds)] $*" | tee -a "$LOG"; }
      PROXY_USER="${proxy_user}"
      PROXY_PASS="${proxy_password}"
      PROXY_PORT="${proxy_port}"
      log "=== Anthropic proxy bootstrap stack=${stack_id} port=$PROXY_PORT ==="
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq 3proxy
      cat > /etc/3proxy/3proxy.cfg <<EOF
      daemon
      maxconn 200
      nserver 8.8.8.8
      nserver 223.5.5.5
      nscache 65536
      timeouts 1 5 30 60 180 1800 15 60
      auth strong
      users ${proxy_user}:CL:${proxy_password}
      proxy -p${proxy_port}
      EOF
      systemctl enable 3proxy
      systemctl restart 3proxy
      sleep 2
      if ss -lntp | grep -q ":${proxy_port} "; then
        log "✅ 3proxy listening on :${proxy_port} public_ip=${public_ip}"
      else
        log "❌ 3proxy 未监听 ${proxy_port}"
        exit 1
      fi

runcmd:
  - /usr/local/bin/setup-anthropic-proxy.sh
