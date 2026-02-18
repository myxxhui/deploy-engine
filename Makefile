# Deploy Engine - make deploy <project> <env> / make down <project> <env>
# 在仓库根目录执行；PROJECT 与 ENV 从目标参数解析，如 make deploy lighthouse dev

KNOWN_TARGETS = deploy down kubeconfig help
ARGS = $(filter-out $(KNOWN_TARGETS),$(MAKECMDGOALS))
PROJECT = $(firstword $(ARGS))
ENV = $(if $(word 2,$(ARGS)),$(word 2,$(ARGS)),dev)

BIN = bin/deploy-engine
# 代码变更后 make deploy/down/kubeconfig 会先自动构建；也可单独 make build
GO_SOURCES = $(shell find cmd pkg -name '*.go' 2>/dev/null)
# CONFIG_ROOT 可选：从应用仓执行时设为应用仓的 config 目录，配置（tfvars、YAML、deploy）均由此读取
CONFIG_ROOT ?=
# 部署配置支持 .yaml/.yml/.json；仅使用正式配置文件（勿直接使用 .example），首次使用请从 config/deploy.yaml.example 复制为 config/deploy.yaml
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

.PHONY: deploy down kubeconfig help build lighthouse dev prod

# 源码更新时自动重建；无依赖或 BIN 不存在时也会构建
build: $(BIN)
$(BIN): $(GO_SOURCES)
	@mkdir -p bin
	go build -o $(BIN) ./cmd/deploy-engine

help:
	@echo "Deploy Engine - 用法"
	@echo ""
	@echo "  make deploy <project> <env>   - 部署（如 make deploy lighthouse dev）"
	@echo "  make down <project> <env>      - 销毁"
	@echo "  make kubeconfig <project> <env> - 输出 kubeconfig 到 stdout"
	@echo ""
	@echo "kubeconfig 文件路径: ~/.kube/config-<project>-<env>"
	@echo "示例: make deploy lighthouse dev  => 生成 ~/.kube/config-lighthouse-dev"
	@echo ""
	@echo "首次使用: 请从 config/deploy.yaml.example 复制为 config/deploy.yaml；在 ConfigRoot 下准备 terraform-<project>-<env>.tfvars 与 <project>-<env>.yaml（见《配置说明》）"
	@echo "从应用仓执行: CONFIG_ROOT=$$(pwd)/config make -C deploy-engine deploy <project> <env>"
	@echo "使用集群: export KUBECONFIG=$$(HOME)/.kube/config-<project>-<env> && kubectl get nodes"
	@echo "  make build - 仅构建 bin/deploy-engine（deploy/down/kubeconfig 会按需自动构建）"

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
	@./$(BIN) -cmd=destroy -config=$(CONFIG_FILE) -state=$(STATE_FILE) -env=$(ENV) -project=$(PROJECT) -root=$$(pwd) $(CONFIG_ROOT_FLAG)

kubeconfig: $(BIN)
	@if [ -z "$(PROJECT)" ]; then \
		$(MAKE) -s help; echo "错误: 请指定 project，如 make kubeconfig lighthouse dev"; exit 1; \
	fi
	@./$(BIN) -cmd=kubeconfig -state=$(STATE_FILE) -env=$(ENV) -project=$(PROJECT) -root=$$(pwd) $(CONFIG_ROOT_FLAG)
