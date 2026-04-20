package flux

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"github.com/spf13/cobra"

	"github.com/kyleondy/dotfiles/forge/internal/agent"
	"github.com/kyleondy/dotfiles/forge/internal/events"
	"github.com/kyleondy/dotfiles/forge/internal/gitwt"
	"github.com/kyleondy/dotfiles/forge/internal/lock"
	"github.com/kyleondy/dotfiles/forge/internal/prompt"
	"github.com/kyleondy/dotfiles/forge/internal/state"
	"github.com/kyleondy/dotfiles/forge/internal/ui"
)

// Sentinel errors for retryable builder failures.
var (
	ErrBuilderNoSummary = errors.New("builder did not produce SUMMARY.md")
	ErrBuilderDirty     = errors.New("builder left uncommitted changes")
	ErrBuilderNoCommit  = errors.New("builder produced no commit")
)

func newTaskReal() *cobra.Command {
	return &cobra.Command{
		Use:               "task <ticket> [task-id]",
		Short:             "Builder phase: dispatch one task to a tool-capable agent",
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

			task, err := pickTask(s, args)
			if err != nil {
				return err
			}
			ui.L().Info("task: %s %s: %s", task.ID, task.Slug, task.Title)

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
				ui.L().Info("creating worktree: %s", worktreePath)
				if _, err := gitwt.CreateFeatureBranch(ctx, exe, cwd, id, task.ID+"-"+task.Slug); err != nil {
					return err
				}
			} else {
				ui.L().Info("worktree exists: %s", worktreePath)
			}
			if err := gitwt.DisableSigning(ctx, exe, worktreePath); err != nil {
				ui.L().Warn("disable gpg signing failed: %v", err)
			}

			lk, err := lock.Acquire(l.LocksDir, "task", task.ID)
			if err != nil {
				return err
			}
			defer lk.Release()
			wasStale := lk.WasStale()
			if wasStale {
				ui.L().Warn("prior dispatch was interrupted; this is a re-run")
			}

			composed, err := prompt.ComposeBuilder(l, s, task.ID)
			if err != nil {
				return err
			}
			composed.Prompt = phaseOverrides(cfg, "task").Apply(composed.Prompt)

			eventPath := events.Path(l.EventsDir, "task", task.ID)
			eventLog, err := events.Open(eventPath)
			if err != nil {
				return err
			}
			defer eventLog.Close()
			ui.L().Info("event log: %s", eventPath)

			retryMax, _ := strconv.Atoi(os.Getenv("FORGE_RETRY_CAP"))
			req := agent.Request{
				Prompt:       composed.Prompt,
				Phase:        agent.PhaseBuilder,
				TicketID:     id,
				TaskID:       task.ID,
				CWD:          worktreePath,
				ExtraDirs:    []string{l.Root},
				AllowedTools: []string{"Write", "Edit", "Read", "Glob", "Grep", "Bash"},
				Quiet:        cfg.Quiet,
				EventLog:     eventLog,
				Stdout:       cmd.OutOrStdout(),
				Stderr:       cmd.ErrOrStderr(),
				Timeout:      cfg.OpenAITimeout,
				RetryAttempt: task.RetryCount,
				RetryMax:     retryMax,
				TaskTotal:    len(s.Tasks),
			}
			summaryPath := filepath.Join(l.TaskDir(task.ID, task.Slug), "SUMMARY.md")

			// Clear stale builder output before dispatch so the agent starts fresh.
			_ = os.Remove(summaryPath)

			if _, err := dispatchAgent(ctx, cfg, req); err != nil {
				return err
			}

			// Validate the builder produced SUMMARY.md.
			if _, err := os.Stat(summaryPath); err != nil {
				return fmt.Errorf("%w: %s", ErrBuilderNoSummary, summaryPath)
			}
			if wasStale {
				appendStaleAnnotation(summaryPath)
			}

			// Verify the builder committed its work.
			if dirty, err := gitwt.IsDirty(ctx, exe, worktreePath); err != nil {
				return fmt.Errorf("check worktree: %w", err)
			} else if dirty {
				return fmt.Errorf("%w in %s; run `git -C %s status` and re-dispatch", ErrBuilderDirty, worktreePath, worktreePath)
			}
			if hasCommits, err := gitwt.HasUnpushed(ctx, exe, worktreePath); err != nil {
				return fmt.Errorf("check commits: %w", err)
			} else if !hasCommits {
				return fmt.Errorf("%w on branch for %s", ErrBuilderNoCommit, task.ID)
			}

			// Reload + mark done.
			s, err = state.Load(l, id)
			if err != nil {
				return err
			}
			if err := s.MarkDone(task.ID); err != nil {
				return err
			}
			if err := state.Save(l, s); err != nil {
				return err
			}
			ui.L().Info("marked %s done", task.ID)
			ui.L().Info("next: forge flux verify %s %s", id, task.ID)
			return nil
		},
	}
}

func pickTask(s *state.State, args []string) (*state.Task, error) {
	if len(args) == 2 {
		t, _ := s.Find(args[1])
		if t == nil {
			return nil, fmt.Errorf("task %s not found in state", args[1])
		}
		if t.Status == state.StatusDone {
			ui.L().Warn("%s is already marked done; re-running anyway", t.ID)
		}
		return t, nil
	}
	t := s.NextPending()
	if t == nil {
		return nil, errors.New("no pending tasks; all done?")
	}
	return t, nil
}

func appendStaleAnnotation(path string) {
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, "\n\n<!-- STALE_RESTART: %s prior dispatch was interrupted -->\n", time.Now().UTC().Format(time.RFC3339))
}
