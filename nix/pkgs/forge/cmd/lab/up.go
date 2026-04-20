package lab

import (
	"github.com/spf13/cobra"

	"github.com/kyleondy/dotfiles/forge/internal/cluster"
)

func newUp() *cobra.Command {
	return &cobra.Command{
		Use:   "up",
		Short: "Converge to desired state from forge.yaml",
		Long: `Bring every resource declared in forge.yaml to its desired state.
Idempotent: already-present resources are skipped.

Order of operations:
  1. Docker bridge network
  2. Pull-through registry mirrors (Zot)
  3. forge-dns container (dnsmasq on the bridge network)
  4. Kind clusters: create, connect to network, configure containerd
     mirrors, install MetalLB + pool, patch CoreDNS for forge.test

Components (ingress-nginx) land in a later commit.`,
		RunE: func(cmd *cobra.Command, _ []string) error {
			if err := cluster.CheckPrerequisites("docker", "kind", "kubectl"); err != nil {
				return err
			}
			cfg, err := cluster.Load(configPath(cmd))
			if err != nil {
				return err
			}
			exe := cluster.DefaultExecutor()
			ctx := cmd.Context()
			if err := cluster.EnsureNetwork(ctx, exe, cfg.Network.Name, cfg.Network.Subnet); err != nil {
				return err
			}
			if err := cluster.EnsureAllMirrors(ctx, exe, cfg); err != nil {
				return err
			}
			if err := cluster.EnsureDNS(ctx, exe, cfg); err != nil {
				return err
			}
			return cluster.EnsureAllClusters(ctx, exe, cfg)
		},
	}
}
