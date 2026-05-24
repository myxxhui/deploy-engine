# ==============================================================================
# Security 模块：安全组和规则
# ==============================================================================
# 复用已有安全组（use_existing_security_group=true）时，不创建 SSH/6443 规则，由控制台统一管理，避免 Terraform 与控制台冲突或 NicType 导致 EIP 访问不通。

# 创建新的安全组（当 use_existing_security_group=false 时）
# v2: prevent_destroy 保护永驻资源（与 VPC/NAS 同级）；仅 FULL_DESTROY 时由 Makefile state rm 后销
resource "alicloud_security_group" "main" {
  count               = var.use_existing_security_group ? 0 : 1
  security_group_name = "${var.project_name}-sg-${var.env_id}"
  description         = "Security group for ${var.project_name} ${var.env_id} environment"
  vpc_id              = var.vpc_id
  lifecycle {
    prevent_destroy = true
  }
}

# 本地值：统一安全组 ID 引用
locals {
  security_group_id = var.use_existing_security_group ? var.existing_security_group_id : alicloud_security_group.main[0].id
}

# 仅在新创建安全组时添加 SSH/6443 规则；复用已有安全组时不创建，由控制台全放通或自行配置
data "http" "current_ip" {
  count = var.use_existing_security_group ? 0 : 1
  url   = "https://api.ipify.org"
  request_headers = {
    Accept = "text/plain"
  }
}

locals {
  current_ip = var.use_existing_security_group ? "" : chomp(data.http.current_ip[0].response_body)
  ssh_cidr   = var.ssh_allowed_cidr != "" ? var.ssh_allowed_cidr : (var.use_existing_security_group ? "" : "${local.current_ip}/32")
}

resource "alicloud_security_group_rule" "ssh" {
  count             = var.use_existing_security_group ? 0 : 1
  type              = "ingress"
  ip_protocol       = "tcp"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "22/22"
  priority          = 1
  security_group_id = local.security_group_id
  cidr_ip           = local.ssh_cidr
  description       = "SSH access (via EIP); source from ssh_allowed_cidr or apply-time IP"
}

resource "alicloud_security_group_rule" "k8s_api" {
  count             = var.use_existing_security_group ? 0 : 1
  type              = "ingress"
  ip_protocol       = "tcp"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "6443/6443"
  priority          = 1
  security_group_id = local.security_group_id
  cidr_ip           = local.ssh_cidr
  description       = "K8s API (via EIP); source from ssh_allowed_cidr or apply-time IP"
}

# 复用安全组时也创建，避免 Terraform 销毁后 SG 无出站/VPC 规则导致 ECS 无法上网、cloud-init 无法完成、SSH 永不就绪
resource "alicloud_security_group_rule" "vpc_internal" {
  count             = 1
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
  count             = 1
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
