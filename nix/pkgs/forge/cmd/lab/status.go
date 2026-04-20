package lab

import (
	"fmt"

	"github.com/spf13/cobra"

	"github.com/kyleondy/dotfiles/forge/internal/cluster"
)

func newStatus() *cobra.Command {
	return &cobra.Command{
		Use:   "status",
		Short: "Show state of forge-owned resources (read-only)",
		Long: `Probe the host for every resource declared in forge.yaml and report
which are present, absent, or orphaned. No mutation.`,
		RunE: func(cmd *cobra.Command, _ []string) error {
			if err := cluster.CheckPrerequisites("docker", "kind"); err != nil {
				return err
			}
			cfg, err := cluster.Load(configPath(cmd))
			if err != nil {
				return err
			}
			lines := cluster.Collect(cmd.Context(), cluster.DefaultExecutor(), cfg)
			for _, l := range lines {
				fmt.Fprintln(cmd.OutOrStdout(), l.Format())
			}
			return nil
		},
	}
}
