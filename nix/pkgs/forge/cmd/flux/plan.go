package flux

import (
	"context"
	"errors"
	"fmt"

	"github.com/spf13/cobra"

	"github.com/kyleondy/dotfiles/forge/internal/agent"
	"github.com/kyleondy/dotfiles/forge/internal/events"
	"github.com/kyleondy/dotfiles/forge/internal/lock"
	"github.com/kyleondy/dotfiles/forge/internal/prompt"
	"github.com/kyleondy/dotfiles/forge/internal/state"
	"github.com/kyleondy/dotfiles/forge/internal/ui"
)

const planFeedbackNote = "\n\n## Validation feedback\n\n" +
	"Your previous output was rejected: sections were not written as Markdown H2 headers. " +
	"Each section title MUST be a line starting with `## ` " +
	"(e.g. `## Approach`, `## Key files`). " +
	"The existing file content is shown above. Rewrite it using proper `## ` headers and preserve all content."

func newPlanReal() *cobra.Command {
	return &cobra.Command{
		Use:               "plan <ticket>",
		Short:             "Generate or revise PLAN.md from SPEC.md",
		Args:              cobra.ExactArgs(1),
		ValidArgsFunction: completeTicketIDs,
		RunE: func(cmd *cobra.Command, args []string) error {
			id := args[0]
			cfg, l, err := requireWorkDir(id)
			if err != nil {
				return err
			}
			composed, err := prompt.ComposePlan(l, id)
			if err != nil {
				return err
			}
			ov := phaseOverrides(cfg, "plan")
			composed.Prompt = ov.Apply(composed.Prompt)
			lk, err := lock.Acquire(l.LocksDir, "plan", "main")
			if err != nil {
				return err
			}
			defer lk.Release()

			eventLog, err := events.Open(events.Path(l.EventsDir, "plan", "main"))
			if err != nil {
				return err
			}
			defer eventLog.Close()

			req := agent.Request{
				Prompt:       composed.Prompt,
				Phase:        agent.PhasePlan,
				TicketID:     id,
				TargetFile:   composed.TargetFile,
				CWD:          l.Root,
				ExtraDirs:    []string{l.Root},
				AllowedTools: []string{"Write", "Edit", "Read"},
				Quiet:        cfg.Quiet,
				EventLog:     eventLog,
				Stdout:       cmd.OutOrStdout(),
				Stderr:       cmd.ErrOrStderr(),
				Timeout:      cfg.OpenAITimeout,
			}
			const maxAttempts = 2
			for attempt := 1; attempt <= maxAttempts; attempt++ {
				if _, err := dispatchAgent(context.Background(), cfg, req); err != nil {
					return err
				}

				s, err := state.Load(l, id)
				if err != nil {
					return fmt.Errorf("reloading state after dispatch: %w", err)
				}
				if state.DerivePhase(l, s) != state.PhasePlan {
					break
				}
				if attempt == maxAttempts {
					return errors.New("PLAN.md is missing H2 headings after dispatch")
				}

				composed, err = prompt.ComposePlan(l, id)
				if err != nil {
					return err
				}
				req.Prompt = ov.Apply(composed.Prompt) + planFeedbackNote
			}
			ui.L().Info("plan updated: %s", l.PlanPath)
			ui.L().Info("next: forge flux decompose %s", id)
			return nil
		},
	}
}
