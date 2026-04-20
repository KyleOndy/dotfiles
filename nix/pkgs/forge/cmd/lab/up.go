package lab

import (
	"github.com/spf13/cobra"

	"github.com/kyleondy/dotfiles/forge/internal/cluster"
)

func newUp() *cobra.Command {
	return &cobra.Command{
		Use:   "up",
		Short: "Converge to desired state from forge.yaml",
		Long: `Create every cluster declared in forge.yaml. Idempotent: already-present
clusters are skipped.

v1 scope: Kind cluster creation and kubeconfig export. Docker network,
registry mirrors, MetalLB, DNS, and components layer in as those features
are ported.`,
		RunE: func(cmd *cobra.Command, _ []string) error {
			if err := cluster.CheckPrerequisites("docker", "kind"); err != nil {
				return err
			}
			cfg, err := cluster.Load(configPath(cmd))
			if err != nil {
				return err
			}
			return cluster.EnsureAllClusters(cmd.Context(), cluster.DefaultExecutor(), cfg)
		},
	}
}
