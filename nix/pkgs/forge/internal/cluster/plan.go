package cluster

import (
	"context"
	"fmt"
)

// BuildUpPlan composes the DAG of nodes `forge lab up` executes. Steps
// have three layers of parallelism:
//
//   - `network` is the single root (no deps).
//   - `dns` + every `mirror:<name>` run in parallel once network is up.
//   - Each `cluster:<name>` runs once network, dns, and every mirror have
//     succeeded. Clusters run in parallel with each other.
//
// Per-cluster work (Kind create → connect → containerd hosts.toml →
// MetalLB → CoreDNS patch → components) stays serial inside its cluster
// node. Splitting it further would let CoreDNS patches overlap with Kind
// creates on other clusters, but the wins are small and the current
// EnsureCluster is an easy-to-reason-about unit.
func BuildUpPlan(exe Executor, cfg *Config) []Step {
	dir := cfg.ExpandedKubeconfigDir()
	nodes := []Step{
		{
			ID:    "network",
			Label: fmt.Sprintf("ensure network %s", cfg.Network.Name),
			Fn: func(ctx context.Context) error {
				return EnsureNetwork(ctx, exe, cfg.Network.Name, cfg.Network.Subnet)
			},
		},
		{
			ID:    "dns",
			Label: "ensure forge-dns",
			Deps:  []string{"network"},
			Fn: func(ctx context.Context) error {
				return EnsureDNS(ctx, exe, cfg)
			},
		},
	}
	mirrorIDs := make([]string, 0, len(cfg.Mirrors))
	for _, m := range cfg.Mirrors {
		id := "mirror:" + m.Name
		mirrorIDs = append(mirrorIDs, id)
		mirror := m // capture
		nodes = append(nodes, Step{
			ID:    id,
			Label: fmt.Sprintf("ensure mirror %s → %s", m.Name, m.Upstream),
			Deps:  []string{"network"},
			Fn: func(ctx context.Context) error {
				return EnsureMirror(ctx, exe, mirror, cfg.Network.Name)
			},
		})
	}
	// Every cluster depends on network + dns + every mirror. That way
	// containerd hosts.toml writes (inside EnsureCluster) land after all
	// mirror containers are up, and CoreDNS patches land after forge-dns
	// is answering.
	clusterDeps := append([]string{"network", "dns"}, mirrorIDs...)
	for _, c := range cfg.AllClusters() {
		cluster := c.Cluster // capture
		nodes = append(nodes, Step{
			ID:    "cluster:" + cluster.Name,
			Label: fmt.Sprintf("ensure cluster %s", cluster.Name),
			Deps:  clusterDeps,
			Fn: func(ctx context.Context) error {
				return EnsureCluster(ctx, exe, dir, cfg.Network.Name, cfg.DNS.IP, cfg.Mirrors, cluster)
			},
		})
	}
	return nodes
}
