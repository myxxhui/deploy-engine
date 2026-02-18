// Package aliyun 阿里云 ECS + K3s 驱动，基于内嵌 Terraform（deploy/terraform/alicloud）。
package aliyun

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/titan-platform/deploy-engine/pkg/config"
	"github.com/titan-platform/deploy-engine/pkg/provider"
)

const providerName = "aliyun"

// Driver 使用模块内 deploy/terraform/alicloud 与 deploy/scripts 实现 Up/Down/GetKubeConfig。
// 契约：仅从 ConfigRoot 读取配置，不向 Root 写入任何配置；临时 tfvars 写系统临时目录。
type Driver struct {
	// Root 模块根目录（deploy-engine 仓库根）。为空时使用 DEPLOY_ENGINE_ROOT 或当前工作目录。仅用于 Terraform 工作目录与脚本路径。
	Root string
	// ConfigRoot 配置根目录，所有 tfvars、环境 YAML 均由此解析；为空时回退为 Root（兼容旧用法）。
	ConfigRoot string
	// EnvID 环境标识。
	EnvID string
	// Project 项目名，用于 kubeconfig 命名（kubeconfig-<Project>-<EnvID>）；为空时仅用 EnvID。
	Project string
}

func (d *Driver) Name() string { return providerName }

func (d *Driver) root() string {
	if d.Root != "" {
		return d.Root
	}
	if r := os.Getenv("DEPLOY_ENGINE_ROOT"); r != "" {
		return r
	}
	cwd, _ := os.Getwd()
	return cwd
}

// configRoot 配置根；为空时回退为 root（兼容旧用法）。
func (d *Driver) configRoot() string {
	if d.ConfigRoot != "" {
		return d.ConfigRoot
	}
	return d.root()
}

func (d *Driver) tfLiveDir() string {
	return filepath.Join(d.root(), "deploy", "terraform", "alicloud")
}

// tfVarsFile 返回实际使用的 tfvars 路径。优先扁平路径（ConfigRoot/terraform-<project>-<env>.tfvars），不存在则回退旧路径（config/environments/<env>/terraform.tfvars），命中旧路径时 usedLegacy=true。
func (d *Driver) tfVarsFile() (path string, usedLegacy bool) {
	flat := filepath.Join(d.configRoot(), config.FlatTfvarsName(d.Project, d.EnvID))
	if _, err := os.Stat(flat); err == nil {
		return flat, false
	}
	legacy := filepath.Join(d.root(), "config", "environments", d.EnvID, "terraform.tfvars")
	if _, err := os.Stat(legacy); err == nil {
		return legacy, true
	}
	return flat, false
}

// projectTfvarsPath 可选：仅兼容旧路径 config/environments/<env>/terraform.<project>.tfvars；扁平命名下无此文件，返回空。
func (d *Driver) projectTfvarsPath() string {
	if d.Project == "" {
		return ""
	}
	p := filepath.Join(d.root(), "config", "environments", d.EnvID, "terraform."+d.Project+".tfvars")
	if _, err := os.Stat(p); err == nil {
		return p
	}
	return ""
}

// instancePasswordFromEnvOrFile 优先从环境变量 TF_VAR_instance_password 读取，否则从 tfvars 文件中解析。
func (d *Driver) instancePasswordFromEnvOrFile(tfvarsPath string) (string, error) {
	if p := os.Getenv("TF_VAR_instance_password"); p != "" {
		return p, nil
	}
	f, err := os.Open(tfvarsPath)
	if err != nil {
		return "", err
	}
	defer f.Close()
	re := regexp.MustCompile(`^\s*instance_password\s*=\s*"(.*)"\s*$`)
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		if m := re.FindStringSubmatch(sc.Text()); len(m) == 2 {
			return strings.ReplaceAll(m[1], `\"`, `"`), nil
		}
	}
	return "", fmt.Errorf("instance_password 未设置：请设置环境变量 TF_VAR_instance_password 或在 %s 中配置 instance_password", tfvarsPath)
}

// kubeconfigPath 与 get-kubeconfig.sh 输出一致：带 Project 时为 kubeconfig-<Project>-<EnvID>，否则 kubeconfig-<EnvID>
func (d *Driver) kubeconfigPath() string {
	dir := os.Getenv("KUBECONFIG_DIR")
	if dir == "" {
		dir = filepath.Join(os.Getenv("HOME"), ".kube")
	}
	name := "kubeconfig-" + d.EnvID
	if d.Project != "" {
		name = "kubeconfig-" + d.Project + "-" + d.EnvID
	}
	return filepath.Join(dir, name)
}

func (d *Driver) Up(ctx context.Context, cfg *config.DeploymentConfig) (*provider.ClusterContext, error) {
	tfDir := d.tfLiveDir()
	tfvars, usedLegacy := d.tfVarsFile()
	if _, err := os.Stat(tfDir); os.IsNotExist(err) {
		return nil, fmt.Errorf("aliyun: terraform 目录不存在: %s（请设置 DEPLOY_ENGINE_ROOT 或在模块根目录执行）", tfDir)
	}
	if _, err := os.Stat(tfvars); os.IsNotExist(err) {
		return nil, fmt.Errorf("aliyun: tfvars 不存在: %s（请从 config/terraform-<project>-<env>.tfvars.example 复制并填写，或见《配置说明》迁移小节）", tfvars)
	}
	if usedLegacy {
		fmt.Fprintf(os.Stderr, "deploy-engine: [deprecation] 使用旧路径 %s，请迁移到扁平路径 %s，下一大版本将仅支持扁平路径。\n", tfvars, filepath.Join(d.configRoot(), config.FlatTfvarsName(d.Project, d.EnvID)))
	}

	instancePassword, err := d.instancePasswordFromEnvOrFile(tfvars)
	if err != nil {
		return nil, fmt.Errorf("aliyun: %w", err)
	}

	if err := d.runTerraform(ctx, tfDir, []string{"init"}, nil); err != nil {
		return nil, fmt.Errorf("aliyun: terraform init: %w", err)
	}
	_ = d.runTerraformStateRm(ctx, tfDir, "module.oss.alicloud_oss_bucket_object.init_script[0]")

	tfVarsAbs, _ := filepath.Abs(tfvars)
	applyArgs := []string{"apply", "-refresh=false", "-auto-approve"}

	var merged *config.LayerConfig
	if cfg != nil && cfg.Merged != nil {
		merged = cfg.Merged
	}
	mergedVars := config.ToAliyunTerraformVars(merged, d.EnvID, instancePassword, d.Project)
	configFilePath := mergedVars.ConfigFile
	if configFilePath != "" && !filepath.IsAbs(configFilePath) {
		configFilePath = filepath.Join(d.configRoot(), configFilePath)
	}
	if configFilePath == "" {
		configFilePath = filepath.Join(d.configRoot(), config.DeriveConfigFile(d.Project, d.EnvID))
	}
	if configFilePath != "" {
		if _, err := os.Stat(configFilePath); os.IsNotExist(err) {
			return nil, fmt.Errorf("aliyun: 配置文件不存在: %s（请在 ConfigRoot 下放置 <project>-<env>.yaml 或 default-<env>.yaml，或设置 config_file）", configFilePath)
		}
		mergedVars.ConfigFile = configFilePath
	}
	tmpFile, err := os.CreateTemp("", "deploy-engine-*.tfvars")
	if err != nil {
		return nil, fmt.Errorf("aliyun: 创建临时 tfvars: %w", err)
	}
	tmpPath := tmpFile.Name()
	defer os.Remove(tmpPath)
	if err := config.WriteAliyunTerraformVarsToFile(mergedVars, tmpPath); err != nil {
		return nil, fmt.Errorf("aliyun: 写入 Merged 变量: %w", err)
	}
	applyArgs = append(applyArgs, "-var-file="+tmpPath)
	if p := d.projectTfvarsPath(); p != "" {
		if _, err := os.Stat(p); err == nil {
			applyArgs = append(applyArgs, "-var-file="+p)
		}
	}
	applyArgs = append(applyArgs, "-var-file="+tfVarsAbs, "-var=env_id="+d.EnvID)

	if err := d.runTerraform(ctx, tfDir, applyArgs, nil); err != nil {
		return nil, fmt.Errorf("aliyun: terraform apply: %w", err)
	}

	instanceID, err := d.terraformOutput(ctx, tfDir, "instance_id")
	if err != nil {
		return nil, fmt.Errorf("aliyun: terraform output instance_id: %w", err)
	}
	publicIP, err := d.terraformOutput(ctx, tfDir, "public_ip")
	if err != nil {
		return nil, fmt.Errorf("aliyun: terraform output public_ip: %w", err)
	}
	if publicIP == "" || publicIP == "Instance Released" {
		return nil, fmt.Errorf("aliyun: public_ip 无效，可能实例未就绪")
	}

	kubeConfig, _ := d.fetchKubeConfig(ctx)
	releaseName := ""
	namespace := "default"
	if cfg != nil && cfg.Merged != nil && cfg.Merged.Deployment != nil {
		if cfg.Merged.Deployment.ReleaseName != "" {
			releaseName = cfg.Merged.Deployment.ReleaseName
		}
		if cfg.Merged.Deployment.Namespace != "" {
			namespace = cfg.Merged.Deployment.Namespace
		}
	}

	return &provider.ClusterContext{
		InstanceID:  instanceID,
		PublicIP:    publicIP,
		KubeConfig:  kubeConfig,
		ReleaseName: releaseName,
		Namespace:   namespace,
		Project:     d.Project,
		EnvID:       d.EnvID,
	}, nil
}

func (d *Driver) Down(ctx context.Context, clusterCtx *provider.ClusterContext) error {
	tfDir := d.tfLiveDir()
	tfvars, _ := d.tfVarsFile()
	if _, err := os.Stat(tfDir); os.IsNotExist(err) {
		return fmt.Errorf("aliyun: terraform 目录不存在: %s", tfDir)
	}
	if _, err := os.Stat(tfvars); os.IsNotExist(err) {
		return fmt.Errorf("aliyun: tfvars 不存在: %s（无法执行 destroy）", tfvars)
	}
	_ = d.runTerraformStateRm(ctx, tfDir, "module.oss.alicloud_oss_bucket_object.init_script[0]")
	tfVarsAbs, _ := filepath.Abs(tfvars)
	project := d.Project
	envID := d.EnvID
	if clusterCtx != nil {
		if clusterCtx.Project != "" {
			project = clusterCtx.Project
		}
		if clusterCtx.EnvID != "" {
			envID = clusterCtx.EnvID
		}
	}
	configFileAbs := filepath.Join(d.configRoot(), config.DeriveConfigFile(project, envID))
	if abs, err := filepath.Abs(configFileAbs); err == nil {
		configFileAbs = abs
	}
	destroyArgs := []string{"destroy"}
	if p := d.projectTfvarsPath(); p != "" {
		destroyArgs = append(destroyArgs, "-var-file="+p)
	}
	destroyArgs = append(destroyArgs, "-var-file="+tfVarsAbs, "-var=env_id="+envID, "-var=project="+project, "-var=config_file="+configFileAbs, "-target=module.ecs", "-auto-approve")
	err := d.runTerraform(ctx, tfDir, destroyArgs, nil)
	if err != nil {
		return fmt.Errorf("aliyun: terraform destroy: %w", err)
	}
	_ = os.Remove(d.kubeconfigPath())
	return nil
}

func (d *Driver) GetKubeConfig(ctx context.Context, _ string) ([]byte, error) {
	return d.fetchKubeConfig(ctx)
}

func (d *Driver) runTerraform(ctx context.Context, tfDir string, args []string, _ map[string]string) error {
	cmd := exec.CommandContext(ctx, "terraform", args...)
	cmd.Dir = tfDir
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func (d *Driver) runTerraformStateRm(ctx context.Context, tfDir, resource string) error {
	cmd := exec.CommandContext(ctx, "terraform", "state", "rm", resource)
	cmd.Dir = tfDir
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	_ = cmd.Run()
	return nil
}

func (d *Driver) terraformOutput(ctx context.Context, tfDir, name string) (string, error) {
	cmd := exec.CommandContext(ctx, "terraform", "output", "-raw", name)
	cmd.Dir = tfDir
	out, err := cmd.Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

func (d *Driver) fetchKubeConfig(ctx context.Context) ([]byte, error) {
	root := d.root()
	script := filepath.Join(root, "deploy", "scripts", "get-kubeconfig.sh")
	if _, err := os.Stat(script); os.IsNotExist(err) {
		return nil, nil
	}
	args := []string{script, d.EnvID}
	if d.Project != "" {
		args = append(args, d.Project)
	}
	cmd := exec.CommandContext(ctx, "bash", args...)
	cmd.Dir = root
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("get-kubeconfig.sh: %w: %s", err, stderr.String())
	}
	return os.ReadFile(d.kubeconfigPath())
}
