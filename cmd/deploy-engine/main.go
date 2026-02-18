// deploy-engine：基础设施即插即用型部署编排 CLI（自包含 Terraform）。
// 契约：仅从 ConfigRoot 读取配置，不向模块根（Root）写入任何配置；临时 tfvars 写系统临时目录。
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/titan-platform/deploy-engine/pkg/config"
	"github.com/titan-platform/deploy-engine/pkg/orchestrator"
	"github.com/titan-platform/deploy-engine/pkg/provider"
	"github.com/titan-platform/deploy-engine/pkg/provider/aliyun"
	"github.com/titan-platform/deploy-engine/pkg/state"
	"gopkg.in/yaml.v3"
)

func main() {
	cmd := flag.String("cmd", "", "deploy | destroy | kubeconfig")
	configPath := flag.String("config", "", "deploy.json 路径；其所在目录作为 ConfigRoot（配置根），未设置 -config-root 时生效")
	configRoot := flag.String("config-root", "", "配置根目录，覆盖由 -config 推导的目录；tfvars、环境 YAML 均由此解析")
	statePath := flag.String("state", ".deploy/state.json", "state file path")
	providerName := flag.String("provider", "aliyun", "provider name")
	root := flag.String("root", os.Getenv("DEPLOY_ENGINE_ROOT"), "deploy-engine 模块根目录（含 deploy/），仅用于 Terraform 与脚本")
	envID := flag.String("env", "dev", "环境 ID")
	project := flag.String("project", "", "项目名，用于 state 与 kubeconfig 命名（如 kubeconfig-<project>-<env>）")
	flag.Parse()

	configRootDir := *configRoot
	if configRootDir == "" && *configPath != "" {
		if abs, err := filepath.Abs(*configPath); err == nil {
			configRootDir = filepath.Dir(abs)
		}
	}
	if configRootDir != "" {
		if abs, err := filepath.Abs(configRootDir); err == nil {
			configRootDir = abs
		}
	}

	switch *cmd {
	case "deploy":
		if *configPath == "" {
			fmt.Fprintln(os.Stderr, "usage: deploy-engine -cmd=deploy -config=deploy.json [-root=...] [-env=dev] [-project=名称]")
			os.Exit(1)
		}
		cfg, err := loadConfig(*configPath)
		if err != nil {
			fmt.Fprintf(os.Stderr, "config: %v\n", err)
			os.Exit(1)
		}
		cfg.Merge()
		if cfg.ProviderName == "" {
			cfg.ProviderName = *providerName
		}
		var p provider.Provider
		switch cfg.ProviderName {
		case "aliyun":
			p = &aliyun.Driver{Root: *root, ConfigRoot: configRootDir, EnvID: *envID, Project: *project}
		default:
			fmt.Fprintf(os.Stderr, "unknown provider: %s\n", cfg.ProviderName)
			os.Exit(1)
		}
		eng := &orchestrator.Engine{Provider: p, StateDir: filepath.Dir(*statePath)}
		s, err := eng.Deploy(context.Background(), cfg)
		if err != nil {
			fmt.Fprintf(os.Stderr, "deploy: %v\n", err)
			os.Exit(1)
		}
		s.EnvID = *envID
		s.Project = *project
		if err := saveState(*statePath, s); err != nil {
			fmt.Fprintf(os.Stderr, "save state: %v\n", err)
			os.Exit(1)
		}
		fmt.Println("deploy ok, state:", *statePath)
	case "destroy":
		s, err := loadState(*statePath)
		if err != nil {
			fmt.Fprintf(os.Stderr, "state: %v\n", err)
			os.Exit(1)
		}
		env := s.EnvID
		if env == "" {
			env = *envID
		}
		proj := s.Project
		if proj == "" {
			proj = *project
		}
		var p provider.Provider
		switch s.ProviderName {
		case "aliyun":
			p = &aliyun.Driver{Root: *root, ConfigRoot: configRootDir, EnvID: env, Project: proj}
		default:
			fmt.Fprintf(os.Stderr, "unknown provider: %s\n", s.ProviderName)
			os.Exit(1)
		}
		eng := &orchestrator.Engine{Provider: p}
		if err := eng.Destroy(context.Background(), s); err != nil {
			fmt.Fprintf(os.Stderr, "destroy: %v\n", err)
			os.Exit(1)
		}
		fmt.Println("destroy ok")
	case "kubeconfig":
		s, err := loadState(*statePath)
		if err != nil {
			fmt.Fprintf(os.Stderr, "state: %v\n", err)
			os.Exit(1)
		}
		if s.ClusterCtx == nil {
			fmt.Fprintln(os.Stderr, "state 中无 cluster 信息，请先 deploy")
			os.Exit(1)
		}
		env := s.EnvID
		if env == "" {
			env = *envID
		}
		proj := s.Project
		if proj == "" {
			proj = *project
		}
		var p provider.Provider
		switch s.ProviderName {
		case "aliyun":
			p = &aliyun.Driver{Root: *root, ConfigRoot: configRootDir, EnvID: env, Project: proj}
		default:
			fmt.Fprintf(os.Stderr, "unknown provider: %s\n", s.ProviderName)
			os.Exit(1)
		}
		kubeconfig, err := p.GetKubeConfig(context.Background(), s.ClusterCtx.InstanceID)
		if err != nil {
			fmt.Fprintf(os.Stderr, "kubeconfig: %v\n", err)
			os.Exit(1)
		}
		os.Stdout.Write(kubeconfig)
	default:
		fmt.Fprintln(os.Stderr, "usage: deploy-engine -cmd=deploy|destroy|kubeconfig -config=... | -state=... [-root=<模块根>] [-env=dev] [-project=名称]")
		os.Exit(1)
	}
}

func loadConfig(path string) (*config.DeploymentConfig, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var cfg config.DeploymentConfig
	ext := strings.ToLower(filepath.Ext(path))
	if ext == ".yaml" || ext == ".yml" {
		if err := yaml.Unmarshal(data, &cfg); err != nil {
			return nil, err
		}
	} else {
		if err := json.Unmarshal(data, &cfg); err != nil {
			return nil, err
		}
	}
	return &cfg, nil
}

func saveState(path string, s *state.State) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0644)
}

func loadState(path string) (*state.State, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var s state.State
	if err := json.Unmarshal(data, &s); err != nil {
		return nil, err
	}
	return &s, nil
}
