# ==============================================================================
# Security 模块：安全组和规则
# ==============================================================================

data "http" "current_ip" {
  url = "https://api.ipify.org"
  request_headers = {
    Accept = "text/plain"
  }
}

locals {
  current_ip = chomp(data.http.current_ip.response_body)
  # 若指定了 ssh_allowed_cidr 则用其，否则用 apply 时检测的出口 IP/32
  ssh_cidr   = var.ssh_allowed_cidr != "" ? var.ssh_allowed_cidr : "${local.current_ip}/32"
}

# 创建新的安全组（当 use_existing_security_group=false 时）
resource "alicloud_security_group" "main" {
  count               = var.use_existing_security_group ? 0 : 1
  security_group_name = "${var.project_name}-sg-${var.env_id}"
  description         = "Security group for ${var.project_name} ${var.env_id} environment"
  vpc_id              = var.vpc_id
}

# 本地值：统一安全组 ID 引用
locals {
  security_group_id = var.use_existing_security_group ? var.existing_security_group_id : alicloud_security_group.main[0].id
}

# 安全组规则（仅当创建新安全组时创建规则，复用时不创建）
# 注意：VPC 中的安全组规则必须使用 nic_type = "intranet"
# 即使通过 EIP 公网访问，流量也会通过 EIP 转发到内网，源 IP 保持为访问者的公网 IP
# SSH 规则：允许从当前 IP 访问（通过 EIP 转发，nic_type 必须是 "intranet"）
resource "alicloud_security_group_rule" "ssh" {
  count             = var.use_existing_security_group ? 0 : 1
  type              = "ingress"
  ip_protocol       = "tcp"
  nic_type          = "intranet" # VPC 中的安全组必须使用 intranet
  policy            = "accept"
  port_range        = "22/22"
  priority          = 1
  security_group_id = local.security_group_id
  cidr_ip           = local.ssh_cidr
  description       = "SSH access (via EIP); source from ssh_allowed_cidr or apply-time IP"
}

# K8s API 规则：允许从当前 IP 访问（通过 EIP 转发，nic_type 必须是 "intranet"）
resource "alicloud_security_group_rule" "k8s_api" {
  count             = var.use_existing_security_group ? 0 : 1
  type              = "ingress"
  ip_protocol       = "tcp"
  nic_type          = "intranet" # VPC 中的安全组必须使用 intranet
  policy            = "accept"
  port_range        = "6443/6443"
  priority          = 1
  security_group_id = local.security_group_id
  cidr_ip           = local.ssh_cidr
  description       = "K8s API (via EIP); source from ssh_allowed_cidr or apply-time IP"
}

resource "alicloud_security_group_rule" "vpc_internal" {
  count             = var.use_existing_security_group ? 0 : 1
  type              = "ingress"
  ip_protocol       = "all"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "-1/-1"
  priority          = 10
  security_group_id = local.security_group_id
  cidr_ip           = var.vpc_cidr
  description       = "Allow all traffic from VPC internal"
}

resource "alicloud_security_group_rule" "egress_all" {
  count             = var.use_existing_security_group ? 0 : 1
  type              = "egress"
  ip_protocol       = "all"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "-1/-1"
  priority          = 1
  security_group_id = local.security_group_id
  cidr_ip           = "0.0.0.0/0"
  description       = "Allow all outbound traffic"
}
