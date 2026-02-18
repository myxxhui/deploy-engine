// Package helm 提供 Helm install/upgrade 的 CLI 封装，供编排层 StepDeploy 使用。
package helm

import (
	"context"
	"fmt"
	"os"
	"os/exec"

	"gopkg.in/yaml.v3"
)

// InstallUpgradeOptions 执行 helm upgrade --install 的选项。
type InstallUpgradeOptions struct {
	KubeConfig  []byte
	ReleaseName string
	Namespace   string
	ChartPath   string
	ChartRepo   string
	ChartName   string
	Values      map[string]any
	ValuesFiles []string
}

// InstallUpgrade 执行 helm upgrade --install；若 ChartPath 非空则使用本地路径，否则使用 ChartRepo+ChartName（会先 helm repo add）。
func InstallUpgrade(ctx context.Context, opts InstallUpgradeOptions) error {
	if opts.ReleaseName == "" || opts.Namespace == "" {
		return fmt.Errorf("helm: release_name 与 namespace 必填")
	}
	var chartRef string
	if opts.ChartPath != "" {
		chartRef = opts.ChartPath
	} else if opts.ChartRepo != "" && opts.ChartName != "" {
		chartRef = opts.ChartName
		// 可选：helm repo add 临时 repo 再 install；为简化，要求 ChartName 已包含 repo 名（如 bitnami/nginx）或 ChartRepo 为 URL 时先 add
		if opts.ChartRepo != "" && !isScopedChart(opts.ChartName) {
			repoName := "deploy-engine-repo"
			if err := runHelm(ctx, opts.KubeConfig, "repo", "add", repoName, opts.ChartRepo); err != nil {
				return fmt.Errorf("helm repo add: %w", err)
			}
			chartRef = repoName + "/" + opts.ChartName
		}
	} else {
		return fmt.Errorf("helm: 需指定 chart_path 或 chart_repo_url+chart_name")
	}

	args := []string{"upgrade", "--install", opts.ReleaseName, chartRef, "-n", opts.Namespace, "--create-namespace"}

	for _, f := range opts.ValuesFiles {
		if f != "" {
			args = append(args, "-f", f)
		}
	}
	if len(opts.Values) > 0 {
		tmp, err := os.CreateTemp("", "deploy-engine-values-*.yaml")
		if err != nil {
			return fmt.Errorf("helm: 创建临时 values 文件: %w", err)
		}
		defer os.Remove(tmp.Name())
		enc := yaml.NewEncoder(tmp)
		if err := enc.Encode(opts.Values); err != nil {
			return fmt.Errorf("helm: 写入 values: %w", err)
		}
		if err := tmp.Close(); err != nil {
			return err
		}
		args = append(args, "-f", tmp.Name())
	}

	return runHelm(ctx, opts.KubeConfig, args...)
}

func isScopedChart(name string) bool {
	for i := 0; i < len(name); i++ {
		if name[i] == '/' {
			return true
		}
	}
	return false
}

func runHelm(ctx context.Context, kubeConfig []byte, args ...string) error {
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

	cmd := exec.CommandContext(ctx, "helm", args...)
	cmd.Env = append(os.Environ(), "KUBECONFIG="+tmpKube.Name())
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("helm %v: %w", args, err)
	}
	return nil
}
