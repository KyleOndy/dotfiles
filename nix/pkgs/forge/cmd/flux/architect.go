package flux

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/spf13/cobra"

	"github.com/kyleondy/dotfiles/forge/internal/agent"
	"github.com/kyleondy/dotfiles/forge/internal/events"
	"github.com/kyleondy/dotfiles/forge/internal/gitwt"
	"github.com/kyleondy/dotfiles/forge/internal/lock"
	"github.com/kyleondy/dotfiles/forge/internal/prompt"
	"github.com/kyleondy/dotfiles/forge/internal/state"
	"github.com/kyleondy/dotfiles/forge/internal/ui"
)

func newArchitectReal() *cobra.Command {
	return &cobra.Command{
		Use:               "architect <ticket> [task-id]",
		Short:             "Architect phase: judge whether a critic-passed task fits the codebase",
		Args:              cobra.RangeArgs(1, 2),
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

			task, err := pickArchitectTask(s, args)
			if err != nil {
				return err
			}
			ui.L().Info("architect: %s %s: %s", task.ID, task.Slug, task.Title)

			ctx := context.Background()
			exe := gitwt.Default()
			cwd, err := os.Getwd()
			if err != nil {
				return fmt.Errorf("getwd: %w", err)
			}
			wtRoot, err := gitwt.RequireRoot(ctx, exe, cwd)
			if err != nil {
				return err
			}
			worktreePath := filepath.Join(wtRoot, id, task.ID+"-"+task.Slug)
			if _, err := os.Stat(worktreePath); err != nil {
				return fmt.Errorf("worktree not found: %s", worktreePath)
			}

			baseRef, err := gitwt.UpstreamRef(ctx, exe, worktreePath)
			if err != nil {
				return err
			}
			diff, err := gitwt.Diff(ctx, exe, worktreePath, baseRef)
			if err != nil {
				ui.L().Warn("diff failed: %v", err)
				diff = "(diff unavailable)"
			}
			if strings.TrimSpace(diff) == "" {
				diff = "(no committed changes vs base)"
			}

			lk, err := lock.Acquire(l.LocksDir, "architect", task.ID)
			if err != nil {
				return err
			}
			defer lk.Release()

			composed, err := prompt.ComposeArchitect(l, s, task.ID, worktreePath, diff)
			if err != nil {
				return err
			}
			composed.Prompt = phaseOverrides(cfg, "architect").Apply(composed.Prompt)

			eventPath := events.Path(l.EventsDir, "architect", task.ID)
			eventLog, err := events.Open(eventPath)
			if err != nil {
				return err
			}
			defer eventLog.Close()
			ui.L().Info("event log: %s", eventPath)

			retryMax, _ := strconv.Atoi(os.Getenv("FORGE_RETRY_CAP"))
			req := agent.Request{
				Prompt:       composed.Prompt,
				Phase:        agent.PhaseArchitect,
				TicketID:     id,
				TaskID:       task.ID,
				CWD:          l.Root,
				ExtraDirs:    []string{worktreePath},
				AllowedTools: []string{"Write", "Edit", "Read", "Glob", "Grep", "Bash"},
				Quiet:        cfg.Quiet,
				EventLog:     eventLog,
				Stdout:       cmd.OutOrStdout(),
				Stderr:       cmd.ErrOrStderr(),
				Timeout:      cfg.OpenAITimeout,
				RetryAttempt: task.RetryCount,
				RetryMax:     retryMax,
			}
			taskDir := l.TaskDir(task.ID, task.Slug)
			reviewPath := filepath.Join(taskDir, "ARCHITECT.md")
			verdictPath := filepath.Join(taskDir, "ARCH_VERDICT")

			// Clear stale architect output before dispatch so the agent starts fresh.
			_ = os.Remove(reviewPath)
			_ = os.Remove(verdictPath)

			if _, err := dispatchAgent(ctx, cfg, req); err != nil {
				return err
			}
			if _, err := os.Stat(reviewPath); err != nil {
				return fmt.Errorf("architect did not produce ARCHITECT.md")
			}
			vb, err := os.ReadFile(verdictPath)
			if err != nil {
				return fmt.Errorf("architect did not produce ARCH_VERDICT: %w", err)
			}
			verdict := state.Verdict(strings.ToUpper(strings.TrimSpace(string(vb))))
			switch verdict {
			case state.VerdictPass:
				ui.L().Info("arch verdict: PASS for %s", task.ID)
			case state.VerdictFail:
				ui.L().Warn("arch verdict: FAIL for %s; flipping back to pending", task.ID)
				if err := appendReviewFindings(taskDir, reviewPath, "Architect findings"); err != nil {
					ui.L().Warn("could not append architect findings to PLAN.md: %v", err)
				}
			default:
				return fmt.Errorf("unexpected ARCH_VERDICT contents: %q", string(vb))
			}

			s, err = state.Load(l, id)
			if err != nil {
				return fmt.Errorf("reloading state after dispatch: %w", err)
			}
			if err := s.SetArchVerdict(task.ID, verdict); err != nil {
				return err
			}
			return state.Save(l, s)
		},
	}
}

// pickArchitectTask: explicit ID wins; otherwise pick the first task that
// has a critic PASS but no architect verdict yet.
func pickArchitectTask(s *state.State, args []string) (*state.Task, error) {
	if len(args) == 2 {
		t, _ := s.Find(args[1])
		if t == nil {
			return nil, fmt.Errorf("task %s not found", args[1])
		}
		return t, nil
	}
	if t := s.NextArchitect(); t != nil {
		return t, nil
	}
	return nil, fmt.Errorf("no task awaiting architect review (need critic PASS without architect verdict)")
}
