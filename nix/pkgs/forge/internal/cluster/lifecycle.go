package cluster

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/kyleondy/dotfiles/forge/internal/ui"
)

// EnsureCluster brings up one cluster if it does not already exist. Writes
// the cluster's kubeconfig to <kubeconfigDir>/<cluster.Name>. Idempotent.
//
// v1 scope: Kind creation + kubeconfig export only. Network attachment,
// mirrors, MetalLB, DNS, and components are layered in by higher-level
// wiring as those features are ported.
func EnsureCluster(ctx context.Context, exe Executor, kubeconfigDir string, c Cluster) error {
	if err := os.MkdirAll(kubeconfigDir, 0o755); err != nil {
		return fmt.Errorf("kubeconfig dir %s: %w", kubeconfigDir, err)
	}
	exists, err := KindClusterExists(ctx, exe, c.Name)
	if err != nil {
		return err
	}
	if exists {
		ui.L().Info("cluster %s already exists, skipping", c.Name)
		return nil
	}
	ui.L().Info("creating cluster %s (this takes ~30s)…", c.Name)
	kubeconfigPath := filepath.Join(kubeconfigDir, c.Name)
	kindConfig := RenderKindConfig(c)
	if err := KindCreateCluster(ctx, exe, c.Name, kindConfig, kubeconfigPath); err != nil {
		return err
	}
	ui.L().Info("created cluster %s (kubeconfig: %s)", c.Name, kubeconfigPath)
	return nil
}

// EnsureAllClusters ensures every cluster in cfg exists, serially. Step 7
// swaps in the DAG-based parallel orchestrator; serial is fine for v1 dev
// work and makes failures easier to read.
func EnsureAllClusters(ctx context.Context, exe Executor, cfg *Config) error {
	dir := cfg.ExpandedKubeconfigDir()
	for _, c := range cfg.AllClusters() {
		if err := EnsureCluster(ctx, exe, dir, c.Cluster); err != nil {
			return err
		}
	}
	return nil
}
