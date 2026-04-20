package flux

import (
	"github.com/spf13/cobra"
)

func newResumeReal() *cobra.Command {
	var auto bool
	c := &cobra.Command{
		Use:               "resume <ticket>",
		Short:             "Print the dashboard; with --auto, continue the orchestration loop",
		Args:              cobra.ExactArgs(1),
		ValidArgsFunction: completeTicketIDs,
		RunE: func(cmd *cobra.Command, args []string) error {
			id := args[0]
			showCmd := newShowReal()
			if err := showCmd.RunE(cmd, []string{id}); err != nil {
				return err
			}
			if !auto {
				return nil
			}
			autoCmd := newAutoReal()
			return autoCmd.RunE(cmd, []string{id})
		},
	}
	c.Flags().BoolVar(&auto, "auto", false, "after showing the dashboard, run forge flux auto")
	return c
}
