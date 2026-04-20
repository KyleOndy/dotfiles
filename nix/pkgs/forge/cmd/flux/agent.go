package flux

import (
	"context"
	"os"

	"github.com/spf13/cobra"

	"github.com/kyleondy/dotfiles/forge/internal/agent"
	"github.com/kyleondy/dotfiles/forge/internal/config"
	"github.com/kyleondy/dotfiles/forge/internal/events"
)

func newAgentReal() *cobra.Command {
	c := &cobra.Command{Use: "agent", Short: "Low-level agent dispatch (debugging)"}
	c.AddCommand(&cobra.Command{
		Use:   "run <prompt-file> <event-log>",
		Short: "Dispatch a prompt file via the configured agent and tee to event-log",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := config.Load()
			if err != nil {
				return err
			}
			body, err := os.ReadFile(args[0])
			if err != nil {
				return err
			}
			eventLog, err := events.Open(args[1])
			if err != nil {
				return err
			}
			defer eventLog.Close()

			req := agent.Request{
				Prompt:       string(body),
				Phase:        agent.PhaseSpec, // most permissive non-tool phase by default
				CWD:          ".",
				AllowedTools: []string{"Write", "Edit", "Read"},
				Quiet:        cfg.Quiet,
				EventLog:     eventLog,
				Stdout:       cmd.OutOrStdout(),
				Stderr:       cmd.ErrOrStderr(),
				Timeout:      cfg.OpenAITimeout,
			}
			_, err = dispatchAgent(context.Background(), cfg, req)
			return err
		},
	})
	return c
}
