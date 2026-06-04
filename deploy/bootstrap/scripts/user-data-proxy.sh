#cloud-config
# Anthropic 出口 HTTP 代理（3proxy）· 新加坡等非香港地域 ECS
# 模板变量：proxy_user, proxy_password, proxy_port, public_ip, stack_id
# Ubuntu 22.04 无 apt 3proxy 包，从源码编译安装。

packages:
  - curl
  - git
  - build-essential
  - libssl-dev

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
      apt-get install -y -qq git build-essential libssl-dev
      rm -rf /tmp/3proxy-build
      git clone --depth 1 https://github.com/3proxy/3proxy.git /tmp/3proxy-build
      make -C /tmp/3proxy-build -f Makefile.Linux
      install -m 755 /tmp/3proxy-build/bin/3proxy /usr/local/bin/3proxy
      mkdir -p /etc/3proxy
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
      cat > /etc/systemd/system/3proxy.service <<'UNIT'
      [Unit]
      Description=3proxy Anthropic egress
      After=network.target
      [Service]
      ExecStart=/usr/local/bin/3proxy /etc/3proxy/3proxy.cfg
      Restart=always
      [Install]
      WantedBy=multi-user.target
      UNIT
      systemctl daemon-reload
      systemctl enable 3proxy
      systemctl restart 3proxy
      sleep 2
      if ss -lntp | grep -q ":${proxy_port} "; then
        log "✅ 3proxy listening on :${proxy_port} public_ip=${public_ip}"
      else
        log "❌ 3proxy 未监听 ${proxy_port}"
        journalctl -u 3proxy --no-pager | tail -20 | tee -a "$LOG"
        exit 1
      fi

runcmd:
  - /usr/local/bin/setup-anthropic-proxy.sh
