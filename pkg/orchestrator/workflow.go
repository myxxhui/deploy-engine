// Package orchestrator 核心编排层：原子化作业流（Init -> Provision -> Config -> Deploy -> HealthCheck），以 Terraform 为基础设施主实现。
package orchestrator

import (
	"context"
	"fmt"
	"os"
	"os/exec"

	"github.com/titan-platform/deploy-engine/pkg/config"
	"github.com/titan-platform/deploy-engine/pkg/helm"
	"github.com/titan-platform/deploy-engine/pkg/provider"
	"github.com/titan-platform/deploy-engine/pkg/state"
)

const (
	StepInit        = "init"
	StepProvision   = "provision"
	StepConfig      = "config"
	StepDeploy      = "deploy"
	StepHealthCheck = "health_check"
)

// Engine 部署编排引擎：执行原子化工作流并维护状态。
type Engine struct {
	Provider provider.Provider
	StateDir string
}

// Deploy 执行全流程：Init -> Provision（Terraform Up）-> Config -> Deploy -> HealthCheck。
func (e *Engine) Deploy(ctx context.Context, cfg *config.DeploymentConfig) (*state.State, error) {
	if cfg.Merged == nil {
		cfg.Merge()
	}
	s := &state.State{
		DeploymentID: cfg.DeploymentID,
		ProviderName: cfg.ProviderName,
	}
	clusterCtx, err := e.Provider.Up(ctx, cfg)
	if err != nil {
		return nil, err
	}
	s.ClusterCtx = clusterCtx
	_ = StepConfig

	if clusterCtx != nil && len(clusterCtx.KubeConfig) > 0 && cfg.Merged != nil && cfg.Merged.Deployment != nil {
		if err := e.runStepDeploy(ctx, cfg.Merged.Deployment, clusterCtx.KubeConfig); err != nil {
			return nil, err
		}
	}
	if clusterCtx != nil && len(clusterCtx.KubeConfig) > 0 {
		if err := e.runStepHealthCheck(ctx, clusterCtx.KubeConfig); err != nil {
			return nil, fmt.Errorf("health_check: %w", err)
		}
	}
	return s, nil
}

// runStepHealthCheck 执行集群可访问性检查（kubectl cluster-info），便于 CI 判定部署是否可用。
func (e *Engine) runStepHealthCheck(ctx context.Context, kubeConfig []byte) error {
	tmp, err := os.CreateTemp("", "deploy-engine-kubeconfig-*")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if _, err := tmp.Write(kubeConfig); err != nil {
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	cmd := exec.CommandContext(ctx, "kubectl", "--kubeconfig="+tmpPath, "cluster-info")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("kubectl cluster-info: %w", err)
	}
	return nil
}

// runStepDeploy 在集群就绪后执行 Helm install/upgrade（若配置了 chart_path 或 chart_repo_url+chart_name）。
func (e *Engine) runStepDeploy(ctx context.Context, dep *config.DeploymentSpec, kubeConfig []byte) error {
	hasChart := dep.ChartPath != "" || (dep.ChartRepoURL != "" && dep.ChartName != "")
	if !hasChart {
		return nil
	}
	releaseName := dep.ReleaseName
	if releaseName == "" {
		releaseName = "release"
	}
	namespace := dep.Namespace
	if namespace == "" {
		namespace = "default"
	}
	return helm.InstallUpgrade(ctx, helm.InstallUpgradeOptions{
		KubeConfig:  kubeConfig,
		ReleaseName: releaseName,
		Namespace:   namespace,
		ChartPath:   dep.ChartPath,
		ChartRepo:   dep.ChartRepoURL,
		ChartName:   dep.ChartName,
		Values:      dep.Values,
		ValuesFiles: dep.ValuesFiles,
	})
}

// Destroy 根据状态执行反向销毁（Terraform destroy）。
// 当 s.ClusterCtx 为 nil 时仍调用 Provider.Down，以便 FULL_DESTROY=1 时无 state 文件也能完整销毁。
func (e *Engine) Destroy(ctx context.Context, s *state.State) error {
	if s == nil {
		return nil
	}
	return e.Provider.Down(ctx, s.ClusterCtx)
}
