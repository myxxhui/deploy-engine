// Package aliyun 阿里云 ECS + K3s 驱动，基于内嵌 Terraform（deploy/terraform/alicloud）。
package aliyun

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/titan-platform/deploy-engine/pkg/config"
	"github.com/titan-platform/deploy-engine/pkg/provider"
)

const providerName = "aliyun"

// Driver 使用模块内 deploy/terraform/alicloud 与 deploy/scripts 实现 Up/Down/GetKubeConfig。
type Driver struct {
	// Root 模块根目录（deploy-engine 仓库根）。为空时使用 DEPLOY_ENGINE_ROOT 或当前工作目录。
	Root string
	// EnvID 环境标识，对应 config/environments/<EnvID>/terraform.tfvars。
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
	// 默认：当前工作目录视为模块根（调用方需在 deploy-engine 根下执行，或通过 Root 指定）
	cwd, _ := os.Getwd()
	return cwd
}

func (d *Driver) tfLiveDir() string {
	return filepath.Join(d.root(), "deploy", "terraform", "alicloud")
}

func (d *Driver) tfVarsFile() string {
	return filepath.Join(d.root(), "config", "environments", d.EnvID, "terraform.tfvars")
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
	tfvars := d.tfVarsFile()
	if _, err := os.Stat(tfDir); os.IsNotExist(err) {
		return nil, fmt.Errorf("aliyun: terraform 目录不存在: %s（请设置 DEPLOY_ENGINE_ROOT 或在模块根目录执行）", tfDir)
	}
	if _, err := os.Stat(tfvars); os.IsNotExist(err) {
		return nil, fmt.Errorf("aliyun: tfvars 不存在: %s（请从 config/environments/%s/terraform.tfvars.example 复制并填写）", tfvars, d.EnvID)
	}

	if err := d.runTerraform(ctx, tfDir, []string{"init"}, nil); err != nil {
		return nil, fmt.Errorf("aliyun: terraform init: %w", err)
	}
	_ = d.runTerraformStateRm(ctx, tfDir, "module.oss.alicloud_oss_bucket_object.init_script[0]")

	// -var-file 相对于当前工作目录；terraform 在 tfDir 下执行，需传绝对路径或相对于 cwd 的路径
	tfVarsAbs, _ := filepath.Abs(tfvars)
	if err := d.runTerraform(ctx, tfDir, []string{
		"apply",
		"-var-file=" + tfVarsAbs,
		"-var=env_id=" + d.EnvID,
		"-refresh=false",
		"-auto-approve",
	}, nil); err != nil {
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
	}, nil
}

func (d *Driver) Down(ctx context.Context, _ *provider.ClusterContext) error {
	tfDir := d.tfLiveDir()
	tfvars := d.tfVarsFile()
	if _, err := os.Stat(tfDir); os.IsNotExist(err) {
		return fmt.Errorf("aliyun: terraform 目录不存在: %s", tfDir)
	}
	if _, err := os.Stat(tfvars); os.IsNotExist(err) {
		return fmt.Errorf("aliyun: tfvars 不存在: %s（无法执行 destroy）", tfvars)
	}
	_ = d.runTerraformStateRm(ctx, tfDir, "module.oss.alicloud_oss_bucket_object.init_script[0]")
	tfVarsAbs, _ := filepath.Abs(tfvars)
	err := d.runTerraform(ctx, tfDir, []string{
		"destroy",
		"-var-file=" + tfVarsAbs,
		"-var=env_id=" + d.EnvID,
		"-target=module.ecs",
		"-auto-approve",
	}, nil)
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
