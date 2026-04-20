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

func newVerifyReal() *cobra.Command {
	return &cobra.Command{
		Use:               "verify <ticket> [task-id]",
		Short:             "Critic phase: review a built task and write VERDICT (PASS|FAIL)",
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

			task, err := pickVerifyTask(l, s, args)
			if err != nil {
				return err
			}
			ui.L().Info("verifying: %s %s: %s", task.ID, task.Slug, task.Title)

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

			lk, err := lock.Acquire(l.LocksDir, "verify", task.ID)
			if err != nil {
				return err
			}
			defer lk.Release()

			composed, err := prompt.ComposeCritic(l, s, task.ID, worktreePath, diff)
			if err != nil {
				return err
			}
			composed.Prompt = phaseOverrides(cfg, "verify").Apply(composed.Prompt)

			eventPath := events.Path(l.EventsDir, "verify", task.ID)
			eventLog, err := events.Open(eventPath)
			if err != nil {
				return err
			}
			defer eventLog.Close()
			ui.L().Info("event log: %s", eventPath)

			retryMax, _ := strconv.Atoi(os.Getenv("FORGE_RETRY_CAP"))
			req := agent.Request{
				Prompt:       composed.Prompt,
				Phase:        agent.PhaseCritic,
				TicketID:     id,
				TaskID:       task.ID,
				CWD:          l.Root,
				ExtraDirs:    []string{worktreePath},
				AllowedTools: []string{"Write", "Edit", "Read", "Glob", "Grep"},
				Quiet:        cfg.Quiet,
				EventLog:     eventLog,
				Stdout:       cmd.OutOrStdout(),
				Stderr:       cmd.ErrOrStderr(),
				Timeout:      cfg.OpenAITimeout,
				RetryAttempt: task.RetryCount,
				RetryMax:     retryMax,
			}
			taskDir := l.TaskDir(task.ID, task.Slug)
			reviewPath := filepath.Join(taskDir, "REVIEW.md")
			verdictPath := filepath.Join(taskDir, "VERDICT")

			// Clear stale critic output before dispatch so the agent starts fresh.
			_ = os.Remove(reviewPath)
			_ = os.Remove(verdictPath)

			if _, err := dispatchAgent(ctx, cfg, req); err != nil {
				return err
			}
			if _, err := os.Stat(reviewPath); err != nil {
				return fmt.Errorf("critic did not produce REVIEW.md")
			}
			vb, err := os.ReadFile(verdictPath)
			if err != nil {
				return fmt.Errorf("critic did not produce VERDICT: %w", err)
			}
			verdict := state.Verdict(strings.ToUpper(strings.TrimSpace(string(vb))))
			switch verdict {
			case state.VerdictPass:
				ui.L().Info("verdict: PASS for %s", task.ID)
			case state.VerdictFail:
				ui.L().Warn("verdict: FAIL for %s; flipping back to pending", task.ID)
				if err := appendReviewFindings(taskDir, reviewPath, "Verifier findings"); err != nil {
					ui.L().Warn("could not append verifier findings to PLAN.md: %v", err)
				}
			default:
				return fmt.Errorf("unexpected VERDICT contents: %q", string(vb))
			}

			s, err = state.Load(l, id)
			if err != nil {
				return fmt.Errorf("reloading state after dispatch: %w", err)
			}
			if err := s.SetVerdict(task.ID, verdict); err != nil {
				return err
			}
			return state.Save(l, s)
		},
	}
}

// pickVerifyTask: explicit ID wins; otherwise pick the most recently
// done task that has a SUMMARY.md but no VERDICT in state yet.
func pickVerifyTask(l state.Layout, s *state.State, args []string) (*state.Task, error) {
	if len(args) == 2 {
		t, _ := s.Find(args[1])
		if t == nil {
			return nil, fmt.Errorf("task %s not found", args[1])
		}
		return t, nil
	}
	for i := len(s.Tasks) - 1; i >= 0; i-- {
		t := &s.Tasks[i]
		dir := l.TaskDir(t.ID, t.Slug)
		if _, err := os.Stat(filepath.Join(dir, "SUMMARY.md")); err != nil {
			continue
		}
		if t.Verdict != state.VerdictNone {
			continue
		}
		return t, nil
	}
	return nil, fmt.Errorf("no task awaiting verification (need a SUMMARY.md without a verdict)")
}

// appendReviewFindings appends review-file content to the per-task PLAN.md
// under a named H2 heading so the next builder dispatch sees it. Shared by
// verify (critic) and architect phases.
func appendReviewFindings(taskDir, reviewPath, heading string) error {
	review, err := os.ReadFile(reviewPath)
	if err != nil {
		return fmt.Errorf("reading %s: %w", reviewPath, err)
	}
	planPath := filepath.Join(taskDir, "PLAN.md")
	f, err := os.OpenFile(planPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return fmt.Errorf("opening %s: %w", planPath, err)
	}
	defer f.Close()
	fmt.Fprintf(f, "\n\n## %s\n\n", heading)
	if _, err := f.Write(review); err != nil {
		return fmt.Errorf("writing findings to %s: %w", planPath, err)
	}
	return nil
}
