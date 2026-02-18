// Package provider 基础设施适配层：驱动接口（Up/Down/GetKubeConfig），以 Terraform 为 IaC 主实现。
package provider

import (
	"context"

	"github.com/titan-platform/deploy-engine/pkg/config"
)

// ClusterContext 部署完成后集群上下文，用于状态锚定与 GetKubeConfig；Project/EnvID 供 Destroy 时与 Apply 使用同一 config_file。
type ClusterContext struct {
	InstanceID  string
	PublicIP    string
	KubeConfig  []byte
	ReleaseName string
	Namespace   string
	Project     string
	EnvID       string
}

// Provider 基础设施驱动接口。实现方通过 Terraform（或等价 IaC）管理资源生命周期。
type Provider interface {
	Name() string
	Up(ctx context.Context, cfg *config.DeploymentConfig) (*ClusterContext, error)
	Down(ctx context.Context, clusterCtx *ClusterContext) error
	GetKubeConfig(ctx context.Context, instanceID string) ([]byte, error)
}
