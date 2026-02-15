// Package state 状态锚定：记录 InstanceID、ClusterContext、ReleaseName 等，作为「一条命令回收环境」的凭证。
package state

import "github.com/titan-platform/deploy-engine/pkg/provider"

// State 部署状态，可持久化为 JSON 文件或数据库记录。
type State struct {
	DeploymentID string                   `json:"deployment_id"`
	ProviderName string                   `json:"provider_name"`
	Project      string                   `json:"project,omitempty"`
	EnvID        string                   `json:"env_id,omitempty"`
	ClusterCtx   *provider.ClusterContext `json:"cluster_ctx,omitempty"`
	ResourceTags []string                 `json:"resource_tags,omitempty"`
}
