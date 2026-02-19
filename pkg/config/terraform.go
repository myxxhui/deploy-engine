// Package config：将统一配置映射为 Terraform 变量（用于阿里云 driver）。
package config

import (
	"fmt"
	"os"
	"strings"
)

// AliyunTerraformVars 与 deploy-engine 内 Terraform variables 对应。
type AliyunTerraformVars struct {
	EnvID                    string  `json:"env_id"`
	Project                  string  `json:"project,omitempty"`
	ConfigFile               string  `json:"config_file,omitempty"`
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

// 扁平命名规则（均在 ConfigRoot 下）：环境 YAML 为 <project>-<env>.yaml（无 project 时 default-<env>.yaml）；
// tfvars 为 terraform-<project>-<env>.tfvars（无 project 时 terraform-<env>.tfvars）。不再使用 environments/<env>/ 层级。

// DeriveConfigFile 返回扁平文件名：有 project 则 <project>-<env>.yaml，否则 default-<env>.yaml。调用方需与 ConfigRoot 拼接得到绝对路径。
func DeriveConfigFile(project, envID string) string {
	if project != "" {
		return project + "-" + envID + ".yaml"
	}
	return "default-" + envID + ".yaml"
}

// FlatTfvarsName 返回扁平 tfvars 文件名：有 project 则 terraform-<project>-<env>.tfvars，否则 terraform-<env>.tfvars。
func FlatTfvarsName(project, envID string) string {
	if project != "" {
		return "terraform-" + project + "-" + envID + ".tfvars"
	}
	return "terraform-" + envID + ".tfvars"
}

func deriveConfigFile(project, envID string) string {
	return DeriveConfigFile(project, envID)
}

// ToAliyunTerraformVars 从 Merged 配置生成阿里云 Terraform 变量；project 用于未指定 config_file 时推导路径，保证 Apply/Destroy 一致。
func ToAliyunTerraformVars(merged *LayerConfig, envID, instancePassword, project string) AliyunTerraformVars {
	v := AliyunTerraformVars{
		EnvID:            envID,
		Project:          project,
		ConfigFile:       deriveConfigFile(project, envID),
		InstancePassword: instancePassword,
		EnableSpot:       true,
		Region:           "cn-hongkong",
		InstanceType:     "ecs.u1-c1m4.xlarge",
		SpotStrategy:     "SpotAsPriceGo",
		SpotPriceLimit:   0.5,
		DiskCategory:     "cloud",
		DiskSize:         100,
		EIPBandwidth:     100,
	}
	if merged != nil && merged.Env != nil && merged.Env.ConfigFile != "" {
		v.ConfigFile = merged.Env.ConfigFile
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

// WriteAliyunTerraformVarsToFile 将 AliyunTerraformVars 写入 HCL tfvars 文件，供 Terraform -var-file 使用。
// 调用方可通过环境变量 TF_VAR_instance_password 覆盖密码，避免写入文件；若未设置则写入 v.InstancePassword。
func WriteAliyunTerraformVarsToFile(v AliyunTerraformVars, path string) error {
	var b strings.Builder
	hclStr := func(s string) string {
		if s == "" {
			return `""`
		}
		return `"` + strings.ReplaceAll(strings.ReplaceAll(s, `\`, `\\`), `"`, `\"`) + `"`
	}
	fmt.Fprintf(&b, "env_id            = %s\n", hclStr(v.EnvID))
	fmt.Fprintf(&b, "project           = %s\n", hclStr(v.Project))
	fmt.Fprintf(&b, "config_file       = %s\n", hclStr(v.ConfigFile))
	fmt.Fprintf(&b, "region            = %s\n", hclStr(v.Region))
	fmt.Fprintf(&b, "enable_spot       = %t\n", v.EnableSpot)
	fmt.Fprintf(&b, "instance_type     = %s\n", hclStr(v.InstanceType))
	fmt.Fprintf(&b, "instance_password = %s\n", hclStr(v.InstancePassword))
	fmt.Fprintf(&b, "spot_strategy     = %s\n", hclStr(v.SpotStrategy))
	fmt.Fprintf(&b, "spot_price_limit  = %g\n", v.SpotPriceLimit)
	fmt.Fprintf(&b, "disk_category     = %s\n", hclStr(v.DiskCategory))
	fmt.Fprintf(&b, "disk_size         = %d\n", v.DiskSize)
	fmt.Fprintf(&b, "eip_bandwidth     = %d\n", v.EIPBandwidth)
	if v.ImageID != "" {
		fmt.Fprintf(&b, "image_id          = %s\n", hclStr(v.ImageID))
	}
	fmt.Fprintf(&b, "acr_server        = %s\n", hclStr(v.ACRServer))
	fmt.Fprintf(&b, "acr_namespace     = %s\n", hclStr(v.ACRNamespace))
	fmt.Fprintf(&b, "vpc_use_existing  = %t\n", v.VPCUseExisting)
	fmt.Fprintf(&b, "vpc_existing_id   = %s\n", hclStr(v.VPCExistingID))
	fmt.Fprintf(&b, "vswitch_use_existing = %t\n", v.VSwitchUseExisting)
	fmt.Fprintf(&b, "vswitch_existing_id  = %s\n", hclStr(v.VSwitchExistingID))
	fmt.Fprintf(&b, "security_group_use_existing = %t\n", v.SecurityGroupUseExisting)
	fmt.Fprintf(&b, "security_group_existing_id   = %s\n", hclStr(v.SecurityGroupExistingID))
	return os.WriteFile(path, []byte(b.String()), 0600)
}
