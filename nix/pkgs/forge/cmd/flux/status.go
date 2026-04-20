package flux

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/spf13/cobra"

	"github.com/kyleondy/dotfiles/forge/internal/agent"
	"github.com/kyleondy/dotfiles/forge/internal/config"
	"github.com/kyleondy/dotfiles/forge/internal/events"
	"github.com/kyleondy/dotfiles/forge/internal/lock"
	"github.com/kyleondy/dotfiles/forge/internal/prompt"
	"github.com/kyleondy/dotfiles/forge/internal/state"
	"github.com/kyleondy/dotfiles/forge/internal/ticket"
	"github.com/kyleondy/dotfiles/forge/internal/ui"
)

func newStatusReal() *cobra.Command {
	c := &cobra.Command{
		Use:               "status <ticket>",
		Short:             "Compose today's status update draft (does not post)",
		Args:              cobra.ExactArgs(1),
		ValidArgsFunction: completeTicketIDs,
		RunE: func(cmd *cobra.Command, args []string) error {
			id := args[0]
			cfg, l, err := requireWorkDir(id)
			if err != nil {
				return err
			}
			s, err := state.Load(l, id)
			if err != nil {
				return err
			}
			date := time.Now().Format("2006-01-02")

			composed, err := prompt.ComposeStatus(l, s, id, date)
			if err != nil {
				return err
			}

			lk, err := lock.Acquire(l.LocksDir, "status", "main")
			if err != nil {
				return err
			}
			defer lk.Release()

			eventLog, err := events.Open(events.Path(l.EventsDir, "status", "main"))
			if err != nil {
				return err
			}
			defer eventLog.Close()

			req := agent.Request{
				Prompt:       composed.Prompt,
				Phase:        agent.PhaseStatus,
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
			if _, err := dispatchAgent(context.Background(), cfg, req); err != nil {
				return err
			}

			out := filepath.Join(l.Root, composed.TargetFile)
			if _, err := os.Stat(out); err != nil {
				return fmt.Errorf("agent did not produce %s", out)
			}
			ui.L().Info("drafted: %s", out)
			ui.L().Info("review with: $EDITOR %s", out)
			ui.L().Info("post with:   forge flux status post %s", id)
			return nil
		},
	}
	c.AddCommand(newStatusPostReal())
	return c
}

func newStatusPostReal() *cobra.Command {
	return &cobra.Command{
		Use:               "post <ticket> [date]",
		Short:             "Post the drafted <DATE>-status.md to Linear (manual confirm)",
		Args:              cobra.RangeArgs(1, 2),
		ValidArgsFunction: completeTicketIDs,
		RunE: func(_ *cobra.Command, args []string) error {
			id := args[0]
			if !ticket.IsLinear(id) {
				ui.L().Warn("%s is not a Linear-style ID; nothing to post", id)
				return nil
			}
			cfg, err := config.Load()
			if err != nil {
				return err
			}
			date := time.Now().Format("2006-01-02")
			if len(args) == 2 {
				date = args[1]
			}
			l := state.LayoutFor(cfg.TicketsRoot, id)
			path := filepath.Join(l.Root, date+"-status.md")
			body, err := os.ReadFile(path)
			if err != nil {
				return fmt.Errorf("no status draft at %s; run: forge flux status %s", path, id)
			}

			fmt.Println("preview:", path)
			fmt.Println("----- BEGIN STATUS -----")
			os.Stdout.Write(body)
			fmt.Println()
			fmt.Println("----- END STATUS -----")
			fmt.Println()

			if err := ui.ConfirmOrDie(fmt.Sprintf("Post this status as a Linear comment on %s?", id), cfg.AutoApprove); err != nil {
				return err
			}

			// Post via the linear CLI through our wrapper.
			if err := postStatus(id, string(body), cfg.LinearAPIKey); err != nil {
				return err
			}
			ui.L().Info("posted to %s", id)
			return nil
		},
	}
}

func postStatus(ticketID, body, apiKey string) error {
	if err := preflightLinear(apiKey); err != nil {
		return err
	}
	return runLinearPost(context.Background(), ticketID, body)
}
