# ECS 模块输出（v2 · 多 stack for_each）
# 旧 instance_id / public_ip / eip_id 输出指向 "base" stack（若存在），保持向后兼容根级 outputs.tf。

locals {
  # 优先 base · 否则取第一个 active stack（按 key 字典序）
  primary_stack_key = contains(keys(alicloud_instance.stack), "base") ? "base" : (
    length(keys(alicloud_instance.stack)) > 0
    ? sort(keys(alicloud_instance.stack))[0]
    : ""
  )
}

output "instance_id" {
  description = "primary stack（优先 base）的 ECS 实例 ID"
  value       = local.primary_stack_key != "" ? alicloud_instance.stack[local.primary_stack_key].id : null
}

output "public_ip" {
  description = "primary stack 的公网 IP（无 EIP 时为 'Instance Released' 兼容旧契约）"
  value = local.primary_stack_key != "" && contains(keys(alicloud_eip_address.stack), local.primary_stack_key) ? (
    alicloud_eip_address.stack[local.primary_stack_key].ip_address
  ) : "Instance Released"
}

output "eip_id" {
  description = "primary stack 的 EIP ID"
  value = local.primary_stack_key != "" && contains(keys(alicloud_eip_address.stack), local.primary_stack_key) ? (
    alicloud_eip_address.stack[local.primary_stack_key].id
  ) : null
}

# v2 新增：多 stack 信息（root outputs / make platform-status 消费）
output "stacks_info" {
  description = "所有 active stack 的 { stack_id => { instance_id, public_ip, image_id } } 映射"
  value = {
    for k, inst in alicloud_instance.stack : k => {
      instance_id = inst.id
      public_ip   = contains(keys(alicloud_eip_address.stack), k) ? alicloud_eip_address.stack[k].ip_address : ""
      image_id    = inst.image_id
      stack_id    = k
    }
  }
}
