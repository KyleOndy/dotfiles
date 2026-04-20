package cmd

import (
	"github.com/spf13/cobra"

	"github.com/kyleondy/dotfiles/forge/cmd/flux"
	"github.com/kyleondy/dotfiles/forge/cmd/lab"
	"github.com/kyleondy/dotfiles/forge/cmd/tickets"
)

func New(version string) *cobra.Command {
	root := &cobra.Command{
		Use:           "forge",
		Short:         "forge: personal SRE + dev orchestrator",
		Version:       version,
		SilenceUsage:  true,
		SilenceErrors: true,
	}
	root.AddCommand(flux.New())
	root.AddCommand(lab.New())
	root.AddCommand(tickets.New())
	return root
}
