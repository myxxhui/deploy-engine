// Package config - deploy_control 部署控制配置（从环境 YAML 的 deploy_control 节读取）
package config

import (
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

// DeployControl 部署控制：决定是否部署各组件及存储配置（从环境 YAML 的 deploy_control 节读取）
type DeployControl struct {
	// 是否部署 TimescaleDB（L1）
	EnableTimescaleDB bool `json:"enable_timescaledb" yaml:"enable_timescaledb"`
	// 是否部署 PostgreSQL L2
	EnablePostgresL2 bool `json:"enable_postgres_l2" yaml:"enable_postgres_l2"`
	// 是否部署 Redis
	EnableRedis bool `json:"enable_redis" yaml:"enable_redis"`
	// K3s 默认存储插件（local-path / nfs-client 等）
	K3sStoragePlugin string `json:"k3s_storage_plugin" yaml:"k3s_storage_plugin"`
	// TimescaleDB/L1 存储配置
	TimescaleDBStorage StorageConfig `json:"timescaledb_storage" yaml:"timescaledb_storage"`
	// PostgreSQL L2 存储配置
	PostgresL2Storage StorageConfig `json:"postgres_l2_storage" yaml:"postgres_l2_storage"`
	// Redis 存储配置
	RedisStorage StorageConfig `json:"redis_storage" yaml:"redis_storage"`
}

// StorageConfig 存储配置（PVC 大小、StorageClass）
type StorageConfig struct {
	Size         string `json:"size" yaml:"size"`
	StorageClass string `json:"storage_class" yaml:"storage_class"`
}

// LoadDeployControl 从环境 YAML 文件读取 deploy_control 节；文件不存在或无 deploy_control 节时返回 nil（不报错）
func LoadDeployControl(configFilePath string) (*DeployControl, error) {
	if configFilePath == "" {
		return nil, nil
	}
	data, err := os.ReadFile(configFilePath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("读取配置文件失败: %w", err)
	}
	var raw struct {
		DeployControl *DeployControl `yaml:"deploy_control"`
	}
	if err := yaml.Unmarshal(data, &raw); err != nil {
		return nil, fmt.Errorf("解析 YAML 失败: %w", err)
	}
	return raw.DeployControl, nil
}
