// Package ossstate 将 deploy-engine 本地 state 文件（.deploy/state-<project>-<env>.json）
// 自动同步到阿里云 OSS，实现多机共享「down 凭证」。
//
// OSS 路径约定（与 Terraform remote state 同一 bucket、同一前缀目录）：
//   oss://<bucket>/<project>/<env>/deploy-state.json
//   oss://<bucket>/<project>/<env>/terraform.tfstate  ← Terraform 管理，本包不碰
//
// 配置（环境变量）：
//   ALICLOUD_ACCESS_KEY   阿里云 AK（与 Terraform 共用，必填）
//   ALICLOUD_SECRET_KEY   阿里云 SK（与 Terraform 共用，必填）
//   STATE_OSS_BUCKET      存储桶，默认 deploy-engine-k3s-storage
//   STATE_OSS_REGION      地域，默认 cn-hongkong
//
// 降级策略：凭证缺失或网络异常时打印 [ossstate warn] 并继续，不阻断主流程。
package ossstate

import (
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/aliyun/aliyun-oss-go-sdk/oss"
)

const (
	defaultBucket = "deploy-engine-k3s-storage"
	defaultRegion = "cn-hongkong"
	stateObjName  = "deploy-state.json"
)

// objectKey 返回 OSS 对象路径：<project>/<env>/deploy-state.json
func objectKey(project, env string) string {
	return fmt.Sprintf("%s/%s/%s", project, env, stateObjName)
}

// newBucket 用环境变量中的凭证构造 OSS Bucket 客户端。
func newBucket() (*oss.Bucket, string, error) {
	ak := os.Getenv("ALICLOUD_ACCESS_KEY")
	sk := os.Getenv("ALICLOUD_SECRET_KEY")
	if ak == "" || sk == "" {
		return nil, "", fmt.Errorf("ALICLOUD_ACCESS_KEY / ALICLOUD_SECRET_KEY 未设置")
	}
	bucket := os.Getenv("STATE_OSS_BUCKET")
	if bucket == "" {
		bucket = defaultBucket
	}
	region := os.Getenv("STATE_OSS_REGION")
	if region == "" {
		region = defaultRegion
	}
	endpoint := fmt.Sprintf("https://oss-%s.aliyuncs.com", region)
	client, err := oss.New(endpoint, ak, sk)
	if err != nil {
		return nil, "", fmt.Errorf("创建 OSS 客户端失败: %w", err)
	}
	bkt, err := client.Bucket(bucket)
	if err != nil {
		return nil, "", fmt.Errorf("获取 bucket %s 失败: %w", bucket, err)
	}
	return bkt, bucket, nil
}

// Upload 将本地 state 文件上传到 OSS（幂等，覆盖写）。
// 若 AK/SK 未设置或上传失败，打印警告并返回 nil（不阻断主流程）。
func Upload(project, env, localPath string) error {
	bkt, bucket, err := newBucket()
	if err != nil {
		fmt.Fprintf(os.Stderr, "[ossstate warn] 凭证缺失，跳过 state 上传: %v\n", err)
		return nil
	}
	key := objectKey(project, env)
	if err := bkt.PutObjectFromFile(key, localPath); err != nil {
		fmt.Fprintf(os.Stderr, "[ossstate warn] 上传 state 到 OSS 失败 (oss://%s/%s): %v\n", bucket, key, err)
		return nil
	}
	fmt.Fprintf(os.Stderr, "[ossstate] ✅ state 已上传 → oss://%s/%s\n", bucket, key)
	return nil
}

// Download 从 OSS 下载 state 文件到本地路径，若对象不存在返回 ErrNotExist。
func Download(project, env, localPath string) error {
	bkt, bucket, err := newBucket()
	if err != nil {
		return fmt.Errorf("ossstate: 凭证缺失: %w", err)
	}
	key := objectKey(project, env)

	// 检查对象是否存在
	exists, err := bkt.IsObjectExist(key)
	if err != nil {
		return fmt.Errorf("ossstate: 检查 OSS 对象失败 (oss://%s/%s): %w", bucket, key, err)
	}
	if !exists {
		return os.ErrNotExist
	}

	// 下载到临时文件再原子 rename，防止下载中断导致文件损坏
	tmpPath := localPath + ".tmp"
	if err := os.MkdirAll(filepath.Dir(localPath), 0755); err != nil {
		return fmt.Errorf("ossstate: 创建目录失败: %w", err)
	}
	result, err := bkt.GetObject(key)
	if err != nil {
		return fmt.Errorf("ossstate: 下载 state 失败 (oss://%s/%s): %w", bucket, key, err)
	}
	defer result.Close()

	f, err := os.Create(tmpPath)
	if err != nil {
		return fmt.Errorf("ossstate: 创建临时文件失败: %w", err)
	}
	if _, err := io.Copy(f, result); err != nil {
		f.Close()
		os.Remove(tmpPath)
		return fmt.Errorf("ossstate: 写入临时文件失败: %w", err)
	}
	f.Close()
	if err := os.Rename(tmpPath, localPath); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("ossstate: 重命名临时文件失败: %w", err)
	}
	fmt.Fprintf(os.Stderr, "[ossstate] ✅ state 已从 OSS 恢复 → %s (oss://%s/%s)\n", localPath, bucket, key)
	return nil
}

// Delete 删除 OSS 上的 state 文件（destroy 成功后调用）。
// 若文件不存在或删除失败，打印警告并继续（不阻断主流程）。
func Delete(project, env string) error {
	bkt, bucket, err := newBucket()
	if err != nil {
		fmt.Fprintf(os.Stderr, "[ossstate warn] 凭证缺失，跳过 state 删除: %v\n", err)
		return nil
	}
	key := objectKey(project, env)
	if err := bkt.DeleteObject(key); err != nil {
		fmt.Fprintf(os.Stderr, "[ossstate warn] 删除 OSS state 失败 (oss://%s/%s): %v\n", bucket, key, err)
		return nil
	}
	fmt.Fprintf(os.Stderr, "[ossstate] ✅ OSS state 已删除 (oss://%s/%s)\n", bucket, key)
	return nil
}
