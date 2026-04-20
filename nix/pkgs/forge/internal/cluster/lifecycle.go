package cluster

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/kyleondy/dotfiles/forge/internal/ui"
)

// EnsureCluster brings one cluster to a usable state: Kind-created,
// connected to the forge network, and configured to pull images through
// the forge mirrors. Writes the cluster's kubeconfig to
// <kubeconfigDir>/<cluster.Name>. Idempotent — each sub-step is a no-op
// when already applied.
//
// `mirrors` may be empty (step-3 minimal case), in which case no
// containerd hosts.toml is written. `networkName` must already exist on
// the host — EnsureNetwork should be called first.
func EnsureCluster(ctx context.Context, exe Executor, kubeconfigDir, networkName string, mirrors []Mirror, c Cluster) error {
	if err := os.MkdirAll(kubeconfigDir, 0o755); err != nil {
		return fmt.Errorf("kubeconfig dir %s: %w", kubeconfigDir, err)
	}
	exists, err := KindClusterExists(ctx, exe, c.Name)
	if err != nil {
		return err
	}
	if !exists {
		ui.L().Info("creating cluster %s (this takes ~30s)…", c.Name)
		kubeconfigPath := filepath.Join(kubeconfigDir, c.Name)
		kindConfig := RenderKindConfig(c)
		if err := KindCreateCluster(ctx, exe, c.Name, kindConfig, kubeconfigPath); err != nil {
			return err
		}
		ui.L().Info("created cluster %s (kubeconfig: %s)", c.Name, kubeconfigPath)
	} else {
		ui.L().Info("cluster %s already exists, skipping create", c.Name)
	}
	if err := ConnectClusterToNetwork(ctx, exe, networkName, c.Name); err != nil {
		return err
	}
	if err := ConfigureNodeMirrors(ctx, exe, c.Name, mirrors); err != nil {
		return err
	}
	return nil
}

// EnsureAllClusters ensures every cluster in cfg exists, connected to the
// forge network, and configured for mirrors. Serial — the DAG-based
// parallel orchestrator lands in step 7.
func EnsureAllClusters(ctx context.Context, exe Executor, cfg *Config) error {
	dir := cfg.ExpandedKubeconfigDir()
	for _, c := range cfg.AllClusters() {
		if err := EnsureCluster(ctx, exe, dir, cfg.Network.Name, cfg.Mirrors, c.Cluster); err != nil {
			return err
		}
	}
	return nil
}
