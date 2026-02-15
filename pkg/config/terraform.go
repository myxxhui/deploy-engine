// Package config：将统一配置映射为 Terraform 变量（用于阿里云 driver）。
package config

// AliyunTerraformVars 与 deploy-engine 内 Terraform variables 对应。
type AliyunTerraformVars struct {
	EnvID                    string  `json:"env_id"`
	Region                   string  `json:"region,omitempty"`
	EnableSpot               bool    `json:"enable_spot"`
	InstanceType             string  `json:"instance_type,omitempty"`
	InstancePassword         string  `json:"instance_password"`
	SpotStrategy             string  `json:"spot_strategy,omitempty"`
	SpotPriceLimit           float64 `json:"spot_price_limit,omitempty"`
	DiskCategory             string  `json:"disk_category,omitempty"`
	DiskSize                 int     `json:"disk_size,omitempty"`
	ImageID                  string  `json:"image_id,omitempty"`
	EIPBandwidth             int     `json:"eip_bandwidth,omitempty"`
	ACRServer                string  `json:"acr_server,omitempty"`
	ACRNamespace             string  `json:"acr_namespace,omitempty"`
	VPCUseExisting           bool    `json:"vpc_use_existing,omitempty"`
	VPCExistingID            string  `json:"vpc_existing_id,omitempty"`
	VSwitchUseExisting       bool    `json:"vswitch_use_existing,omitempty"`
	VSwitchExistingID        string  `json:"vswitch_existing_id,omitempty"`
	SecurityGroupUseExisting bool    `json:"security_group_use_existing,omitempty"`
	SecurityGroupExistingID  string  `json:"security_group_existing_id,omitempty"`
}

// ToAliyunTerraformVars 从 Merged 配置生成阿里云 Terraform 变量。
func ToAliyunTerraformVars(merged *LayerConfig, envID, instancePassword string) AliyunTerraformVars {
	v := AliyunTerraformVars{
		EnvID:            envID,
		InstancePassword: instancePassword,
		EnableSpot:       true,
		Region:           "cn-hongkong",
		InstanceType:     "ecs.u1-c1m4.xlarge",
		SpotStrategy:     "SpotAsPriceGo",
		SpotPriceLimit:   0.5,
		DiskCategory:     "cloud_essd",
		DiskSize:         100,
		EIPBandwidth:     100,
	}
	if merged == nil {
		return v
	}
	if r := merged.Resource; r != nil {
		if r.Region != "" {
			v.Region = r.Region
		}
		if r.InstanceType != "" {
			v.InstanceType = r.InstanceType
		}
		if r.EnableSpot != nil {
			v.EnableSpot = *r.EnableSpot
		}
		if r.SpotStrategy != "" {
			v.SpotStrategy = r.SpotStrategy
		}
		if r.SpotPriceLimit > 0 {
			v.SpotPriceLimit = r.SpotPriceLimit
		}
		if r.DiskCategory != "" {
			v.DiskCategory = r.DiskCategory
		}
		if r.DiskSize > 0 {
			v.DiskSize = r.DiskSize
		}
		if r.ImageID != "" {
			v.ImageID = r.ImageID
		}
		if r.EIPBandwidth > 0 {
			v.EIPBandwidth = r.EIPBandwidth
		}
		if r.VPCID != "" {
			v.VPCUseExisting = true
			v.VPCExistingID = r.VPCID
		}
		if r.VSwitchID != "" {
			v.VSwitchUseExisting = true
			v.VSwitchExistingID = r.VSwitchID
		}
		if r.SecurityGroupID != "" {
			v.SecurityGroupUseExisting = true
			v.SecurityGroupExistingID = r.SecurityGroupID
		}
	}
	if e := merged.Env; e != nil {
		if e.ACRServer != "" {
			v.ACRServer = e.ACRServer
		}
		if e.ACRNamespace != "" {
			v.ACRNamespace = e.ACRNamespace
		}
	}
	return v
}
