# Deploy Engine - make deploy <project> <env> / make down <project> <env>
# 在仓库根目录执行；PROJECT 与 ENV 从目标参数解析，如 make deploy lighthouse dev

KNOWN_TARGETS = deploy down kubeconfig nodes help build fix-nas-state \
                up-stack down-stack down-platform-base down-all platform-status
ARGS = $(filter-out $(KNOWN_TARGETS),$(MAKECMDGOALS))
PROJECT = $(firstword $(ARGS))
ENV = $(if $(word 2,$(ARGS)),$(word 2,$(ARGS)),dev)

# v2 多 stack：stack_id 通过 STACK=<id> 环境变量传入（推荐）
# 上层 diting-infra Makefile 用 STACK=base/train/infer 调用 up-stack/down-stack
STACK ?=

BIN = bin/deploy-engine
# 代码变更后 make deploy/down/kubeconfig 会先自动构建；也可单独 make build
GO_SOURCES = $(shell find cmd pkg -name '*.go' 2>/dev/null)
# CONFIG_ROOT 可选：从应用仓执行时设为应用仓的 config 目录，配置（tfvars、YAML、deploy）均由此读取
CONFIG_ROOT ?=
# FULL_DESTROY 可选：make down 时 FULL_DESTROY=1 则完整销毁（VPC/NAS/OSS/ECS），否则仅销毁 ECS；完整销毁后下次 deploy 会按 tfvars 的 region 重新创建
FULL_DESTROY ?=
# 部署配置支持 .yaml/.yml/.json；仅使用正式配置文件（勿直接使用 .example），首次使用请从 config/examples/ 复制示例到 config/ 并填写
# 查找顺序：1) <project>-<env>.yaml  2) <project>.yaml  3) deploy.yaml
CONFIG_FILE = $(if $(CONFIG_ROOT),$(if $(wildcard $(CONFIG_ROOT)/$(PROJECT)-$(ENV).yaml),$(CONFIG_ROOT)/$(PROJECT)-$(ENV).yaml,$(if $(wildcard $(CONFIG_ROOT)/$(PROJECT)-$(ENV).yml),$(CONFIG_ROOT)/$(PROJECT)-$(ENV).yml,$(if $(wildcard $(CONFIG_ROOT)/$(PROJECT).yaml),$(CONFIG_ROOT)/$(PROJECT).yaml,$(if $(wildcard $(CONFIG_ROOT)/$(PROJECT).yml),$(CONFIG_ROOT)/$(PROJECT).yml,$(if $(wildcard $(CONFIG_ROOT)/$(PROJECT).json),$(CONFIG_ROOT)/$(PROJECT).json,$(if $(wildcard $(CONFIG_ROOT)/deploy.yaml),$(CONFIG_ROOT)/deploy.yaml,$(if $(wildcard $(CONFIG_ROOT)/deploy.yml),$(CONFIG_ROOT)/deploy.yml,$(CONFIG_ROOT)/deploy.yaml))))))),$(if $(wildcard config/$(PROJECT)-$(ENV).yaml),config/$(PROJECT)-$(ENV).yaml,$(if $(wildcard config/$(PROJECT)-$(ENV).yml),config/$(PROJECT)-$(ENV).yml,$(if $(wildcard config/$(PROJECT).yaml),config/$(PROJECT).yaml,$(if $(wildcard config/$(PROJECT).yml),config/$(PROJECT).yml,$(if $(wildcard config/$(PROJECT).json),config/$(PROJECT).json,$(if $(wildcard config/deploy.yaml),config/deploy.yaml,$(if $(wildcard config/deploy.yml),config/deploy.yml,config/deploy.yaml))))))))
STATE_FILE = .deploy/state-$(PROJECT)-$(ENV).json
KUBECONFIG_PATH = $(HOME)/.kube/config-$(PROJECT)-$(ENV)
CONFIG_ROOT_FLAG = $(if $(CONFIG_ROOT),-config-root=$(CONFIG_ROOT),)

# 占位目标：防止 make 将 project/env 名当作目标文件（任意 project 名均可）
lighthouse dev prod:
	@:
%:
	@:

.PHONY: deploy down kubeconfig nodes help build lighthouse dev prod fix-nas-state \
        up-stack down-stack down-platform-base down-all platform-status

# 源码更新时自动重建；无依赖或 BIN 不存在时也会构建
build: $(BIN)
$(BIN): $(GO_SOURCES)
	@mkdir -p bin
	go build -o $(BIN) ./cmd/deploy-engine

help:
	@echo "Deploy Engine - 用法"
	@echo ""
	@echo "  make deploy <project> <env>   - 部署（如 make deploy lighthouse dev）"
	@echo "  make down <project> <env>      - 销毁（默认仅销毁 ECS；FULL_DESTROY=1 时完整销毁 VPC/NAS/OSS/ECS）"
	@echo "  make kubeconfig <project> <env> - 输出 kubeconfig 到 stdout"
	@echo "  make nodes <project> <env>      - 使用对应 kubeconfig 执行 kubectl get nodes（无需手动 export KUBECONFIG）"
	@echo ""
	@echo "v2 多 stack（P 轨）— 按需起停某个 stack（base/train/infer）"
	@echo "  make up-stack <project> <env> STACK=<id>      - 起单 stack（仅 -target 该 stack ECS+EIP）"
	@echo "  make down-stack <project> <env> STACK=<id>    - 销单 stack（保留永驻 VPC/SG/NAS/盘/OSS）"
	@echo "  make down-platform-base <project> <env>       - 销所有 ECS+EIP（保留永驻 10 项）"
	@echo "  make down-all <project> <env> FULL_DESTROY=1  - 完全销毁含永驻（需二次确认 DESTROY-DATA）"
	@echo "  make platform-status <project> <env>          - 当前 stacks 状态总览"
	@echo ""
	@echo "kubeconfig 文件路径: ~/.kube/config-<project>-<env>"
	@echo "示例: make deploy myapp dev  => 生成 ~/.kube/config-myapp-dev；验收集群: make nodes myapp dev"
	@echo ""
	@echo "首次使用: 从 config/examples/ 复制示例到 config/ 并填写（见《验证此模块逻辑》；示例以 config/examples/ 实际文件为准）"
	@echo "从应用仓执行: CONFIG_ROOT=$$(pwd)/config make -C deploy-engine deploy <project> <env>"
	@echo "验收集群: make nodes <project> <env> 或 CONFIG_ROOT=$$(pwd)/config make -C deploy-engine nodes <project> <env>"
	@echo "  make build - 仅构建 bin/deploy-engine（deploy/down/kubeconfig 会按需自动构建）"
	@echo "  make fix-nas-state <project> <env> - NAS AlreadyAttached 恢复（见 docs/VERIFICATION.md 1.9）"

fix-nas-state:
	@if [ -z "$(PROJECT)" ] || [ -z "$(ENV)" ]; then \
		echo "用法: make fix-nas-state <project> <env>"; \
		echo "示例: make fix-nas-state myapp dev"; exit 1; \
	fi
	@chmod +x scripts/fix-nas-state.sh 2>/dev/null || true
	@CONFIG_ROOT="$${CONFIG_ROOT:-$(CURDIR)/config}" ./scripts/fix-nas-state.sh "$(PROJECT)" "$(ENV)" "$$CONFIG_ROOT"

deploy: $(BIN)
	@if [ -z "$(PROJECT)" ]; then \
		$(MAKE) -s help; echo "错误: 请指定 project，如 make deploy lighthouse dev"; exit 1; \
	fi
	@command -v terraform >/dev/null 2>&1 || { echo "错误: 未找到 terraform，请安装 Terraform（>= 1.0）并加入 PATH，见 README 前置条件"; exit 1; }
	@mkdir -p .deploy
	@./$(BIN) -cmd=deploy -config=$(CONFIG_FILE) -state=$(STATE_FILE) -env=$(ENV) -project=$(PROJECT) -root=$$(pwd) $(CONFIG_ROOT_FLAG)

down: $(BIN)
	@if [ -z "$(PROJECT)" ]; then \
		$(MAKE) -s help; echo "错误: 请指定 project，如 make down lighthouse dev"; exit 1; \
	fi
	@command -v terraform >/dev/null 2>&1 || { echo "错误: 未找到 terraform，请安装 Terraform（>= 1.0）并加入 PATH，见 README 前置条件"; exit 1; }
	@FULL_DESTROY="$(FULL_DESTROY)" ./$(BIN) -cmd=destroy -config=$(CONFIG_FILE) -state=$(STATE_FILE) -env=$(ENV) -project=$(PROJECT) -root=$$(pwd) $(CONFIG_ROOT_FLAG)

kubeconfig: $(BIN)
	@if [ -z "$(PROJECT)" ]; then \
		$(MAKE) -s help; echo "错误: 请指定 project，如 make kubeconfig lighthouse dev"; exit 1; \
	fi
	@./$(BIN) -cmd=kubeconfig -state=$(STATE_FILE) -env=$(ENV) -project=$(PROJECT) -root=$$(pwd) $(CONFIG_ROOT_FLAG)

# 使用对应 kubeconfig 执行 kubectl get nodes，无需手动 export KUBECONFIG
nodes:
	@if [ -z "$(PROJECT)" ]; then \
		$(MAKE) -s help; echo "错误: 请指定 project，如 make nodes myapp dev"; exit 1; \
	fi
	@if [ ! -f "$(KUBECONFIG_PATH)" ]; then \
		echo "错误: kubeconfig 不存在 ($(KUBECONFIG_PATH))，请先执行 make deploy $(PROJECT) $(ENV) 或 make kubeconfig $(PROJECT) $(ENV)"; exit 1; \
	fi
	@KUBECONFIG="$(KUBECONFIG_PATH)" kubectl get nodes

# ============================================================================
# v2 多 stack：up-stack / down-stack / down-platform-base / down-all / platform-status
# ============================================================================
# 设计要点（详见 03_/共享平台基础/.../02_deploy-engine扩展规约.md §3）：
#   - up-stack STACK=<id>           : terraform apply -target='module.ecs.alicloud_instance.stack["<id>"]'+ EIP/disk_attach
#   - down-stack STACK=<id>         : terraform destroy -target='module.ecs.alicloud_instance.stack["<id>"]'+ EIP
#   - down-platform-base            : terraform destroy 所有 module.ecs.alicloud_instance.stack（无 key）
#   - down-all FULL_DESTROY=1       : 先 terraform state rm 永驻 prevent_destroy 资源 · 再二次确认 · destroy 全部
# 永驻资源（VPC/SG/NAS/独立盘/OSS）均有 lifecycle { prevent_destroy = true }，tier-1/tier-2 不会动到。

TF_DIR := deploy/terraform/alicloud
# TF_VAR_FILE 总是绝对路径（CONFIG_ROOT 为空时用 CURDIR 前缀），避免 cd $(TF_DIR) 后相对路径失效
TF_VAR_FILE := $(if $(CONFIG_ROOT),$(CONFIG_ROOT)/terraform-$(PROJECT)-$(ENV).tfvars,$(CURDIR)/config/terraform-$(PROJECT)-$(ENV).tfvars)

_require_stack:
	@if [ -z "$(STACK)" ]; then echo "错误: 请通过 STACK=<id> 指定 stack（base/train/infer）"; exit 1; fi
	@if [ -z "$(PROJECT)" ]; then echo "错误: 请指定 project，如 make up-stack diting prod STACK=base"; exit 1; fi
	@if [ ! -f "$(TF_VAR_FILE)" ]; then echo "错误: tfvars 不存在 ($(TF_VAR_FILE))"; exit 1; fi

# tier-1：起单 stack（base / train / infer 任一）
# 兼容旧使用：STACK=base 时等价 make deploy；但 deploy 走 Go orchestrator 完成 kubeconfig 拉取，建议优先用 deploy
up-stack: _require_stack
	@echo "[up-stack] STACK=$(STACK) PROJECT=$(PROJECT) ENV=$(ENV)"
	@cd $(TF_DIR) && terraform init \
	  -backend-config="prefix=$(PROJECT)/$(ENV)" \
	  -reconfigure \
	  -input=false \
	  -no-color > /dev/null
	@cd $(TF_DIR) && terraform apply -auto-approve \
	  -var-file="$(TF_VAR_FILE)" \
	  -var="env_id=$(ENV)" \
	  -var="project=$(PROJECT)" \
	  -target='module.ecs.alicloud_eip_address.stack["$(STACK)"]' \
	  -target='module.ecs.alicloud_instance.stack["$(STACK)"]' \
	  -target='module.ecs.alicloud_eip_association.stack["$(STACK)"]' \
	  -target='module.ecs.alicloud_disk_attachment.stack["$(STACK)"]'

# tier-1：销单 stack（仅 ECS+EIP+attach；永驻资源 lifecycle prevent_destroy 保护）
down-stack: _require_stack
	@echo "[down-stack] STACK=$(STACK) PROJECT=$(PROJECT) ENV=$(ENV)"
	@cd $(TF_DIR) && terraform init \
	  -backend-config="prefix=$(PROJECT)/$(ENV)" \
	  -reconfigure \
	  -input=false \
	  -no-color > /dev/null
	@cd $(TF_DIR) && terraform destroy -auto-approve \
	  -var-file="$(TF_VAR_FILE)" \
	  -var="env_id=$(ENV)" \
	  -var="project=$(PROJECT)" \
	  -target='module.ecs.alicloud_disk_attachment.stack["$(STACK)"]' \
	  -target='module.ecs.alicloud_eip_association.stack["$(STACK)"]' \
	  -target='module.ecs.alicloud_instance.stack["$(STACK)"]' \
	  -target='module.ecs.alicloud_eip_address.stack["$(STACK)"]'

# tier-2：销所有 ECS+EIP（保留永驻 10 项：VPC/SG/路由/网关/NAS/独立盘/OSS/ACR）
down-platform-base:
	@if [ -z "$(PROJECT)" ]; then echo "错误: 请指定 project，如 make down-platform-base diting prod"; exit 1; fi
	@if [ ! -f "$(TF_VAR_FILE)" ]; then echo "错误: tfvars 不存在 ($(TF_VAR_FILE))"; exit 1; fi
	@echo "[down-platform-base] 销所有 stack ECS+EIP · 保留永驻 10 项"
	@cd $(TF_DIR) && terraform init \
	  -backend-config="prefix=$(PROJECT)/$(ENV)" \
	  -reconfigure \
	  -input=false \
	  -no-color > /dev/null
	@cd $(TF_DIR) && terraform destroy -auto-approve \
	  -var-file="$(TF_VAR_FILE)" \
	  -var="env_id=$(ENV)" \
	  -var="project=$(PROJECT)" \
	  -target='module.ecs.alicloud_disk_attachment.stack' \
	  -target='module.ecs.alicloud_eip_association.stack' \
	  -target='module.ecs.alicloud_instance.stack' \
	  -target='module.ecs.alicloud_eip_address.stack'

# tier-3：完全销毁（含 VPC/SG/NAS/独立盘/OSS）· 需 FULL_DESTROY=1 + 二次确认 DESTROY-DATA
down-all:
	@if [ "$(FULL_DESTROY)" != "1" ]; then \
		echo "错误: tier-3 完全销毁需 FULL_DESTROY=1"; \
		echo "用法: make down-all $(PROJECT) $(ENV) FULL_DESTROY=1"; exit 1; \
	fi
	@if [ -z "$(PROJECT)" ]; then echo "错误: 请指定 project"; exit 1; fi
	@if [ ! -f "$(TF_VAR_FILE)" ]; then echo "错误: tfvars 不存在 ($(TF_VAR_FILE))"; exit 1; fi
	@echo "⚠️ ⚠️ ⚠️  即将完全销毁 PROJECT=$(PROJECT) ENV=$(ENV) 的全部资源："
	@echo "        包括 VPC + 安全组 + NAS + 独立数据盘 + OSS Bucket（数据不可恢复）"
	@echo "        若复用现状资源（vpc_existing_id 非空），仅会销毁 Terraform-managed 部分"
	@read -p "请输入 DESTROY-DATA 二次确认（其他输入将取消）: " CONFIRM; \
	if [ "$$CONFIRM" != "DESTROY-DATA" ]; then echo "已取消"; exit 1; fi
	@echo "[down-all] 移除 prevent_destroy 保护后销毁..."
	@cd $(TF_DIR) && for r in \
	  'module.vpc.alicloud_vpc.main[0]' \
	  'module.vpc.alicloud_vswitch.main[0]' \
	  'module.security.alicloud_security_group.main[0]' \
	  'module.nas.alicloud_nas_file_system.main[0]' \
	  'module.oss.alicloud_oss_bucket.main[0]' \
	  'alicloud_disk.prod_data[0]'; do \
	    terraform state rm "$$r" 2>/dev/null || true; \
	  done
	@cd $(TF_DIR) && terraform init \
	  -backend-config="prefix=$(PROJECT)/$(ENV)" \
	  -reconfigure \
	  -input=false \
	  -no-color > /dev/null
	@cd $(TF_DIR) && terraform destroy -auto-approve \
	  -var-file="$(TF_VAR_FILE)" \
	  -var="env_id=$(ENV)" \
	  -var="project=$(PROJECT)"

# 状态总览：terraform output + helm list（如果 KUBECONFIG 可用）
platform-status:
	@if [ -z "$(PROJECT)" ]; then echo "用法: make platform-status <project> <env>"; exit 1; fi
	@echo "=== Terraform stacks_info ==="
	@cd $(TF_DIR) && terraform init \
	  -backend-config="prefix=$(PROJECT)/$(ENV)" \
	  -reconfigure \
	  -input=false \
	  -no-color > /dev/null 2>&1 || true
	@cd $(TF_DIR) && terraform output -json stacks_info 2>/dev/null || echo "（无 state 或未部署）"
	@echo ""
	@echo "=== KUBECONFIG 与 nodes ==="
	@if [ -f "$(KUBECONFIG_PATH)" ]; then \
		KUBECONFIG="$(KUBECONFIG_PATH)" kubectl get nodes -L stack.diting/node 2>/dev/null || echo "（kubectl 不可达）"; \
		echo ""; echo "=== Helm releases ==="; \
		KUBECONFIG="$(KUBECONFIG_PATH)" helm list -A 2>/dev/null || echo "（helm 不可用或无 release）"; \
	else \
		echo "（kubeconfig 不存在: $(KUBECONFIG_PATH)）"; \
	fi
