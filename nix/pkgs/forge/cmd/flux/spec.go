package flux

import (
	"context"
	"errors"
	"strings"

	"github.com/spf13/cobra"

	"github.com/kyleondy/dotfiles/forge/internal/agent"
	"github.com/kyleondy/dotfiles/forge/internal/events"
	"github.com/kyleondy/dotfiles/forge/internal/lock"
	"github.com/kyleondy/dotfiles/forge/internal/prompt"
	"github.com/kyleondy/dotfiles/forge/internal/state"
	"github.com/kyleondy/dotfiles/forge/internal/ui"
)

const specFeedbackNote = "\n\n## Validation feedback\n\n" +
	"Your previous output was rejected: sections were not written as Markdown H2 headers. " +
	"Each section title MUST be a line starting with `## ` " +
	"(e.g. `## Outcomes`, `## In scope`). " +
	"The existing file content is shown above. Rewrite it using proper `## ` headers and preserve all content."

func newSpecReal() *cobra.Command {
	return &cobra.Command{
		Use:               "spec <ticket> [description...]",
		Short:             "Generate or revise SPEC.md for a ticket",
		Args:              cobra.MinimumNArgs(1),
		ValidArgsFunction: completeTicketIDs,
		RunE: func(cmd *cobra.Command, args []string) error {
			id := args[0]
			description := strings.Join(args[1:], " ")
			cfg, l, err := requireTicket(id, true)
			if err != nil {
				return err
			}
			if err := ensureLinearFetched(cmd, id, l); err != nil {
				return err
			}

			composed, err := prompt.ComposeSpec(l, id, description)
			if err != nil {
				return err
			}
			ov := phaseOverrides(cfg, "spec")
			composed.Prompt = ov.Apply(composed.Prompt)

			lk, err := lock.Acquire(l.LocksDir, "spec", "main")
			if err != nil {
				return err
			}
			defer lk.Release()

			eventLog, err := events.Open(events.Path(l.EventsDir, "spec", "main"))
			if err != nil {
				return err
			}
			defer eventLog.Close()

			req := agent.Request{
				Prompt:       composed.Prompt,
				Phase:        agent.PhaseSpec,
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
					return err
				}
				phase := state.DerivePhase(l, s)
				if phase != state.PhaseSpec && phase != state.PhaseInit {
					break
				}
				if attempt == maxAttempts {
					return errors.New("SPEC.md is missing required sections after dispatch (need at least one of: Outcomes / In scope / Out of scope / Constraints / Prior decisions / Verification)")
				}

				// Rebuild prompt: ComposeSpec picks up the malformed SPEC.md as
				// EXISTING_SPEC, so the model sees what it wrote plus the feedback.
				composed, err = prompt.ComposeSpec(l, id, description)
				if err != nil {
					return err
				}
				req.Prompt = ov.Apply(composed.Prompt) + specFeedbackNote
			}
			ui.L().Info("spec updated: %s", l.SpecPath)
			ui.L().Info("next: forge flux plan %s", id)
			return nil
		},
	}
}
