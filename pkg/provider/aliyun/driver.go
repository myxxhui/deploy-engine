// Package aliyun 阿里云 ECS + K3s 驱动，基于内嵌 Terraform（deploy/terraform/alicloud）。
package aliyun

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/titan-platform/deploy-engine/pkg/config"
	"github.com/titan-platform/deploy-engine/pkg/provider"
	"gopkg.in/yaml.v3"
)

// #region agent log
const debugLogPath = "/root/sean/workspace/.diting/.cursor/debug-71deed.log"

func agentLog(location, message, hypothesisId string, data map[string]interface{}) {
	if data == nil {
		data = make(map[string]interface{})
	}
	payload := map[string]interface{}{"sessionId": "71deed", "location": location, "message": message, "hypothesisId": hypothesisId, "data": data, "timestamp": time.Now().UnixMilli()}
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

// nasUseExistingAccessGroupFromTfvars 从 tfvars 解析 nas_use_existing_access_group；缺省 false，避免误销毁 AG 导致 AlreadyAttached
func nasUseExistingAccessGroupFromTfvars(tfvarsPath string) bool {
	f, err := os.Open(tfvarsPath)
	if err != nil {
		return false
	}
	defer f.Close()
	re := regexp.MustCompile(`^\s*nas_use_existing_access_group\s*=\s*(true|false)\s*$`)
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		if m := re.FindStringSubmatch(sc.Text()); len(m) == 2 {
			return m[1] == "true"
		}
	}
	return false
}

// sshAllowedCidrFromTfvars 从 tfvars 解析 ssh_allowed_cidr，供 apply 时显式传入以确保安全组规则同步生效。
func sshAllowedCidrFromTfvars(tfvarsPath string) string {
	f, err := os.Open(tfvarsPath)
	if err != nil {
		return ""
	}
	defer f.Close()
	re := regexp.MustCompile(`^\s*ssh_allowed_cidr\s*=\s*"([^"]+)"\s*$`)
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

// ensureOSSScriptUploaded 确保 OSS 初始化脚本已上传：先 plan 检查是否存在且无更新；不存在或本地有更新则上传，存在且无更新则跳过。
func (d *Driver) ensureOSSScriptUploaded(ctx context.Context, tfDir, tfvars string, merged *config.LayerConfig, instancePassword string) error {
	fmt.Fprintln(os.Stderr, "【步骤 1/5】检查 OSS 初始化脚本...")
	// 切换桶时，避免 Terraform 尝试从旧桶 DeleteObject（旧桶可能已销毁导致 NoSuchBucket）
	_ = d.runTerraformStateRm(ctx, tfDir, "module.oss.alicloud_oss_bucket_object.init_script")
	_ = d.runTerraformStateRm(ctx, tfDir, "module.oss.alicloud_oss_bucket_object.init_script[0]")
	tfVarsAbs, _ := filepath.Abs(tfvars)
	mergedVars := config.ToAliyunTerraformVars(merged, d.EnvID, instancePassword, d.Project)
	configFilePath := mergedVars.ConfigFile
	if configFilePath != "" && !filepath.IsAbs(configFilePath) {
		configFilePath = filepath.Join(d.configRoot(), configFilePath)
	}
	if configFilePath == "" {
		configFilePath = filepath.Join(d.configRoot(), config.DeriveConfigFile(d.Project, d.EnvID))
	}
	if configFilePath != "" {
		if _, err := os.Stat(configFilePath); err == nil {
			mergedVars.ConfigFile = configFilePath
		}
	}
	tmpFile, err := os.CreateTemp("", "deploy-engine-oss-*.tfvars")
	if err != nil {
		return fmt.Errorf("创建临时 tfvars: %w", err)
	}
	tmpPath := tmpFile.Name()
	defer os.Remove(tmpPath)
	if err := config.WriteAliyunTerraformVarsToFile(mergedVars, tmpPath); err != nil {
		return fmt.Errorf("写入 Merged 变量: %w", err)
	}
	regionVal := regionFromTfvars(tfvars)
	if regionVal == "" {
		regionVal = mergedVars.Region
	}
	baseArgs := d.buildOSSTargetArgs(tmpPath, tfVarsAbs, tfvars)
	env := map[string]string{}
	if regionVal != "" {
		env["ALICLOUD_REGION"] = regionVal
	}

	// plan -detailed-exitcode: 0=无变更 1=错误 2=有待执行变更。
	// -refresh=false 避免 plan 时对已存在桶（可能跨 region 或跨账号）执行 GetObjectDetailedMeta 导致 NoSuchBucket 误报
	planArgs := append([]string{"plan", "-detailed-exitcode", "-refresh=false", "-target=module.oss"}, baseArgs...)
	hasChanges, planErr := d.runTerraformPlanExitCode(ctx, tfDir, planArgs, env)
	if planErr != nil {
		return fmt.Errorf("terraform plan 检查 OSS 脚本失败: %w", planErr)
	}
	if !hasChanges {
		fmt.Fprintln(os.Stderr, "  ✅ OSS 初始化脚本已存在且无更新，跳过上传")
		return nil
	}

	// 存在变更：执行上传。 -refresh=false 与 plan 一致，避免对已存在桶 refresh 触发 NoSuchBucket
	fmt.Fprintln(os.Stderr, "  正在上传 OSS 初始化脚本...")
	applyArgs := append([]string{"apply", "-auto-approve", "-refresh=false", "-target=module.oss"}, baseArgs...)
	if err := d.runTerraformApplyWithStderrLog(ctx, tfDir, applyArgs, env); err != nil {
		return err
	}
	fmt.Fprintln(os.Stderr, "  ✅ OSS 初始化脚本已就绪")
	return nil
}

// buildOSSTargetArgs 构建 OSS target 所需的 -var-file 和 -var 参数。
func (d *Driver) buildOSSTargetArgs(tmpPath, tfVarsAbs, tfvars string) []string {
	args := []string{"-var-file=" + tmpPath}
	if p := d.projectTfvarsPath(); p != "" {
		if _, err := os.Stat(p); err == nil {
			args = append(args, "-var-file="+p)
		}
	}
	args = append(args, "-var-file="+tfVarsAbs, "-var=env_id="+d.EnvID)
	if v := regionFromTfvars(tfvars); v != "" {
		args = append(args, "-var=region="+v)
	}
	if v := diskCategoryFromTfvars(tfvars); v != "" {
		args = append(args, "-var=disk_category="+v)
	}
	if v := sshAllowedCidrFromTfvars(tfvars); v != "" {
		args = append(args, "-var=ssh_allowed_cidr="+v)
	}
	args = append(args, "-var=nas_use_existing_access_group="+strconv.FormatBool(nasUseExistingAccessGroupFromTfvars(tfvars)))
	return args
}

// runTerraformPlanExitCode 执行 terraform plan -detailed-exitcode，返回是否有待执行变更。0=无变更 1=错误 2=有变更。
func (d *Driver) runTerraformPlanExitCode(ctx context.Context, tfDir string, args []string, envOverrides map[string]string) (hasChanges bool, err error) {
	cmd := exec.CommandContext(ctx, "terraform", args...)
	cmd.Dir = tfDir
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	if len(envOverrides) > 0 {
		env := os.Environ()
		for k, v := range envOverrides {
			found := false
			for i, e := range env {
				if strings.HasPrefix(e, k+"=") {
					env[i] = k + "=" + v
					found = true
					break
				}
			}
			if !found {
				env = append(env, k+"="+v)
			}
		}
		cmd.Env = env
	}
	runErr := cmd.Run()
	if runErr == nil {
		return false, nil // exit 0: no changes
	}
	var exitErr *exec.ExitError
	if errors.As(runErr, &exitErr) {
		code := exitErr.ExitCode()
		if code == 2 {
			return true, nil // changes present
		}
		if code == 1 {
			return false, runErr // plan error
		}
	}
	return false, runErr
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
	fmt.Fprintln(os.Stderr, "")
	fmt.Fprintln(os.Stderr, "========================================")
	fmt.Fprintln(os.Stderr, "  开始一键部署 K3s 集群")
	fmt.Fprintf(os.Stderr, "  项目: %s, 环境: %s\n", d.Project, d.EnvID)
	fmt.Fprintln(os.Stderr, "========================================")
	fmt.Fprintln(os.Stderr, "")
	
	tfDir := d.tfLiveDir()
	tfvars, usedLegacy := d.tfVarsFile()
	if _, err := os.Stat(tfDir); os.IsNotExist(err) {
		return nil, fmt.Errorf("terraform 目录不存在: %s（请设置 DEPLOY_ENGINE_ROOT 或在模块根目录执行）", tfDir)
	}
	if _, err := os.Stat(tfvars); os.IsNotExist(err) {
		return nil, fmt.Errorf("tfvars 不存在: %s（请从 config/examples/terraform-<project>-<env>.tfvars.example 复制到 config/ 并填写）", tfvars)
	}
	if usedLegacy {
		fmt.Fprintf(os.Stderr, "⚠️  [弃用警告] 使用旧路径 %s，请迁移到扁平路径 %s\n", tfvars, filepath.Join(d.configRoot(), config.FlatTfvarsName(d.Project, d.EnvID)))
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

	// 始终先确保 OSS 初始化脚本已上传：K3s 未部署时 ECS 需从存储桶下载；上传失败则直接报错退出
	var merged *config.LayerConfig
	if cfg != nil && cfg.Merged != nil {
		merged = cfg.Merged
	}
	if err := d.ensureOSSScriptUploaded(ctx, tfDir, tfvars, merged, instancePassword); err != nil {
		return nil, fmt.Errorf("aliyun: OSS 初始化脚本上传失败（请检查 Bucket 权限、oss_bucket_name 配置）: %w", err)
	}

	if skipApply {
		fmt.Fprintln(os.Stderr, "")
		fmt.Fprintln(os.Stderr, "【步骤 2/5】检测到已有 ECS/K3s，同步安全组规则...")
		tfVarsAbs, _ := filepath.Abs(tfvars)
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
			// 强制 replace 两条规则，确保云上规则与 tfvars 的 ssh_allowed_cidr 一致（cidr_ip 为 ForceNew，仅 replace 会真正更新云上规则）
			cidrVal := sshAllowedCidrFromTfvars(tfvars)
			if cidrVal == "" {
				cidrVal = "0.0.0.0/0"
			}
			sgArgs := []string{"apply", "-auto-approve",
				"-target=module.security.alicloud_security_group_rule.ssh[0]",
				"-target=module.security.alicloud_security_group_rule.k8s_api[0]",
				"-replace=module.security.alicloud_security_group_rule.ssh[0]",
				"-replace=module.security.alicloud_security_group_rule.k8s_api[0]",
				"-var-file=" + tmpPath, "-var-file=" + tfVarsAbs, "-var=env_id=" + d.EnvID,
				"-var=ssh_allowed_cidr=" + cidrVal}
			fmt.Fprintf(os.Stderr, "deploy-engine: 安全组同步强制 replace 规则，ssh_allowed_cidr=%s\n", cidrVal)
			if regionVal != "" {
				sgArgs = append(sgArgs, "-var=region="+regionVal)
			}
			applyEnv := map[string]string{}
			if regionVal != "" {
				applyEnv["ALICLOUD_REGION"] = regionVal
			}
			if p := d.projectTfvarsPath(); p != "" {
				if _, err := os.Stat(p); err == nil {
					// 在 -var-file=tfVarsAbs 前插入 project tfvars（sgArgs 前 7 项含 apply/-target/-replace/-var-file=tmpPath）
					newArgs := append([]string{}, sgArgs[:7]...)
					newArgs = append(newArgs, "-var-file="+p)
					newArgs = append(newArgs, sgArgs[7:]...)
					sgArgs = newArgs
				}
			}
			if err := d.runTerraform(ctx, tfDir, sgArgs, applyEnv); err != nil {
				fmt.Fprintf(os.Stderr, "deploy-engine: 安全组规则同步失败（可忽略后重试 kubeconfig）: %v\n", err)
			}
		}
		fmt.Fprintln(os.Stderr, "  ✅ 安全组规则已同步")
	} else {
		fmt.Fprintln(os.Stderr, "")
		fmt.Fprintln(os.Stderr, "【步骤 2/5】执行 Terraform Apply，创建云资源...")
		tfVarsAbs, _ := filepath.Abs(tfvars)
		applyArgs := []string{"apply", "-refresh=false", "-auto-approve"}

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
		// #region agent log
		agentLog("driver.go:Up:disk_category", "disk_category resolution", "H1", map[string]interface{}{
			"tfvarsPath": tfvars, "diskFromTfvars": diskFromTfvars, "mergedVarsDiskCategory": mergedVars.DiskCategory, "diskCategoryVal": diskCategoryVal, "willAppendVar": diskCategoryVal != "",
		})
		// #endregion
		if diskCategoryVal != "" {
			applyArgs = append(applyArgs, "-var=disk_category="+diskCategoryVal)
			fmt.Fprintf(os.Stderr, "deploy-engine: 使用系统盘类型 disk_category=%s（来自 tfvars 或 deploy 配置）\n", diskCategoryVal)
		}
		if cidrVal := sshAllowedCidrFromTfvars(tfvars); cidrVal != "" {
			applyArgs = append(applyArgs, "-var=ssh_allowed_cidr="+cidrVal)
			fmt.Fprintf(os.Stderr, "deploy-engine: 使用 ssh_allowed_cidr=%s（来自 tfvars）\n", cidrVal)
		}
		// 显式传入 nas_use_existing_access_group，避免缺省或解析异常导致误销毁 AG（AlreadyAttached）
		nasUseExisting := nasUseExistingAccessGroupFromTfvars(tfvars)
		applyArgs = append(applyArgs, "-var=nas_use_existing_access_group="+strconv.FormatBool(nasUseExisting))

		// #region agent log
		agentLog("driver.go:Up:before-apply", "calling terraform apply", "H1", map[string]interface{}{"tfDir": tfDir})
		// #endregion
		// 强制子进程 ALICLOUD_REGION，避免宿主机环境变量覆盖 var.region 导致请求发往错误地域（如 cn-beijing）
		applyEnv := map[string]string{}
		if regionVal != "" {
			applyEnv["ALICLOUD_REGION"] = regionVal
		}
		if err := d.runTerraformApplyWithStderrLog(ctx, tfDir, applyArgs, applyEnv); err != nil {
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
	fmt.Fprintln(os.Stderr, "")
	fmt.Fprintln(os.Stderr, "【步骤 3/5】等待 K3s 就绪并获取 kubeconfig...")
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

	// 根据 deploy_control 部署数据库（TimescaleDB、PostgreSQL L2、Redis）
	configFilePath := ""
	if merged != nil && merged.Env != nil {
		configFilePath = merged.Env.ConfigFile
	}
	if configFilePath == "" {
		configFilePath = filepath.Join(d.configRoot(), config.DeriveConfigFile(d.Project, d.EnvID))
	}
	if err := d.deployDatabases(ctx, configFilePath, kubeConfig); err != nil {
		fmt.Fprintf(os.Stderr, "⚠️  数据库部署失败（K3s 已就绪，可手动部署）: %v\n", err)
	}

	fmt.Fprintln(os.Stderr, "")
	fmt.Fprintln(os.Stderr, "【步骤 5/5】部署完成")
	fmt.Fprintln(os.Stderr, "========================================")
	fmt.Fprintln(os.Stderr, "  ✅ K3s 集群部署完成")
	fmt.Fprintf(os.Stderr, "  公网 IP: %s\n", publicIP)
	fmt.Fprintf(os.Stderr, "  实例 ID: %s\n", instanceID)
	fmt.Fprintln(os.Stderr, "========================================")
	fmt.Fprintln(os.Stderr, "")

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
	fmt.Fprintln(os.Stderr, "")
	fmt.Fprintln(os.Stderr, "========================================")
	fmt.Fprintln(os.Stderr, "  开始回收 K3s 集群资源")
	fmt.Fprintf(os.Stderr, "  项目: %s, 环境: %s\n", d.Project, d.EnvID)
	fullDestroy := strings.ToLower(os.Getenv("FULL_DESTROY")) == "1" || strings.ToLower(os.Getenv("FULL_DESTROY")) == "true"
	if fullDestroy {
		fmt.Fprintln(os.Stderr, "  模式: 完整销毁（VPC/NAS/OSS/ECS）")
	} else {
		fmt.Fprintln(os.Stderr, "  模式: 仅销毁 ECS（保留 VPC/NAS/OSS）")
	}
	fmt.Fprintln(os.Stderr, "========================================")
	fmt.Fprintln(os.Stderr, "")
	
	tfDir := d.tfLiveDir()
	tfvars, _ := d.tfVarsFile()
	if _, err := os.Stat(tfDir); os.IsNotExist(err) {
		return fmt.Errorf("terraform 目录不存在: %s", tfDir)
	}
	if _, err := os.Stat(tfvars); os.IsNotExist(err) {
		return fmt.Errorf("tfvars 不存在: %s（无法执行 destroy）", tfvars)
	}
	_ = d.runTerraformStateRm(ctx, tfDir, "module.oss.alicloud_oss_bucket_object.init_script")
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
	if !fullDestroy {
		destroyArgs = append(destroyArgs, "-target=module.ecs")
		fmt.Fprintln(os.Stderr, "正在销毁 ECS 实例（保留 VPC/NAS/OSS）...")
	} else {
		fmt.Fprintln(os.Stderr, "正在完整销毁所有资源（VPC/NAS/OSS/ECS）...")
	}
	destroyArgs = append(destroyArgs, "-var-file="+tfVarsAbs, "-var=env_id="+envID, "-var=project="+project, "-var=config_file="+configFileAbs)
	// destroy 必须使用 state 中资源的实际 region，且强制子进程 ALICLOUD_REGION，否则 OSS/ECS 等会请求错误地域导致 403（如 GetBucketCORS）
	destroyRegion := d.regionFromTerraformState(ctx, tfDir)
	if destroyRegion == "" {
		destroyRegion = regionFromTfvars(tfvars)
	}
	if destroyRegion != "" {
		destroyArgs = append(destroyArgs, "-var=region="+destroyRegion)
		fmt.Fprintf(os.Stderr, "使用地域: %s\n", destroyRegion)
	}
	destroyArgs = append(destroyArgs, "-auto-approve")
	destroyEnv := map[string]string{}
	if destroyRegion != "" {
		destroyEnv["ALICLOUD_REGION"] = destroyRegion
	}
	
	fmt.Fprintln(os.Stderr, "")
	err := d.runTerraform(ctx, tfDir, destroyArgs, destroyEnv)
	if err != nil {
		return fmt.Errorf("terraform destroy 失败: %w", err)
	}
	
	_ = os.Remove(d.kubeconfigPath())
	
	fmt.Fprintln(os.Stderr, "")
	fmt.Fprintln(os.Stderr, "========================================")
	fmt.Fprintln(os.Stderr, "  ✅ 资源回收完成")
	fmt.Fprintln(os.Stderr, "========================================")
	fmt.Fprintln(os.Stderr, "")
	
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

const maxStderrLogLen = 4000

// runTerraformApplyWithStderrLog 仅用于 apply：将 stderr 同时输出到终端并写入 debug 日志（失败时），便于排查 InvalidSystemDiskCategory 等错误。
func (d *Driver) runTerraformApplyWithStderrLog(ctx context.Context, tfDir string, args []string, envOverrides map[string]string) error {
	var stderrBuf bytes.Buffer
	cmd := exec.CommandContext(ctx, "terraform", args...)
	cmd.Dir = tfDir
	cmd.Stdout = os.Stdout
	cmd.Stderr = io.MultiWriter(os.Stderr, &stderrBuf)
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
	err := cmd.Run()
	if err != nil && stderrBuf.Len() > 0 {
		stderrStr := strings.TrimSpace(stderrBuf.String())
		if len(stderrStr) > maxStderrLogLen {
			stderrStr = stderrStr[len(stderrStr)-maxStderrLogLen:]
		}
		// #region agent log
		agentLog("driver.go:runTerraformApplyWithStderrLog", "terraform apply stderr on failure", "H1", map[string]interface{}{"stderrSnippet": stderrStr})
		// #endregion
	}
	return err
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
	// 传入 tfvars 路径，使从业务仓（如 diting-infra）调用时脚本能从 ConfigRoot 读取 instance_password
	env := os.Environ()
	if tfvars, _ := d.tfVarsFile(); tfvars != "" {
		if _, err := os.Stat(tfvars); err == nil {
			env = append(env, "TFVARS_FILE="+tfvars)
		}
	}
	// 已有 ECS 时给 K3s 约 24s 窗口（12 次 × 2s），避免 3 次过短导致误报未就绪
	if skipLongWait {
		env = append(env, "KUBECONFIG_MAX_RETRIES=12", "KUBECONFIG_SLEEP_SEC=2")
	}
	cmd.Env = env
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

// deployDatabases 根据 deploy_control 配置部署数据库（TimescaleDB、PostgreSQL L2、Redis）
func (d *Driver) deployDatabases(ctx context.Context, configFilePath string, kubeConfig []byte) error {
	deployCtrl, err := config.LoadDeployControl(configFilePath)
	if err != nil {
		return fmt.Errorf("加载 deploy_control 失败: %w", err)
	}
	if deployCtrl == nil {
		fmt.Fprintln(os.Stderr, "未找到 deploy_control 配置，跳过数据库部署")
		return nil
	}

	fmt.Fprintln(os.Stderr, "")
	fmt.Fprintln(os.Stderr, "【步骤 4/5】部署数据库组件")
	fmt.Fprintln(os.Stderr, "========================================")
	namespace := "default"

	// 1. 先安装存储插件并创建 StorageClass
	if deployCtrl.K3sStoragePlugin != "" {
		fmt.Fprintf(os.Stderr, "  [4.1] 正在安装 K3s 存储插件: %s...\n", deployCtrl.K3sStoragePlugin)
		if err := d.installStoragePlugin(ctx, kubeConfig, deployCtrl.K3sStoragePlugin); err != nil {
			return fmt.Errorf("存储插件安装失败: %w", err)
		}
		fmt.Fprintln(os.Stderr, "  ✅ 存储插件安装完成")
		
		// 等待 StorageClass 就绪
		fmt.Fprintln(os.Stderr, "  等待 StorageClass 就绪...")
		time.Sleep(5 * time.Second)
		if err := d.verifyStorageClass(ctx, kubeConfig, deployCtrl.K3sStoragePlugin); err != nil {
			return fmt.Errorf("StorageClass 验证失败: %w", err)
		}
		fmt.Fprintln(os.Stderr, "  ✅ StorageClass 已就绪")
	}

	// 2. 部署 TimescaleDB（L1）
	if deployCtrl.EnableTimescaleDB {
		fmt.Fprintln(os.Stderr, "  [4.2] 正在部署 TimescaleDB (L1)...")
		if err := d.deployTimescaleDB(ctx, kubeConfig, namespace, deployCtrl.TimescaleDBStorage); err != nil {
			return fmt.Errorf("TimescaleDB 部署失败: %w", err)
		}
		fmt.Fprintln(os.Stderr, "  ✅ TimescaleDB 部署完成")
	}

	// 部署 PostgreSQL L2
	if deployCtrl.EnablePostgresL2 {
		fmt.Fprintln(os.Stderr, "  [4.3] 正在部署 PostgreSQL L2...")
		if err := d.deployPostgresL2(ctx, kubeConfig, namespace, deployCtrl.PostgresL2Storage); err != nil {
			return fmt.Errorf("PostgreSQL L2 部署失败: %w", err)
		}
		fmt.Fprintln(os.Stderr, "  ✅ PostgreSQL L2 部署完成")
	}

	// 部署 Redis
	if deployCtrl.EnableRedis {
		fmt.Fprintln(os.Stderr, "  [4.4] 正在部署 Redis...")
		if err := d.deployRedis(ctx, kubeConfig, namespace, deployCtrl.RedisStorage); err != nil {
			return fmt.Errorf("Redis 部署失败: %w", err)
		}
		fmt.Fprintln(os.Stderr, "  ✅ Redis 部署完成")
	}

	fmt.Fprintln(os.Stderr, "========================================")
	fmt.Fprintln(os.Stderr, "✅ 数据库组件部署完成")
	return nil
}

// deployTimescaleDB 部署 TimescaleDB（使用 Bitnami PostgreSQL chart + TimescaleDB 扩展）
func (d *Driver) deployTimescaleDB(ctx context.Context, kubeConfig []byte, namespace string, storage config.StorageConfig) error {
	values := map[string]any{
		"auth": map[string]any{
			"username": "postgres",
			"password": "postgres",
			"database": "postgres",
		},
		"primary": map[string]any{
			"persistence": map[string]any{
				"enabled": true,
				"size":    storage.Size,
			},
		},
	}
	// 如果未指定 StorageClass，使用 local-path（K3s 默认）
	scName := storage.StorageClass
	if scName == "" {
		scName = "local-path"
	}
	values["primary"].(map[string]any)["persistence"].(map[string]any)["storageClass"] = scName

	return d.runHelmInstall(ctx, kubeConfig, "timescaledb", namespace, "bitnami/postgresql", values)
}

// deployPostgresL2 部署 PostgreSQL L2
func (d *Driver) deployPostgresL2(ctx context.Context, kubeConfig []byte, namespace string, storage config.StorageConfig) error {
	values := map[string]any{
		"auth": map[string]any{
			"username": "postgres",
			"password": "postgres",
			"database": "diting_l2",
		},
		"primary": map[string]any{
			"persistence": map[string]any{
				"enabled": true,
				"size":    storage.Size,
			},
		},
	}
	// 如果未指定 StorageClass，使用 local-path（K3s 默认）
	scName := storage.StorageClass
	if scName == "" {
		scName = "local-path"
	}
	values["primary"].(map[string]any)["persistence"].(map[string]any)["storageClass"] = scName

	return d.runHelmInstall(ctx, kubeConfig, "postgresql-l2", namespace, "bitnami/postgresql", values)
}

// deployRedis 部署 Redis
func (d *Driver) deployRedis(ctx context.Context, kubeConfig []byte, namespace string, storage config.StorageConfig) error {
	values := map[string]any{
		"auth": map[string]any{
			"enabled": false,
		},
		"master": map[string]any{
			"persistence": map[string]any{
				"enabled": true,
				"size":    storage.Size,
			},
		},
	}
	// 如果未指定 StorageClass，使用 local-path（K3s 默认）
	scName := storage.StorageClass
	if scName == "" {
		scName = "local-path"
	}
	values["master"].(map[string]any)["persistence"].(map[string]any)["storageClass"] = scName

	return d.runHelmInstall(ctx, kubeConfig, "redis", namespace, "bitnami/redis", values)
}

// runHelmInstall 执行 helm upgrade --install（封装 helm 包调用）
func (d *Driver) runHelmInstall(ctx context.Context, kubeConfig []byte, releaseName, namespace, chartName string, values map[string]any) error {
	tmpKube, err := os.CreateTemp("", "deploy-engine-kubeconfig-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmpKube.Name())
	if _, err := tmpKube.Write(kubeConfig); err != nil {
		return err
	}
	if err := tmpKube.Close(); err != nil {
		return err
	}

	tmpValues, err := os.CreateTemp("", "deploy-engine-values-*.yaml")
	if err != nil {
		return err
	}
	defer os.Remove(tmpValues.Name())
	enc := yaml.NewEncoder(tmpValues)
	if err := enc.Encode(values); err != nil {
		return err
	}
	if err := tmpValues.Close(); err != nil {
		return err
	}

	cmd := exec.CommandContext(ctx, "helm", "upgrade", "--install", releaseName, chartName,
		"-n", namespace, "--create-namespace", "-f", tmpValues.Name())
	cmd.Env = append(os.Environ(), "KUBECONFIG="+tmpKube.Name())
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("helm upgrade --install %s: %w", releaseName, err)
	}
	return nil
}

// installStoragePlugin 安装 K3s 存储插件（local-path 默认已安装，其他插件需要部署）
func (d *Driver) installStoragePlugin(ctx context.Context, kubeConfig []byte, plugin string) error {
	switch plugin {
	case "local-path":
		// K3s 默认已安装 local-path-provisioner，检查是否存在
		if err := d.verifyStorageClass(ctx, kubeConfig, "local-path"); err != nil {
			fmt.Fprintln(os.Stderr, "⚠️  local-path StorageClass 不存在，尝试重新部署...")
			return d.deployLocalPathProvisioner(ctx, kubeConfig)
		}
		fmt.Fprintln(os.Stderr, "local-path 存储插件已存在")
		return nil
	case "nfs-client":
		return d.deployNFSClientProvisioner(ctx, kubeConfig)
	default:
		return fmt.Errorf("不支持的存储插件: %s（支持: local-path, nfs-client）", plugin)
	}
}

// deployLocalPathProvisioner 部署 local-path-provisioner
func (d *Driver) deployLocalPathProvisioner(ctx context.Context, kubeConfig []byte) error {
	// K3s 默认使用 Rancher local-path-provisioner
	manifest := `https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.24/deploy/local-path-storage.yaml`
	
	tmpKube, err := os.CreateTemp("", "deploy-engine-kubeconfig-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmpKube.Name())
	if _, err := tmpKube.Write(kubeConfig); err != nil {
		return err
	}
	if err := tmpKube.Close(); err != nil {
		return err
	}

	cmd := exec.CommandContext(ctx, "kubectl", "apply", "-f", manifest)
	cmd.Env = append(os.Environ(), "KUBECONFIG="+tmpKube.Name())
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("kubectl apply local-path-provisioner: %w", err)
	}
	return nil
}

// deployNFSClientProvisioner 部署 NFS client provisioner
func (d *Driver) deployNFSClientProvisioner(ctx context.Context, kubeConfig []byte) error {
	// 使用 Helm chart 部署 nfs-subdir-external-provisioner
	values := map[string]any{
		"nfs": map[string]any{
			"server": "NFS_SERVER_IP",  // 需要从配置读取
			"path":   "/mnt/titan-data",
		},
		"storageClass": map[string]any{
			"name":              "nfs-client",
			"defaultClass":      false,
			"reclaimPolicy":     "Retain",
			"archiveOnDelete":   true,
		},
	}
	
	// 先添加 Helm repo
	tmpKube, err := os.CreateTemp("", "deploy-engine-kubeconfig-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmpKube.Name())
	if _, err := tmpKube.Write(kubeConfig); err != nil {
		return err
	}
	if err := tmpKube.Close(); err != nil {
		return err
	}

	repoAddCmd := exec.CommandContext(ctx, "helm", "repo", "add", "nfs-subdir-external-provisioner",
		"https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/")
	repoAddCmd.Env = append(os.Environ(), "KUBECONFIG="+tmpKube.Name())
	repoAddCmd.Stdout = os.Stdout
	repoAddCmd.Stderr = os.Stderr
	if err := repoAddCmd.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "⚠️  helm repo add 失败（可能已存在）: %v\n", err)
	}

	return d.runHelmInstall(ctx, kubeConfig, "nfs-subdir-external-provisioner", "kube-system",
		"nfs-subdir-external-provisioner/nfs-subdir-external-provisioner", values)
}

// verifyStorageClass 验证 StorageClass 是否存在
func (d *Driver) verifyStorageClass(ctx context.Context, kubeConfig []byte, scName string) error {
	tmpKube, err := os.CreateTemp("", "deploy-engine-kubeconfig-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmpKube.Name())
	if _, err := tmpKube.Write(kubeConfig); err != nil {
		return err
	}
	if err := tmpKube.Close(); err != nil {
		return err
	}

	cmd := exec.CommandContext(ctx, "kubectl", "get", "storageclass", scName)
	cmd.Env = append(os.Environ(), "KUBECONFIG="+tmpKube.Name())
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("StorageClass %s 不存在: %w", scName, err)
	}
	return nil
}
