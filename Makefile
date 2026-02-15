# Deploy Engine - make deploy <project> <env> / make down <project> <env>
# 在仓库根目录执行；PROJECT 与 ENV 从目标参数解析，如 make deploy lighthouse dev

KNOWN_TARGETS = deploy down kubeconfig help
ARGS = $(filter-out $(KNOWN_TARGETS),$(MAKECMDGOALS))
PROJECT = $(firstword $(ARGS))
ENV = $(if $(word 2,$(ARGS)),$(word 2,$(ARGS)),dev)

BIN = bin/deploy-engine
CONFIG_FILE = $(if $(wildcard deploy/config/$(PROJECT).json),deploy/config/$(PROJECT).json,deploy.json.example)
STATE_FILE = .deploy/state-$(PROJECT)-$(ENV).json
KUBECONFIG_PATH = $(HOME)/.kube/kubeconfig-$(PROJECT)-$(ENV)

# 占位目标：防止 make 将 project/env 名当作目标文件
lighthouse dev prod:
	@:

.PHONY: deploy down kubeconfig help lighthouse dev prod

help:
	@echo "Deploy Engine - 用法"
	@echo ""
	@echo "  make deploy <project> <env>   - 部署（如 make deploy lighthouse dev）"
	@echo "  make down <project> <env>      - 销毁"
	@echo "  make kubeconfig <project> <env> - 输出 kubeconfig 到 stdout"
	@echo ""
	@echo "kubeconfig 文件路径: ~/.kube/kubeconfig-<project>-<env>"
	@echo "示例: make deploy lighthouse dev  => 生成 ~/.kube/kubeconfig-lighthouse-dev"
	@echo ""
	@echo "首次使用: 在 config/environments/<env>/ 下准备 terraform.tfvars（可从 example 复制）"

deploy:
	@if [ -z "$(PROJECT)" ]; then \
		$(MAKE) -s help; echo "错误: 请指定 project，如 make deploy lighthouse dev"; exit 1; \
	fi
	@if [ ! -f "$(BIN)" ]; then go build -o $(BIN) ./cmd/deploy-engine; fi
	@mkdir -p .deploy
	@./$(BIN) -cmd=deploy -config=$(CONFIG_FILE) -state=$(STATE_FILE) -env=$(ENV) -project=$(PROJECT) -root=$$(pwd)

down:
	@if [ -z "$(PROJECT)" ]; then \
		$(MAKE) -s help; echo "错误: 请指定 project，如 make down lighthouse dev"; exit 1; \
	fi
	@if [ ! -f "$(BIN)" ]; then go build -o $(BIN) ./cmd/deploy-engine; fi
	@./$(BIN) -cmd=destroy -state=$(STATE_FILE) -env=$(ENV) -project=$(PROJECT) -root=$$(pwd)

kubeconfig:
	@if [ -z "$(PROJECT)" ]; then \
		$(MAKE) -s help; echo "错误: 请指定 project，如 make kubeconfig lighthouse dev"; exit 1; \
	fi
	@if [ ! -f "$(BIN)" ]; then go build -o $(BIN) ./cmd/deploy-engine; fi
	@./$(BIN) -cmd=kubeconfig -state=$(STATE_FILE) -env=$(ENV) -project=$(PROJECT) -root=$$(pwd)
