package lab

import (
	"github.com/spf13/cobra"

	"github.com/kyleondy/dotfiles/forge/internal/cluster"
)

func newDown() *cobra.Command {
	return &cobra.Command{
		Use:   "down",
		Short: "Delete all forge clusters (preserves mirrors + forge-dns + network)",
		Long: `Delete every Kind cluster declared in forge.yaml plus any orphaned
forge-* clusters on the host. Leaves the forge Docker network, mirror
containers and their caches, and forge-dns in place so a subsequent
` + "`lab up`" + ` is fast.

Use ` + "`lab nuke`" + ` for a full teardown.`,
		RunE: func(cmd *cobra.Command, _ []string) error {
			if err := cluster.CheckPrerequisites("docker", "kind"); err != nil {
				return err
			}
			cfg, err := cluster.Load(configPath(cmd))
			if err != nil {
				return err
			}
			return cluster.TearDown(cmd.Context(), cluster.DefaultExecutor(), cfg, false)
		},
	}
}

func newNuke() *cobra.Command {
	return &cobra.Command{
		Use:   "nuke",
		Short: "Delete clusters, mirrors, volumes, forge-dns, and the network",
		Long: `Full teardown: every declared + orphan forge resource gets removed.
Mirror image caches (Docker volumes) are deleted too, so the next ` +
			"`lab up`" + ` will pull fresh.`,
		RunE: func(cmd *cobra.Command, _ []string) error {
			if err := cluster.CheckPrerequisites("docker", "kind"); err != nil {
				return err
			}
			cfg, err := cluster.Load(configPath(cmd))
			if err != nil {
				return err
			}
			return cluster.TearDown(cmd.Context(), cluster.DefaultExecutor(), cfg, true)
		},
	}
}
