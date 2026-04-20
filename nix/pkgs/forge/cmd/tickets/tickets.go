// Package tickets hosts top-level ticket-related subcommands. Today it
// exposes `forge tickets refresh`, which pulls assigned-to-me issues from
// Linear and writes them to the completion cache.
package tickets

import (
	"context"
	"time"

	"github.com/spf13/cobra"

	"github.com/kyleondy/dotfiles/forge/internal/config"
	"github.com/kyleondy/dotfiles/forge/internal/linear"
	"github.com/kyleondy/dotfiles/forge/internal/ui"
)

func New() *cobra.Command {
	c := &cobra.Command{
		Use:   "tickets",
		Short: "Manage forge's Linear ticket cache",
	}
	c.AddCommand(newRefreshCmd())
	return c
}

func newRefreshCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "refresh",
		Short: "Refresh the assigned-to-me ticket cache from Linear",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			cfg, err := config.Load()
			if err != nil {
				return err
			}
			ctx, cancel := context.WithTimeout(cmd.Context(), 30*time.Second)
			defer cancel()
			issues, err := linear.FetchAssignedIssues(ctx, cfg.LinearAPIKey)
			if err != nil {
				return err
			}
			if err := linear.WriteCache(linear.CacheFile{FetchedAt: time.Now(), Issues: issues}); err != nil {
				return err
			}
			ui.L().Info("cached %d tickets to %s", len(issues), linear.CachePath())
			return nil
		},
	}
}
