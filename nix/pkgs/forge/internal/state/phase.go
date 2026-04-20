package state

import (
	"os"
	"strings"
)

// DerivePhase returns the orchestrator's current phase. Computed from disk
// + state — never cached. Order:
//
//  1. SPEC.md missing or empty            → init
//  2. SPEC.md has only the template       → spec
//  3. PLAN.md missing or empty            → plan
//  4. No tasks in state.json              → decompose
//  5. Any task with status=pending        → tasks
//  6. Any task with critic PASS but no
//     architect verdict                   → tasks (architect owes work)
//  7. Otherwise                           → complete
func DerivePhase(l Layout, s *State) Phase {
	if !specHasContent(l.SpecPath) {
		if !fileExists(l.SpecPath) {
			return PhaseInit
		}
		return PhaseSpec
	}
	if !planHasContent(l.PlanPath) {
		return PhasePlan
	}
	if len(s.Tasks) == 0 {
		return PhaseDecompose
	}
	if s.NextPending() != nil || s.NextArchitect() != nil {
		return PhaseTasks
	}
	return PhaseComplete
}

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

// specHasContent returns true once SPEC.md has at least one of the six
// required H2 sections. The init scaffold is wrapped in HTML comments and
// has no H2, so it correctly counts as empty.
func specHasContent(p string) bool {
	b, err := os.ReadFile(p)
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(b), "\n") {
		t := strings.TrimSpace(line)
		if !strings.HasPrefix(t, "## ") {
			continue
		}
		title := strings.TrimSpace(strings.TrimPrefix(t, "## "))
		switch {
		case strings.HasPrefix(title, "Outcomes"),
			strings.HasPrefix(title, "In scope"),
			strings.HasPrefix(title, "Out of scope"),
			strings.HasPrefix(title, "Constraints"),
			strings.HasPrefix(title, "Prior decisions"),
			strings.HasPrefix(title, "Verification"):
			return true
		}
	}
	return false
}

// planHasContent returns true once PLAN.md has any H2 heading. The init
// scaffold has none.
func planHasContent(p string) bool {
	b, err := os.ReadFile(p)
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(b), "\n") {
		t := strings.TrimSpace(line)
		if strings.HasPrefix(t, "## ") && len(strings.TrimSpace(strings.TrimPrefix(t, "## "))) > 0 {
			return true
		}
	}
	return false
}
