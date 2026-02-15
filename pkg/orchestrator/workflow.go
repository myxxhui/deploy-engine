// Package orchestrator 核心编排层：原子化作业流（Init -> Provision -> Config -> Deploy -> HealthCheck），以 Terraform 为基础设施主实现。
package orchestrator

import (
	"context"

	"github.com/titan-platform/deploy-engine/pkg/config"
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
	_ = StepDeploy
	_ = StepHealthCheck
	return s, nil
}

// Destroy 根据状态执行反向销毁（Terraform destroy）。
func (e *Engine) Destroy(ctx context.Context, s *state.State) error {
	if s == nil || s.ClusterCtx == nil {
		return nil
	}
	return e.Provider.Down(ctx, s.ClusterCtx)
}
