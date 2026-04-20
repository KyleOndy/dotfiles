package flux

import (
	"context"
	"fmt"

	"github.com/spf13/cobra"

	"github.com/kyleondy/dotfiles/forge/internal/agent"
	"github.com/kyleondy/dotfiles/forge/internal/events"
	"github.com/kyleondy/dotfiles/forge/internal/lock"
	"github.com/kyleondy/dotfiles/forge/internal/prompt"
	"github.com/kyleondy/dotfiles/forge/internal/state"
	"github.com/kyleondy/dotfiles/forge/internal/ui"
)

func newDecomposeReal() *cobra.Command {
	return &cobra.Command{
		Use:               "decompose <ticket>",
		Short:             "Decompose PLAN.md into TASKS.md plus per-task PLAN.md files",
		Args:              cobra.ExactArgs(1),
		ValidArgsFunction: completeTicketIDs,
		RunE: func(cmd *cobra.Command, args []string) error {
			id := args[0]
			cfg, l, err := requireWorkDir(id)
			if err != nil {
				return err
			}
			composed, err := prompt.ComposeDecompose(l, id)
			if err != nil {
				return err
			}
			composed.Prompt = phaseOverrides(cfg, "decompose").Apply(composed.Prompt)
			lk, err := lock.Acquire(l.LocksDir, "decompose", "main")
			if err != nil {
				return err
			}
			defer lk.Release()

			eventLog, err := events.Open(events.Path(l.EventsDir, "decompose", "main"))
			if err != nil {
				return err
			}
			defer eventLog.Close()

			req := agent.Request{
				Prompt:       composed.Prompt,
				Phase:        agent.PhaseDecompose,
				TicketID:     id,
				CWD:          l.Root,
				ExtraDirs:    []string{l.Root},
				AllowedTools: []string{"Write", "Edit", "Read"},
				Quiet:        cfg.Quiet,
				EventLog:     eventLog,
				Stdout:       cmd.OutOrStdout(),
				Stderr:       cmd.ErrOrStderr(),
				Timeout:      cfg.OpenAITimeout,
			}
			if _, err := dispatchAgent(context.Background(), cfg, req); err != nil {
				return err
			}

			// Parse the agent-written TASKS.md and merge into state.json.
			s, err := state.Load(l, id)
			if err != nil {
				return err
			}
			added, err := state.SyncFromTasksMD(l, s)
			if err != nil {
				return fmt.Errorf("agent did not produce a parseable TASKS.md: %w", err)
			}
			if err := state.Save(l, s); err != nil {
				return err
			}
			ui.L().Info("decomposed into %d task(s) (%d new)", len(s.Tasks), added)
			for _, t := range s.Tasks {
				ui.L().Info("  %-7s %s %s: %s", t.Status, t.ID, t.Slug, t.Title)
			}
			ui.L().Info("next: forge flux task %s", id)
			return nil
		},
	}
}
