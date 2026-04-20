package flux

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"time"

	"github.com/spf13/cobra"

	"github.com/kyleondy/dotfiles/forge/internal/state"
	"github.com/kyleondy/dotfiles/forge/internal/ui"
)

func newAutoReal() *cobra.Command {
	var maxIter int
	var retryCap int
	var skipRetro bool
	c := &cobra.Command{
		Use:               "auto <ticket>",
		Short:             "Drive spec → plan → decompose → loop(task → verify) until done",
		Args:              cobra.ExactArgs(1),
		ValidArgsFunction: completeTicketIDs,
		RunE: func(cmd *cobra.Command, args []string) error {
			id := args[0]
			_, l, err := requireTicket(id, true)
			if err != nil {
				return err
			}

			// Seed SPEC.md from Linear when possible — spec itself will
			// auto-fetch LINEAR.md as part of its prelude.
			if !specHasContent(l, id) {
				ui.L().Info("[auto] SPEC.md empty; generating")
				if err := newSpecReal().RunE(cmd, []string{id}); err != nil {
					return err
				}
			}

			// Refuse without a real spec — the loop has nothing to start from.
			if !specHasContent(l, id) {
				return fmt.Errorf("SPEC.md missing or empty; seed it first:\n  forge flux spec %s \"<freeform description>\"", id)
			}

			// Expose retry cap to task/verify so their heartbeat label can
			// show "retry N/M". Env is the lightest channel — alternative
			// is threading a cfg field through common.go for one int.
			_ = os.Setenv("FORGE_RETRY_CAP", strconv.Itoa(retryCap))

			noopIter := 0
			for iter := 1; iter <= maxIter; iter++ {
				s, err := state.Load(l, id)
				if err != nil {
					return err
				}
				phase := state.DerivePhase(l, s)
				ui.L().Info("[auto iter %d] phase=%s", iter, phase)

				switch phase {
				case state.PhaseInit, state.PhaseSpec:
					return fmt.Errorf("spec missing or empty (phase=%s); seed with: forge flux spec %s \"<description>\"", phase, id)
				case state.PhasePlan:
					if err := newPlanReal().RunE(cmd, []string{id}); err != nil {
						return err
					}
				case state.PhaseDecompose:
					if err := newDecomposeReal().RunE(cmd, []string{id}); err != nil {
						return err
					}
				case state.PhaseTasks:
					// Architect debt — a prior task passed the critic but
					// never got an architect verdict — is picked up before
					// new builder work so the pipeline reaches a consistent
					// state before advancing.
					if arch := s.NextArchitect(); arch != nil {
						if arch.RetryCount >= retryCap {
							s.NeedsHuman = &state.NeedsHuman{
								Reason: fmt.Sprintf("Task %s exceeded retry cap (%d) before architect; last verdicts critic=%s arch=%s.", arch.ID, retryCap, arch.Verdict, arch.ArchVerdict),
								TaskID: arch.ID,
								At:     time.Now().UTC(),
							}
							if saveErr := state.Save(l, s); saveErr != nil {
								ui.L().Error("needs_human flag could not be persisted: %v", saveErr)
							}
							ui.L().Error("task %s exceeded retry cap; needs_human flagged", arch.ID)
							return fmt.Errorf("retry cap reached for %s", arch.ID)
						}
						ui.L().Info("[auto iter %d] architect %s (attempt %d/%d)", iter, arch.ID, arch.RetryCount+1, retryCap)
						if err := newArchitectReal().RunE(cmd, []string{id, arch.ID}); err != nil {
							return err
						}
						continue
					}

					next := s.NextPending()
					if next == nil {
						noopIter++
						if noopIter >= 2 {
							return fmt.Errorf("state stuck in phase=tasks with no pending or architect task; run 'forge flux show %s' to inspect", id)
						}
						ui.L().Warn("phase=tasks but no pending task; recomputing")
						continue
					}
					noopIter = 0
					if next.RetryCount >= retryCap {
						s.NeedsHuman = &state.NeedsHuman{
							Reason: fmt.Sprintf("Task %s exceeded retry cap (%d); last verdict %s. See REVIEW.md.", next.ID, retryCap, next.Verdict),
							TaskID: next.ID,
							At:     time.Now().UTC(),
						}
						if saveErr := state.Save(l, s); saveErr != nil {
							ui.L().Error("needs_human flag could not be persisted: %v", saveErr)
						}
						ui.L().Error("task %s exceeded retry cap; needs_human flagged", next.ID)
						return fmt.Errorf("retry cap reached for %s", next.ID)
					}
					ui.L().Info("[auto iter %d] task %s (attempt %d/%d)", iter, next.ID, next.RetryCount+1, retryCap)
					taskErr := newTaskReal().RunE(cmd, []string{id, next.ID})
					if taskErr != nil {
						if errors.Is(taskErr, ErrBuilderNoSummary) || errors.Is(taskErr, ErrBuilderDirty) || errors.Is(taskErr, ErrBuilderNoCommit) {
							s2, loadErr := state.Load(l, id)
							if loadErr != nil {
								return fmt.Errorf("reloading state for retry bump: %w", loadErr)
							}
							if bumpErr := s2.BumpRetry(next.ID); bumpErr != nil {
								ui.L().Warn("bump retry count for %s: %v", next.ID, bumpErr)
							}
							if saveErr := state.Save(l, s2); saveErr != nil {
								ui.L().Warn("persist retry count for %s: %v", next.ID, saveErr)
							}
							ui.L().Warn("builder failure for %s: %v; flipping back to pending", next.ID, taskErr)
							continue
						}
						return taskErr
					}
					if err := newVerifyReal().RunE(cmd, []string{id, next.ID}); err != nil {
						return err
					}
				case state.PhaseComplete:
					ui.L().Info("[auto] all tasks complete")
					if skipRetro {
						ui.L().Info("retro skipped (--skip-retro)")
					} else if err := runRetroIfConfigured(cmd, id); err != nil {
						ui.L().Warn("retro skipped: %v", err)
					}
					ui.L().Info("next: forge flux status %s    (draft today's status)", id)
					ui.L().Info("      forge flux status post %s (post to Linear)", id)
					ui.L().Info("      forge flux pr %s <task>   (open PRs)", id)
					return nil
				default:
					return fmt.Errorf("unexpected phase: %s", phase)
				}
			}
			return fmt.Errorf("max-iter (%d) reached without completion", maxIter)
		},
	}
	c.Flags().IntVar(&maxIter, "max-iter", 50, "overall iteration cap")
	c.Flags().IntVar(&retryCap, "retry-cap", 3, "max retries per task on FAIL")
	c.Flags().BoolVar(&skipRetro, "skip-retro", false, "skip the retrospective phase at ticket completion")
	return c
}

func specHasContent(l state.Layout, id string) bool {
	s, err := state.Load(l, id)
	if err != nil {
		return false
	}
	phase := state.DerivePhase(l, s)
	return phase != state.PhaseInit && phase != state.PhaseSpec
}

// runRetroIfConfigured invokes retro when the repo has a prompts root to
// write to. Returns the original error when retro is not applicable (e.g.
// no FORGE_PROMPTS_ROOT) so auto can log and continue instead of failing.
func runRetroIfConfigured(cmd *cobra.Command, ticketID string) error {
	return newRetroReal().RunE(cmd, []string{ticketID})
}
