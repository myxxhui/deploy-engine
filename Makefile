# Deploy Engine - make deploy <project> <env> / make down <project> <env>
# 在仓库根目录执行；PROJECT 与 ENV 从目标参数解析，如 make deploy lighthouse dev

KNOWN_TARGETS = deploy down kubeconfig nodes help build fix-nas-state
ARGS = $(filter-out $(KNOWN_TARGETS),$(MAKECMDGOALS))
PROJECT = $(firstword $(ARGS))
ENV = $(if $(word 2,$(ARGS)),$(word 2,$(ARGS)),dev)

BIN = bin/deploy-engine
# 代码变更后 make deploy/down/kubeconfig 会先自动构建；也可单独 make build
GO_SOURCES = $(shell find cmd pkg -name '*.go' 2>/dev/null)
# CONFIG_ROOT 可选：从应用仓执行时设为应用仓的 config 目录，配置（tfvars、YAML、deploy）均由此读取
CONFIG_ROOT ?=
# FULL_DESTROY 可选：make down 时 FULL_DESTROY=1 则完整销毁（VPC/NAS/OSS/ECS），否则仅销毁 ECS；完整销毁后下次 deploy 会按 tfvars 的 region 重新创建
FULL_DESTROY ?=
# 部署配置支持 .yaml/.yml/.json；仅使用正式配置文件（勿直接使用 .example），首次使用请从 config/examples/ 复制示例到 config/ 并填写
# 无 CONFIG_ROOT 时本仓默认：先 config/<project>.yaml|yml|json，再 config/deploy.yaml|yml|json
CONFIG_FILE = $(if $(CONFIG_ROOT),$(if $(wildcard $(CONFIG_ROOT)/$(PROJECT).yaml),$(CONFIG_ROOT)/$(PROJECT).yaml,$(if $(wildcard $(CONFIG_ROOT)/$(PROJECT).yml),$(CONFIG_ROOT)/$(PROJECT).yml,$(if $(wildcard $(CONFIG_ROOT)/$(PROJECT).json),$(CONFIG_ROOT)/$(PROJECT).json,$(if $(wildcard $(CONFIG_ROOT)/deploy.yaml),$(CONFIG_ROOT)/deploy.yaml,$(if $(wildcard $(CONFIG_ROOT)/deploy.yml),$(CONFIG_ROOT)/deploy.yml,$(CONFIG_ROOT)/deploy.yaml))))),$(if $(wildcard config/$(PROJECT).yaml),config/$(PROJECT).yaml,$(if $(wildcard config/$(PROJECT).yml),config/$(PROJECT).yml,$(if $(wildcard config/$(PROJECT).json),config/$(PROJECT).json,$(if $(wildcard config/deploy.yaml),config/deploy.yaml,$(if $(wildcard config/deploy.yml),config/deploy.yml,config/deploy.yaml))))))
STATE_FILE = .deploy/state-$(PROJECT)-$(ENV).json
KUBECONFIG_PATH = $(HOME)/.kube/config-$(PROJECT)-$(ENV)
CONFIG_ROOT_FLAG = $(if $(CONFIG_ROOT),-config-root=$(CONFIG_ROOT),)

# 占位目标：防止 make 将 project/env 名当作目标文件（任意 project 名均可）
lighthouse dev prod:
	@:
%:
	@:

.PHONY: deploy down kubeconfig nodes help build lighthouse dev prod fix-nas-state

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
