package cluster

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/kyleondy/dotfiles/forge/internal/ui"
)

// Step is one unit of work in the bring-up DAG. IDs are free-form strings;
// dependencies reference other steps by ID. Fn runs exactly once per step,
// on its own goroutine, after every dep has succeeded.
//
// (Named Step rather than Node to avoid collision with the Kind cluster
// Node type used by Config.)
type Step struct {
	ID    string
	Label string
	Deps  []string
	Fn    func(ctx context.Context) error
}

// StepResult is the final state of one step after DAG execution. Exactly
// one of Skipped or Err is meaningful: Skipped means a required dep
// failed, Err means this step's own Fn failed. Both nil means success.
type StepResult struct {
	ID       string
	Label    string
	Err      error
	Skipped  bool
	Duration time.Duration
}

// ValidateDAG checks the step list for duplicate IDs, missing deps, and
// cycles. Returns nil when the DAG is valid.
func ValidateDAG(steps []Step) error {
	ids := make(map[string]struct{}, len(steps))
	for _, s := range steps {
		if _, dup := ids[s.ID]; dup {
			return fmt.Errorf("duplicate step id %q", s.ID)
		}
		ids[s.ID] = struct{}{}
	}
	for _, s := range steps {
		for _, d := range s.Deps {
			if _, ok := ids[d]; !ok {
				return fmt.Errorf("step %q depends on missing step %q", s.ID, d)
			}
		}
	}
	// Kahn's: count incoming edges, then peel nodes with zero remaining.
	inDegree := make(map[string]int, len(steps))
	dependents := make(map[string][]string, len(steps))
	for _, s := range steps {
		inDegree[s.ID] = len(s.Deps)
		for _, d := range s.Deps {
			dependents[d] = append(dependents[d], s.ID)
		}
	}
	var queue []string
	for id, deg := range inDegree {
		if deg == 0 {
			queue = append(queue, id)
		}
	}
	sort.Strings(queue) // deterministic order for tests
	peeled := 0
	for len(queue) > 0 {
		id := queue[0]
		queue = queue[1:]
		peeled++
		for _, dep := range dependents[id] {
			inDegree[dep]--
			if inDegree[dep] == 0 {
				queue = append(queue, dep)
			}
		}
	}
	if peeled != len(steps) {
		return errors.New("DAG contains a cycle")
	}
	return nil
}

// ExecuteDAG runs a validated DAG with maximum parallelism. Each step's Fn
// runs on its own goroutine once every dep has finished successfully.
// Failed steps cause transitively dependent steps to be marked Skipped.
// Returns per-step results in input order and a non-nil summary error
// when any step failed or was skipped.
func ExecuteDAG(ctx context.Context, steps []Step) ([]StepResult, error) {
	if err := ValidateDAG(steps); err != nil {
		return nil, err
	}

	type state struct {
		step   Step
		result StepResult
		done   chan struct{}
	}
	states := make(map[string]*state, len(steps))
	for _, s := range steps {
		states[s.ID] = &state{
			step:   s,
			result: StepResult{ID: s.ID, Label: s.Label},
			done:   make(chan struct{}),
		}
	}

	var wg sync.WaitGroup
	for _, s := range steps {
		wg.Add(1)
		go func(st *state) {
			defer wg.Done()
			defer close(st.done)
			for _, dep := range st.step.Deps {
				d := states[dep]
				select {
				case <-d.done:
				case <-ctx.Done():
					st.result.Err = ctx.Err()
					return
				}
				if d.result.Err != nil || d.result.Skipped {
					st.result.Skipped = true
					ui.L().Warn("skip %s (dep %s %s)", st.step.ID, dep, depReason(d.result))
					return
				}
			}
			ui.L().Info("start %s: %s", st.step.ID, st.step.Label)
			start := time.Now()
			err := st.step.Fn(ctx)
			st.result.Duration = time.Since(start)
			st.result.Err = err
			if err != nil {
				ui.L().Error("fail %s (%s): %v", st.step.ID, st.result.Duration.Round(time.Millisecond), err)
			} else {
				ui.L().Info("done %s (%s)", st.step.ID, st.result.Duration.Round(time.Millisecond))
			}
		}(states[s.ID])
	}
	wg.Wait()

	out := make([]StepResult, 0, len(steps))
	for _, s := range steps {
		out = append(out, states[s.ID].result)
	}
	return out, summarizeDAG(out)
}

func depReason(r StepResult) string {
	if r.Err != nil {
		return "failed"
	}
	return "skipped"
}

// summarizeDAG returns a joined error if any step failed or was skipped.
// Returns nil when every step succeeded.
func summarizeDAG(results []StepResult) error {
	var errs []error
	var failed, skipped []string
	for _, r := range results {
		if r.Err != nil {
			failed = append(failed, fmt.Sprintf("%s: %v", r.ID, r.Err))
			errs = append(errs, fmt.Errorf("%s: %w", r.ID, r.Err))
		} else if r.Skipped {
			skipped = append(skipped, r.ID)
		}
	}
	if len(failed) == 0 && len(skipped) == 0 {
		return nil
	}
	var b strings.Builder
	if len(failed) > 0 {
		fmt.Fprintf(&b, "%d step(s) failed: %s", len(failed), strings.Join(failed, "; "))
	}
	if len(skipped) > 0 {
		if b.Len() > 0 {
			b.WriteString("; ")
		}
		fmt.Fprintf(&b, "%d step(s) skipped: %s", len(skipped), strings.Join(skipped, ", "))
	}
	return errors.Join(append(errs, errors.New(b.String()))...)
}
