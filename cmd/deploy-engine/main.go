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
	"time"

	"github.com/titan-platform/deploy-engine/pkg/config"
	"github.com/titan-platform/deploy-engine/pkg/orchestrator"
	"github.com/titan-platform/deploy-engine/pkg/ossstate"
	"github.com/titan-platform/deploy-engine/pkg/provider"
	"github.com/titan-platform/deploy-engine/pkg/provider/aliyun"
	"github.com/titan-platform/deploy-engine/pkg/state"
	"gopkg.in/yaml.v3"
)

// #region agent log
const debugLogPath = "/Users/huishaoqi/Desktop/workspace/.cursor/debug.log"

func agentLog(location, message, hypothesisId string, data map[string]interface{}) {
	if data == nil {
		data = make(map[string]interface{})
	}
	payload := map[string]interface{}{
		"location": location, "message": message, "hypothesisId": hypothesisId,
		"data": data, "timestamp": time.Now().UnixMilli(),
	}
	if b, err := json.Marshal(payload); err == nil {
		f, err := os.OpenFile(debugLogPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
		if err == nil {
			f.Write(append(b, '\n'))
			f.Close()
		}
	}
}
// #endregion

func main() {
	cmd := flag.String("cmd", "", "deploy | destroy | kubeconfig")
	configPath := flag.String("config", "", "deploy.json 路径；其所在目录作为 ConfigRoot（配置根），未设置 -config-root 时生效")
	configRoot := flag.String("config-root", "", "配置根目录，覆盖由 -config 推导的目录；tfvars、环境 YAML 均由此解析")
	statePath := flag.String("state", ".deploy/state.json", "state file path")
	providerName := flag.String("provider", "aliyun", "provider name")
	root := flag.String("root", os.Getenv("DEPLOY_ENGINE_ROOT"), "deploy-engine 模块根目录（含 deploy/），仅用于 Terraform 与脚本")
	envID := flag.String("env", "dev", "环境 ID")
	project := flag.String("project", "", "项目名，用于 state 与 kubeconfig 命名（如 config-<project>-<env>）")
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
		// #region agent log
		defer func() {
			if r := recover(); r != nil {
				agentLog("main.go:deploy:recover", fmt.Sprint(r), "H5", map[string]interface{}{"panic": fmt.Sprint(r)})
				panic(r)
			}
		}()
		// #endregion
		if *configPath == "" {
			fmt.Fprintln(os.Stderr, "usage: deploy-engine -cmd=deploy -config=deploy.json [-root=...] [-env=dev] [-project=名称]")
			os.Exit(1)
		}
		// #region agent log
		agentLog("main.go:deploy:start", "deploy started", "H5", map[string]interface{}{"configPath": *configPath, "project": *project, "env": *envID})
		// #endregion
		cfg, err := loadConfig(*configPath)
		if err != nil {
			fmt.Fprintf(os.Stderr, "config: %v\n", err)
			os.Exit(1)
		}
		// #region agent log
		agentLog("main.go:deploy:after-loadConfig", "loadConfig ok", "H5", nil)
		// #endregion
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
		// #region agent log
		if err != nil {
			agentLog("main.go:deploy:after-Deploy", "Deploy error", "H1", map[string]interface{}{"error": err.Error()})
		} else {
			agentLog("main.go:deploy:after-Deploy", "Deploy ok", "H1", nil)
		}
		// #endregion
		if err != nil {
			fmt.Fprintf(os.Stderr, "deploy: %v\n", err)
			os.Exit(1)
		}
		s.EnvID = *envID
		s.Project = *project
		// #region agent log
		agentLog("main.go:deploy:before-saveState", "before saveState", "H4", map[string]interface{}{"statePath": *statePath})
		// #endregion
		if err := saveState(*statePath, s); err != nil {
			fmt.Fprintf(os.Stderr, "save state: %v\n", err)
			os.Exit(1)
		}
		// 自动上传 state 到 OSS，实现多机共享 down 凭证
		// 降级：凭证缺失或网络失败时只打印警告，不阻断流程
		_ = ossstate.Upload(s.Project, s.EnvID, *statePath)
		// #region agent log
		agentLog("main.go:deploy:after-saveState", "deploy ok", "H4", nil)
		// #endregion
		fmt.Println("deploy ok, state:", *statePath)
	case "destroy":
		s, err := loadState(*statePath)
		if err != nil {
			if os.IsNotExist(err) {
				// 本地 state 不存在 → 尝试从 OSS 自动恢复
				fmt.Fprintln(os.Stderr, "[ossstate] 本地 state 文件不存在，尝试从 OSS 恢复...")
				proj := *project
				env := *envID
				ossErr := ossstate.Download(proj, env, *statePath)
				if ossErr == nil {
					// 恢复成功，重新加载
					s, err = loadState(*statePath)
				} else if os.IsNotExist(ossErr) {
					// OSS 上也没有（资源可能已销毁或从未 deploy）
					s = nil
					err = os.ErrNotExist
				} else {
					// OSS 访问失败，但凭证/网络问题不应阻断 FULL_DESTROY
					fmt.Fprintf(os.Stderr, "[ossstate warn] 从 OSS 恢复 state 失败: %v\n", ossErr)
					s = nil
					err = os.ErrNotExist
				}
			}
		}
		if err != nil {
			// 无 state 文件时，FULL_DESTROY=1 且指定了 project 则仍可完整销毁（按 tfvars 清理资源）
			if os.IsNotExist(err) && os.Getenv("FULL_DESTROY") != "" && *project != "" {
				fmt.Fprintln(os.Stderr, "未找到 state 文件，因 FULL_DESTROY=1 将按 project/env 与 tfvars 执行销毁")
				s = &state.State{ProviderName: *providerName, Project: *project, EnvID: *envID, ClusterCtx: nil}
			} else if os.IsNotExist(err) {
				fmt.Println("no state file, nothing to destroy")
				fmt.Fprintln(os.Stderr, "提示: 若资源在别处创建或 state 丢失，可用 FULL_DESTROY=1 make down <project> <env> 强制按 tfvars 销毁")
				os.Exit(0)
			} else {
				fmt.Fprintf(os.Stderr, "state: %v\n", err)
				os.Exit(1)
			}
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
		// destroy 成功后：删除 OSS 上的 state（资源已销毁，凭证无意义）并清理本地文件
		_ = ossstate.Delete(proj, env)
		if err := os.Remove(*statePath); err != nil && !os.IsNotExist(err) {
			fmt.Fprintf(os.Stderr, "[ossstate warn] 删除本地 state 文件失败: %v\n", err)
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
