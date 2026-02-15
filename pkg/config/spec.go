// Package config 输入抽象层：统一配置契约，独立于云厂商。
package config

// BaseResourceSpec 基础资源规格（CPU/Mem、竞价策略、区域等）。
type BaseResourceSpec struct {
	InstanceType     string   `json:"instance_type,omitempty"`
	Region           string   `json:"region,omitempty"`
	EnableSpot       *bool    `json:"enable_spot,omitempty"`
	SpotStrategy     string   `json:"spot_strategy,omitempty"`
	SpotPriceLimit   float64  `json:"spot_price_limit,omitempty"`
	DiskCategory     string   `json:"disk_category,omitempty"`
	DiskSize         int      `json:"disk_size,omitempty"`
	EIPBandwidth     int      `json:"eip_bandwidth,omitempty"`
	ImageID          string   `json:"image_id,omitempty"`
	AvailabilityZone string   `json:"availability_zone,omitempty"`
	VPCID            string   `json:"vpc_id,omitempty"`
	VSwitchID        string   `json:"vswitch_id,omitempty"`
	SecurityGroupID  string   `json:"security_group_id,omitempty"`
	ResourceTags     []string `json:"resource_tags,omitempty"`
}

// BaseEnvSpec 基础环境定义（K3s 版本、CNI 等）。
type BaseEnvSpec struct {
	K3sVersion   string `json:"k3s_version,omitempty"`
	CNI          string `json:"cni,omitempty"`
	ACRServer    string `json:"acr_server,omitempty"`
	ACRNamespace string `json:"acr_namespace,omitempty"`
	ConfigFile   string `json:"config_file,omitempty"`
}

// DeploymentSpec 应用部署定义（Chart 路径、Values 覆写）。
type DeploymentSpec struct {
	ChartPath    string         `json:"chart_path,omitempty"`
	ChartRepoURL string         `json:"chart_repo_url,omitempty"`
	ChartName    string         `json:"chart_name,omitempty"`
	ReleaseName  string         `json:"release_name,omitempty"`
	Namespace    string         `json:"namespace,omitempty"`
	Values       map[string]any `json:"values,omitempty"`
	ValuesFiles  []string       `json:"values_files,omitempty"`
}

// DeploymentConfig 顶层部署配置，支持三层合并（Default / Env / User Override）。
type DeploymentConfig struct {
	DeploymentID string       `json:"deployment_id"`
	ProviderName string       `json:"provider_name,omitempty"`
	Default      *LayerConfig `json:"default,omitempty"`
	Env          *LayerConfig `json:"env,omitempty"`
	UserOverride *LayerConfig `json:"user_override,omitempty"`
	Merged       *LayerConfig `json:"-"`
}

// LayerConfig 单层配置（资源 + 环境 + 部署）。
type LayerConfig struct {
	Resource   *BaseResourceSpec `json:"resource,omitempty"`
	Env        *BaseEnvSpec      `json:"env,omitempty"`
	Deployment *DeploymentSpec   `json:"deployment,omitempty"`
}

// Merge 执行三层合并：Default <- Env <- UserOverride，结果写入 c.Merged。
func (c *DeploymentConfig) Merge() {
	c.Merged = &LayerConfig{}
	layers := []*LayerConfig{c.Default, c.Env, c.UserOverride}
	for _, layer := range layers {
		if layer == nil {
			continue
		}
		mergeResource(c.Merged, layer)
		mergeEnv(c.Merged, layer)
		mergeDeployment(c.Merged, layer)
	}
}

func mergeResource(dst, src *LayerConfig) {
	if src.Resource == nil {
		return
	}
	if dst.Resource == nil {
		dst.Resource = &BaseResourceSpec{}
	}
	r, s := dst.Resource, src.Resource
	if s.InstanceType != "" {
		r.InstanceType = s.InstanceType
	}
	if s.Region != "" {
		r.Region = s.Region
	}
	if s.EnableSpot != nil {
		r.EnableSpot = s.EnableSpot
	}
	if s.SpotStrategy != "" {
		r.SpotStrategy = s.SpotStrategy
	}
	if s.SpotPriceLimit > 0 {
		r.SpotPriceLimit = s.SpotPriceLimit
	}
	if s.DiskCategory != "" {
		r.DiskCategory = s.DiskCategory
	}
	if s.DiskSize > 0 {
		r.DiskSize = s.DiskSize
	}
	if s.EIPBandwidth > 0 {
		r.EIPBandwidth = s.EIPBandwidth
	}
	if s.ImageID != "" {
		r.ImageID = s.ImageID
	}
	if s.AvailabilityZone != "" {
		r.AvailabilityZone = s.AvailabilityZone
	}
	if s.VPCID != "" {
		r.VPCID = s.VPCID
	}
	if s.VSwitchID != "" {
		r.VSwitchID = s.VSwitchID
	}
	if s.SecurityGroupID != "" {
		r.SecurityGroupID = s.SecurityGroupID
	}
	if len(s.ResourceTags) > 0 {
		r.ResourceTags = s.ResourceTags
	}
}

func mergeEnv(dst, src *LayerConfig) {
	if src.Env == nil {
		return
	}
	if dst.Env == nil {
		dst.Env = &BaseEnvSpec{}
	}
	e, s := dst.Env, src.Env
	if s.K3sVersion != "" {
		e.K3sVersion = s.K3sVersion
	}
	if s.CNI != "" {
		e.CNI = s.CNI
	}
	if s.ACRServer != "" {
		e.ACRServer = s.ACRServer
	}
	if s.ACRNamespace != "" {
		e.ACRNamespace = s.ACRNamespace
	}
	if s.ConfigFile != "" {
		e.ConfigFile = s.ConfigFile
	}
}

func mergeDeployment(dst, src *LayerConfig) {
	if src.Deployment == nil {
		return
	}
	if dst.Deployment == nil {
		dst.Deployment = &DeploymentSpec{}
	}
	d, s := dst.Deployment, src.Deployment
	if s.ChartPath != "" {
		d.ChartPath = s.ChartPath
	}
	if s.ChartRepoURL != "" {
		d.ChartRepoURL = s.ChartRepoURL
	}
	if s.ChartName != "" {
		d.ChartName = s.ChartName
	}
	if s.ReleaseName != "" {
		d.ReleaseName = s.ReleaseName
	}
	if s.Namespace != "" {
		d.Namespace = s.Namespace
	}
	if len(s.Values) > 0 {
		if d.Values == nil {
			d.Values = make(map[string]any)
		}
		for k, v := range s.Values {
			d.Values[k] = v
		}
	}
	if len(s.ValuesFiles) > 0 {
		d.ValuesFiles = s.ValuesFiles
	}
}
