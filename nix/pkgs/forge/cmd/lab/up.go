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

Executes a DAG:
  - network (root)
  - dns + every mirror run in parallel after network
  - each cluster runs in parallel after network + dns + every mirror
    (Kind create → connect → hosts.toml → MetalLB → CoreDNS patch →
    components)`,
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
			plan := cluster.BuildUpPlan(exe, cfg)
			_, err = cluster.ExecuteDAG(ctx, plan)
			return err
		},
	}
}
