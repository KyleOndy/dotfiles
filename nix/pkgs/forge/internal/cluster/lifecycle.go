package cluster

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/kyleondy/dotfiles/forge/internal/ui"
)

// EnsureCluster brings one cluster to a usable state:
//  1. Kind-create the cluster (if absent)
//  2. Connect every node to the forge Docker network
//  3. Write containerd hosts.toml so image pulls route through mirrors
//  4. Install MetalLB + apply the per-cluster IP pool (if configured)
//  5. Patch CoreDNS to forward forge.test → forge-dns
//
// Idempotent end-to-end. Writes the kubeconfig to
// <kubeconfigDir>/<cluster.Name>. `networkName` must already exist on the
// host; `dnsIP` should be reachable from inside the cluster (typically the
// forge-dns container's static IP on the forge network).
func EnsureCluster(ctx context.Context, exe Executor, kubeconfigDir, networkName, dnsIP string, mirrors []Mirror, c Cluster) error {
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
	if err := EnsureMetalLB(ctx, exe, kubeconfigDir, c); err != nil {
		return err
	}
	if dnsIP != "" {
		if err := PatchCoreDNS(ctx, exe, kubeconfigDir, c.Name, dnsIP); err != nil {
			return err
		}
	}
	return nil
}

// EnsureAllClusters ensures every cluster in cfg is bring-up ready. Serial
// for now — step 7 swaps in the DAG-based parallel orchestrator.
func EnsureAllClusters(ctx context.Context, exe Executor, cfg *Config) error {
	dir := cfg.ExpandedKubeconfigDir()
	for _, c := range cfg.AllClusters() {
		if err := EnsureCluster(ctx, exe, dir, cfg.Network.Name, cfg.DNS.IP, cfg.Mirrors, c.Cluster); err != nil {
			return err
		}
	}
	return nil
}
