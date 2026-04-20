package flux

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/spf13/cobra"

	"github.com/kyleondy/dotfiles/forge/internal/gitwt"
	"github.com/kyleondy/dotfiles/forge/internal/lock"
	"github.com/kyleondy/dotfiles/forge/internal/state"
	"github.com/kyleondy/dotfiles/forge/internal/ui"
)

func newResetReal() *cobra.Command {
	var hard, clean, force, all bool
	c := &cobra.Command{
		Use:   "reset <ticket> [task-id]",
		Short: "Clear failure state so a task can rerun",
		Long: `Clear failure/retry state so the auto loop can resume. Never deletes
SPEC.md, PLAN.md, TASKS.md, or task directories themselves.

Without task-id:
  - Resets retry_count on every task
  - Clears stale FAIL verdicts (PASS preserved)
  - Clears the needs_human sentinel

With task-id (e.g. T01):
  - Resets that one task: status → pending, verdict cleared, retry → 0
  - Deletes SUMMARY.md and REVIEW.md (so builder + critic rerun fresh)
  - Keeps the per-task PLAN.md (with accumulated critic feedback)

--all:
  - Clears ALL verdicts including PASS, so flux auto restarts from T01
  - Deletes SUMMARY.md and REVIEW.md for every task
  - Incompatible with a task-id (per-task reset already does a full reset)

--hard:
  - Also deletes the per-task PLAN.md, dropping accumulated critic feedback

--clean:
  - Also removes forge-owned worktrees and branches listed in state.json
  - Refuses if any worktree has uncommitted changes or unpushed commits
  - Use with --force to remove anyway (git worktree remove --force; git branch -D)
  - Worktrees/branches not in state.json are never touched`,
		Args:              cobra.RangeArgs(1, 2),
		ValidArgsFunction: completeTicketIDs,
		RunE: func(_ *cobra.Command, args []string) error {
			if force && !clean {
				return fmt.Errorf("--force requires --clean")
			}
			id := args[0]
			var taskID string
			if len(args) == 2 {
				taskID = args[1]
			}
			if all && taskID != "" {
				return fmt.Errorf("--all is incompatible with a task-id; per-task reset already does a full reset")
			}
			_, l, err := requireWorkDir(id)
			if err != nil {
				return err
			}

			// Bail if any live lock is held.
			locks, err := lock.All(l.LocksDir)
			if err != nil {
				return fmt.Errorf("checking locks: %w", err)
			}
			for _, lk := range locks {
				if lk.Alive {
					return fmt.Errorf("live lock at %s (PID %d); wait for it or kill it first", lk.Name, lk.Meta.PID)
				}
			}

			s, err := state.Load(l, id)
			if err != nil {
				return err
			}

			var removed []string
			if taskID == "" {
				if all {
					s.ResetAllTasks()
					ui.L().Info("reset all tasks (including PASS) to pending")
					for _, t := range s.Tasks {
						dir := l.TaskDir(t.ID, t.Slug)
						for _, f := range []string{"SUMMARY.md", "REVIEW.md", "VERDICT", "ARCHITECT.md", "ARCH_VERDICT"} {
							p := dir + "/" + f
							if removeIfExists(p) {
								removed = append(removed, p)
							}
						}
						if hard {
							p := dir + "/PLAN.md"
							if removeIfExists(p) {
								removed = append(removed, p)
							}
						}
					}
				} else {
					s.ResetAll()
					ui.L().Info("reset all FAIL verdicts and retry counts")
				}
			} else {
				if err := s.ResetTask(taskID); err != nil {
					return err
				}
				t, _ := s.Find(taskID)
				dir := l.TaskDir(taskID, t.Slug)
				for _, f := range []string{"SUMMARY.md", "REVIEW.md", "VERDICT", "ARCHITECT.md", "ARCH_VERDICT"} {
					p := dir + "/" + f
					if removeIfExists(p) {
						removed = append(removed, p)
					}
				}
				if hard {
					p := dir + "/PLAN.md"
					if removeIfExists(p) {
						removed = append(removed, p)
					}
				}
			}
			if err := state.Save(l, s); err != nil {
				return err
			}
			for _, p := range removed {
				ui.L().Info("removed %s", p)
			}

			if clean {
				ctx := context.Background()
				exe := gitwt.Default()
				cwd, _ := os.Getwd()
				wtRoot, err := gitwt.RequireRoot(ctx, exe, cwd)
				if err != nil {
					return err
				}
				if err := cleanForgeArtifacts(ctx, exe, cwd, wtRoot, s, taskID, force); err != nil {
					return err
				}
			}

			ui.L().Info("next: forge flux auto %s", id)
			return nil
		},
	}
	c.Flags().BoolVar(&all, "all", false, "reset all tasks including PASS, so flux auto restarts from T01")
	c.Flags().BoolVar(&hard, "hard", false, "also delete the per-task PLAN.md")
	c.Flags().BoolVar(&clean, "clean", false, "also remove forge-owned worktrees and branches listed in state.json")
	c.Flags().BoolVar(&force, "force", false, "with --clean: remove worktrees/branches even if dirty or unpushed")
	return c
}

// worktreeTarget pairs the expected on-disk path with the branch name forge created.
type worktreeTarget struct {
	path   string
	branch string
}

// forgeTargets builds the set of worktree+branch pairs forge owns for the
// ticket. If taskID is non-empty, only that task is included.
func forgeTargets(wtRoot string, s *state.State, taskID string) []worktreeTarget {
	var targets []worktreeTarget
	for _, t := range s.Tasks {
		if taskID != "" && t.ID != taskID {
			continue
		}
		name := t.ID + "-" + t.Slug
		targets = append(targets, worktreeTarget{
			path:   filepath.Join(wtRoot, s.Ticket, name),
			branch: s.Ticket + "-" + name,
		})
	}
	return targets
}

// cleanForgeArtifacts removes forge-owned worktrees and branches for the
// ticket. It intersects forgeTargets against live worktrees reported by git,
// checks each for dirty/unpushed state, and refuses (or force-removes) as
// appropriate.
func cleanForgeArtifacts(ctx context.Context, exe gitwt.Executor, cwd, wtRoot string, s *state.State, taskID string, force bool) error {
	targets := forgeTargets(wtRoot, s, taskID)
	if len(targets) == 0 {
		return nil
	}

	// Index live worktrees by path for fast lookup.
	live, err := gitwt.ListWorktrees(ctx, exe, cwd)
	if err != nil {
		return err
	}
	liveByPath := make(map[string]bool, len(live))
	for _, wt := range live {
		liveByPath[wt.Path] = true
	}

	// Gather targets that actually exist on disk.
	var present []worktreeTarget
	for _, tgt := range targets {
		if liveByPath[tgt.path] {
			present = append(present, tgt)
		}
	}
	if len(present) == 0 {
		return nil
	}

	// Check for dirty or unpushed work; collect blockers.
	if !force {
		var blockers []string
		for _, tgt := range present {
			dirty, err := gitwt.IsDirty(ctx, exe, tgt.path)
			if err != nil {
				return err
			}
			if dirty {
				blockers = append(blockers, tgt.path+": uncommitted changes")
				continue
			}
			unpushed, err := gitwt.HasUnpushed(ctx, exe, tgt.path)
			if err != nil {
				return err
			}
			if unpushed {
				blockers = append(blockers, tgt.path+": unpushed commits")
			}
		}
		if len(blockers) > 0 {
			return fmt.Errorf("--clean refused; worktrees have unsaved work (use --force to override):\n  %s",
				strings.Join(blockers, "\n  "))
		}
	}

	// Remove worktrees then branches.
	removed := 0
	for _, tgt := range present {
		if err := gitwt.RemoveWorktree(ctx, exe, cwd, tgt.path, force); err != nil {
			return err
		}
		ui.L().Info("removed worktree %s", tgt.path)
		if err := gitwt.DeleteBranch(ctx, exe, cwd, tgt.branch, force); err != nil {
			return err
		}
		ui.L().Info("deleted branch %s", tgt.branch)
		removed++
	}
	ui.L().Info("removed %d worktree(s) and %d branch(es) for %s", removed, removed, s.Ticket)
	return nil
}

func removeIfExists(path string) bool {
	if _, err := os.Stat(path); err == nil {
		return os.Remove(path) == nil
	}
	return false
}
