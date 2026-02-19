// Package aliyun 阿里云 ECS + K3s 驱动，基于内嵌 Terraform（deploy/terraform/alicloud）。
package aliyun

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/titan-platform/deploy-engine/pkg/config"
	"github.com/titan-platform/deploy-engine/pkg/provider"
)

// #region agent log
const debugLogPath = "/Users/huishaoqi/Desktop/workspace/.cursor/debug.log"

func agentLog(location, message, hypothesisId string, data map[string]interface{}) {
	if data == nil {
		data = make(map[string]interface{})
	}
	payload := map[string]interface{}{"location": location, "message": message, "hypothesisId": hypothesisId, "data": data, "timestamp": time.Now().UnixMilli()}
	if b, err := json.Marshal(payload); err == nil {
		if f, err := os.OpenFile(debugLogPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644); err == nil {
			f.Write(append(b, '\n'))
			f.Close()
		}
	}
}

// #endregion

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
	// Project 项目名，用于 kubeconfig 命名（config-<Project>-<EnvID>）；为空时仅用 EnvID。
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

// tfVarsFile 返回实际使用的 tfvars 路径。优先级：① ConfigRoot/terraform-<project>-<env>.tfvars；② ConfigRoot/terraform-<env>.tfvars（无 project 或 project 级不存在时共用）；③ config/environments/<env>/terraform.tfvars（旧路径）。
func (d *Driver) tfVarsFile() (path string, usedLegacy bool) {
	flat := filepath.Join(d.configRoot(), config.FlatTfvarsName(d.Project, d.EnvID))
	if _, err := os.Stat(flat); err == nil {
		return flat, false
	}
	// 有 project 时，若 terraform-<project>-<env>.tfvars 不存在，回退到 terraform-<env>.tfvars
	if d.Project != "" {
		fallback := filepath.Join(d.configRoot(), config.FlatTfvarsName("", d.EnvID))
		if _, err := os.Stat(fallback); err == nil {
			return fallback, false
		}
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

// regionFromTerraformState 从 Terraform state 中解析资源的实际 region，用于 destroy 时使用正确地域的 API 端点。
// 若 state 中资源与 tfvars 的 region 不一致，destroy 会因调用错误地域的 API 而失败。
func (d *Driver) regionFromTerraformState(ctx context.Context, tfDir string) string {
	cmd := exec.CommandContext(ctx, "terraform", "state", "pull")
	cmd.Dir = tfDir
	out, err := cmd.Output()
	if err != nil || len(out) == 0 {
		return ""
	}
	var state struct {
		Resources []struct {
			Instances []struct {
				Attributes map[string]interface{} `json:"attributes"`
			} `json:"instances"`
		} `json:"resources"`
	}
	if err := json.Unmarshal(out, &state); err != nil {
		return ""
	}
	for _, res := range state.Resources {
		for _, inst := range res.Instances {
			if inst.Attributes == nil {
				continue
			}
			if r, ok := inst.Attributes["region_id"]; ok {
				if s, ok := r.(string); ok && s != "" {
					return s
				}
			}
			if r, ok := inst.Attributes["region"]; ok {
				if s, ok := r.(string); ok && s != "" {
					return s
				}
			}
		}
	}
	return ""
}

// regionFromTfvars 从 tfvars 文件解析 region，供 apply 时显式传入以确保优先级。
func regionFromTfvars(tfvarsPath string) string {
	f, err := os.Open(tfvarsPath)
	if err != nil {
		return ""
	}
	defer f.Close()
	re := regexp.MustCompile(`^\s*region\s*=\s*"([^"]+)"\s*$`)
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		if m := re.FindStringSubmatch(sc.Text()); len(m) == 2 {
			return m[1]
		}
	}
	return ""
}

// diskCategoryFromTfvars 从 tfvars 解析 disk_category，供 apply 时显式传入以确保优先级（与 region 同逻辑）。
func diskCategoryFromTfvars(tfvarsPath string) string {
	f, err := os.Open(tfvarsPath)
	if err != nil {
		return ""
	}
	defer f.Close()
	re := regexp.MustCompile(`^\s*disk_category\s*=\s*"([^"]+)"\s*$`)
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		if m := re.FindStringSubmatch(sc.Text()); len(m) == 2 {
			return m[1]
		}
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

// ecsInstanceInState 检查 Terraform state 中是否仍存在 ECS 实例（destroy 后 output 可能仍残留旧值，须以 state 为准）。
func (d *Driver) ecsInstanceInState(ctx context.Context, tfDir string) bool {
	cmd := exec.CommandContext(ctx, "terraform", "state", "list")
	cmd.Dir = tfDir
	out, err := cmd.Output()
	if err != nil {
		return false
	}
	return strings.Contains(string(out), "module.ecs.alicloud_instance.")
}

// tryExistingOutputs 从当前 Terraform 状态读取 instance_id、public_ip，且 state 中确有 ECS 资源时才返回 skipApply=true（避免 destroy 后残留 output 导致误跳过 apply）。
func (d *Driver) tryExistingOutputs(ctx context.Context, tfDir string) (instanceID, publicIP string, skipApply bool) {
	id, err1 := d.terraformOutput(ctx, tfDir, "instance_id")
	ip, err2 := d.terraformOutput(ctx, tfDir, "public_ip")
	if err1 != nil || err2 != nil {
		return "", "", false
	}
	if id == "" || ip == "" || ip == "Instance Released" {
		return "", "", false
	}
	if !d.ecsInstanceInState(ctx, tfDir) {
		return "", "", false
	}
	return id, ip, true
}

// kubeconfigPath 与 get-kubeconfig.sh 输出一致：带 Project 时为 config-<Project>-<EnvID>，否则 config-<EnvID>
func (d *Driver) kubeconfigPath() string {
	dir := os.Getenv("KUBECONFIG_DIR")
	if dir == "" {
		dir = filepath.Join(os.Getenv("HOME"), ".kube")
	}
	name := "config-" + d.EnvID
	if d.Project != "" {
		name = "config-" + d.Project + "-" + d.EnvID
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
		return nil, fmt.Errorf("aliyun: tfvars 不存在: %s（请从 config/examples/terraform-<project>-<env>.tfvars.example 复制到 config/ 并填写，或见《配置说明》）", tfvars)
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

	// 若 Terraform 状态中已有 ECS（instance_id、public_ip 有效），则跳过完整 apply，但仍对安全组规则做定向 apply 以同步 ssh_allowed_cidr 等
	instanceID, publicIP, skipApply := d.tryExistingOutputs(ctx, tfDir)
	if skipApply {
		fmt.Fprintln(os.Stderr, "deploy-engine: 检测到已有 ECS/K3s，跳过完整 Terraform apply；正在同步安全组规则（ssh_allowed_cidr/出口 IP）...")
		tfVarsAbs, _ := filepath.Abs(tfvars)
		var merged *config.LayerConfig
		if cfg != nil && cfg.Merged != nil {
			merged = cfg.Merged
		}
		mergedVars := config.ToAliyunTerraformVars(merged, d.EnvID, instancePassword, d.Project)
		configFilePath := filepath.Join(d.configRoot(), config.DeriveConfigFile(d.Project, d.EnvID))
		if configFilePath != "" {
			mergedVars.ConfigFile = configFilePath
		}
		tmpFile, err := os.CreateTemp("", "deploy-engine-*.tfvars")
		if err == nil {
			tmpPath := tmpFile.Name()
			defer os.Remove(tmpPath)
			_ = config.WriteAliyunTerraformVarsToFile(mergedVars, tmpPath)
			regionVal := regionFromTfvars(tfvars)
			if regionVal == "" {
				regionVal = mergedVars.Region
			}
			sgArgs := []string{"apply", "-refresh=false", "-auto-approve",
				"-target=module.security.alicloud_security_group_rule.ssh[0]",
				"-target=module.security.alicloud_security_group_rule.k8s_api[0]",
				"-var-file=" + tmpPath, "-var-file=" + tfVarsAbs, "-var=env_id=" + d.EnvID}
			if regionVal != "" {
				sgArgs = append(sgArgs, "-var=region="+regionVal)
			}
			applyEnv := map[string]string{}
			if regionVal != "" {
				applyEnv["ALICLOUD_REGION"] = regionVal
			}
			if p := d.projectTfvarsPath(); p != "" {
				if _, err := os.Stat(p); err == nil {
					// 在 -var-file=tfVarsAbs 前插入 project tfvars，与完整 apply 顺序一致
					newArgs := append([]string{}, sgArgs[:6]...) // apply + 2×-target + -var-file=tmpPath
					newArgs = append(newArgs, "-var-file="+p)
					newArgs = append(newArgs, sgArgs[6:]...)
					sgArgs = newArgs
				}
			}
			if err := d.runTerraform(ctx, tfDir, sgArgs, applyEnv); err != nil {
				fmt.Fprintf(os.Stderr, "deploy-engine: 安全组规则同步失败（可忽略后重试 kubeconfig）: %v\n", err)
			}
		}
		fmt.Fprintln(os.Stderr, "deploy-engine: 继续获取 kubeconfig...")
	} else {
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
		// 确保 tfvars 中的 region 显式传入，覆盖 Merged 与 TF_VAR_region，避免被环境变量或错误地域覆盖
		regionVal := regionFromTfvars(tfvars)
		if regionVal == "" {
			regionVal = mergedVars.Region
		}
		if regionVal != "" {
			applyArgs = append(applyArgs, "-var=region="+regionVal)
			fmt.Fprintf(os.Stderr, "deploy-engine: 使用地域 region=%s（来自 tfvars 或 deploy 配置，将覆盖 TF_VAR_region）\n", regionVal)
		}
		// 确保 tfvars 中的 disk_category 显式传入，覆盖 Merged 与 TF_VAR_disk_category（IoOptimized 实例仅支持 cloud_efficiency/cloud_ssd）
		diskFromTfvars := diskCategoryFromTfvars(tfvars)
		diskCategoryVal := diskFromTfvars
		if diskCategoryVal == "" {
			diskCategoryVal = mergedVars.DiskCategory
		}
		if diskCategoryVal != "" {
			applyArgs = append(applyArgs, "-var=disk_category="+diskCategoryVal)
			fmt.Fprintf(os.Stderr, "deploy-engine: 使用系统盘类型 disk_category=%s（来自 tfvars 或 deploy 配置）\n", diskCategoryVal)
		}

		// #region agent log
		agentLog("driver.go:Up:before-apply", "calling terraform apply", "H1", map[string]interface{}{"tfDir": tfDir})
		// #endregion
		// 强制子进程 ALICLOUD_REGION，避免宿主机环境变量覆盖 var.region 导致请求发往错误地域（如 cn-beijing）
		applyEnv := map[string]string{}
		if regionVal != "" {
			applyEnv["ALICLOUD_REGION"] = regionVal
		}
		if err := d.runTerraform(ctx, tfDir, applyArgs, applyEnv); err != nil {
			// #region agent log
			agentLog("driver.go:Up:after-apply", "terraform apply error", "H1", map[string]interface{}{"error": err.Error()})
			// #endregion
			return nil, fmt.Errorf("aliyun: terraform apply: %w", err)
		}
		// #region agent log
		agentLog("driver.go:Up:after-apply", "terraform apply ok", "H1", nil)
		// #endregion

		var errOut error
		instanceID, errOut = d.terraformOutput(ctx, tfDir, "instance_id")
		// #region agent log
		agentLog("driver.go:Up:terraformOutput-instance_id", "terraform output instance_id", "H2", map[string]interface{}{"err": errOut != nil, "instanceID": instanceID})
		// #endregion
		if errOut != nil {
			return nil, fmt.Errorf("aliyun: terraform output instance_id: %w", errOut)
		}
		publicIP, errOut = d.terraformOutput(ctx, tfDir, "public_ip")
		if errOut != nil {
			return nil, fmt.Errorf("aliyun: terraform output public_ip: %w", errOut)
		}
		if publicIP == "" || publicIP == "Instance Released" {
			return nil, fmt.Errorf("aliyun: public_ip 无效，可能实例未就绪")
		}
	}

	// #region agent log
	agentLog("driver.go:Up:before-fetchKubeConfig", "calling fetchKubeConfig", "H3", nil)
	// #endregion
	if skipApply {
		fmt.Fprintln(os.Stderr, "deploy-engine: 正在获取 kubeconfig（等待 K3s 就绪，最多约 5 分钟）...")
	} else {
		fmt.Fprintln(os.Stderr, "deploy-engine: Terraform 已完成，正在等待 K3s 就绪并获取 kubeconfig（可能需数分钟）...")
	}
	os.Stderr.Sync()
	// 始终使用完整等待（60×5s），避免跳过 apply 时 24s 不足导致 K3s 未就绪
	kubeConfig, kubeErr := d.fetchKubeConfigWithOpts(ctx, false)
	// #region agent log
	agentLog("driver.go:Up:after-fetchKubeConfig", "fetchKubeConfig done", "H3", map[string]interface{}{"err": kubeErr != nil, "kubeConfigLen": len(kubeConfig)})
	// #endregion
	if kubeErr != nil {
		return nil, fmt.Errorf("aliyun: 获取 kubeconfig 失败: %w", kubeErr)
	}
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
	fullDestroy := strings.ToLower(os.Getenv("FULL_DESTROY")) == "1" || strings.ToLower(os.Getenv("FULL_DESTROY")) == "true"
	if !fullDestroy {
		destroyArgs = append(destroyArgs, "-target=module.ecs")
	} else {
		fmt.Fprintln(os.Stderr, "deploy-engine: FULL_DESTROY=1，完整销毁（VPC/NAS/OSS/ECS 等），下次 deploy 将按 tfvars 的 region 重新创建")
	}
	destroyArgs = append(destroyArgs, "-var-file="+tfVarsAbs, "-var=env_id="+envID, "-var=project="+project, "-var=config_file="+configFileAbs)
	// destroy 必须使用 state 中资源的实际 region，否则 tfvars 改过 region 后 provider 会调用错误地域的 API 导致销毁失败
	if region := d.regionFromTerraformState(ctx, tfDir); region != "" {
		destroyArgs = append(destroyArgs, "-var=region="+region)
	} else if region := regionFromTfvars(tfvars); region != "" {
		destroyArgs = append(destroyArgs, "-var=region="+region)
	}
	destroyArgs = append(destroyArgs, "-auto-approve")
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

// runTerraform 执行 terraform 命令。envOverrides 非空时合并进子进程环境（用于强制 ALICLOUD_REGION 等，避免宿主机环境覆盖 tfvars）。
func (d *Driver) runTerraform(ctx context.Context, tfDir string, args []string, envOverrides map[string]string) error {
	cmd := exec.CommandContext(ctx, "terraform", args...)
	cmd.Dir = tfDir
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if len(envOverrides) > 0 {
		env := os.Environ()
		overridden := make(map[string]bool)
		for _, e := range env {
			if idx := strings.IndexByte(e, '='); idx > 0 {
				overridden[e[:idx]] = true
			}
		}
		for k, v := range envOverrides {
			if !overridden[k] {
				env = append(env, k+"="+v)
			} else {
				for i, e := range env {
					if strings.HasPrefix(e, k+"=") {
						env[i] = k + "=" + v
						break
					}
				}
			}
		}
		cmd.Env = env
	}
	return cmd.Run()
}

// resourceInState 检查 state list 中是否包含指定资源地址（子串匹配）。
func (d *Driver) resourceInState(ctx context.Context, tfDir, resourceSubstr string) bool {
	cmd := exec.CommandContext(ctx, "terraform", "state", "list")
	cmd.Dir = tfDir
	out, err := cmd.Output()
	if err != nil {
		return false
	}
	return strings.Contains(string(out), resourceSubstr)
}

func (d *Driver) runTerraformStateRm(ctx context.Context, tfDir, resource string) error {
	if !d.resourceInState(ctx, tfDir, resource) {
		return nil
	}
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
	return d.fetchKubeConfigWithOpts(ctx, false)
}

// fetchKubeConfigWithOpts 拉取 kubeconfig。skipLongWait=true 时通过环境变量让脚本缩短「等待 K3s」重试（适用于已有 ECS 的场景）。
// 脚本 stderr 经管道逐行读到 os.Stderr 并 Sync，确保在 make/非 TTY 下进度实时可见。
func (d *Driver) fetchKubeConfigWithOpts(ctx context.Context, skipLongWait bool) ([]byte, error) {
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
	cmd.Stdout = os.Stdout
	stderrPipe, err := cmd.StderrPipe()
	if err != nil {
		return nil, fmt.Errorf("get-kubeconfig.sh StderrPipe: %w", err)
	}
	// 已有 ECS 时给 K3s 约 24s 窗口（12 次 × 2s），避免 3 次过短导致误报未就绪
	if skipLongWait {
		cmd.Env = append(os.Environ(), "KUBECONFIG_MAX_RETRIES=12", "KUBECONFIG_SLEEP_SEC=2")
	}
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("get-kubeconfig.sh Start: %w", err)
	}
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		sc := bufio.NewScanner(stderrPipe)
		for sc.Scan() {
			fmt.Fprintln(os.Stderr, sc.Text())
			os.Stderr.Sync()
		}
	}()
	if err := cmd.Wait(); err != nil {
		return nil, fmt.Errorf("get-kubeconfig.sh: %w", err)
	}
	wg.Wait()
	return os.ReadFile(d.kubeconfigPath())
}
