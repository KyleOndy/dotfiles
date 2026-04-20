package state

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func setupTicket(t *testing.T) (Layout, string) {
	t.Helper()
	root := t.TempDir()
	l := LayoutFor(root, "ENG-1")
	if err := EnsureLayout(l); err != nil {
		t.Fatal(err)
	}
	return l, root
}

func TestSlugify(t *testing.T) {
	cases := []struct{ in, want string }{
		{"Wire up the router", "wire-up-the-router"},
		{"Fix auth bypass!!", "fix-auth-bypass"},
		{"  ---  hello  ---  ", "hello"},
		{"A very long task title that exceeds the forty character limit", "a-very-long-task-title-that-exceeds-the"},
	}
	for _, c := range cases {
		if got := Slugify(c.in); got != c.want {
			t.Errorf("Slugify(%q): got %q want %q", c.in, got, c.want)
		}
	}
}

func TestLoadFreshState(t *testing.T) {
	l, _ := setupTicket(t)
	s, err := Load(l, "ENG-1")
	if err != nil {
		t.Fatal(err)
	}
	if s.Ticket != "ENG-1" {
		t.Errorf("Ticket: got %q", s.Ticket)
	}
	if len(s.Tasks) != 0 {
		t.Errorf("Tasks: expected empty, got %d", len(s.Tasks))
	}
	if s.Version != StateVersion {
		t.Errorf("Version: got %d", s.Version)
	}
}

func TestSaveAndRoundTrip(t *testing.T) {
	l, _ := setupTicket(t)
	s, _ := Load(l, "ENG-1")
	s.Tasks = []Task{{ID: "T01", Slug: "wire", Title: "Wire it up", Status: StatusPending}}
	if err := Save(l, s); err != nil {
		t.Fatal(err)
	}
	got, err := Load(l, "ENG-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Tasks) != 1 || got.Tasks[0].ID != "T01" {
		t.Errorf("round-trip lost tasks: %+v", got.Tasks)
	}
	if got.UpdatedAt.IsZero() {
		t.Error("UpdatedAt not stamped on Save")
	}
}

func TestSaveAtomicViaTempfile(t *testing.T) {
	l, _ := setupTicket(t)
	s, _ := Load(l, "ENG-1")
	if err := Save(l, s); err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(l.ForgeDir)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if filepath.Ext(e.Name()) == ".tmp" {
			t.Errorf("tempfile leaked: %s", e.Name())
		}
	}
}

func TestSetVerdictFailIncrementsRetry(t *testing.T) {
	l, _ := setupTicket(t)
	s, _ := Load(l, "ENG-1")
	s.Tasks = []Task{{ID: "T01", Slug: "x", Title: "x", Status: StatusDone}}
	if err := s.SetVerdict("T01", VerdictFail); err != nil {
		t.Fatal(err)
	}
	if s.Tasks[0].RetryCount != 1 {
		t.Errorf("RetryCount: got %d want 1", s.Tasks[0].RetryCount)
	}
	if s.Tasks[0].Status != StatusPending {
		t.Errorf("Status: should flip to pending after FAIL; got %s", s.Tasks[0].Status)
	}
}

func TestSetVerdictPassPreservesDone(t *testing.T) {
	l, _ := setupTicket(t)
	s, _ := Load(l, "ENG-1")
	s.Tasks = []Task{{ID: "T01", Slug: "x", Title: "x", Status: StatusDone}}
	if err := s.SetVerdict("T01", VerdictPass); err != nil {
		t.Fatal(err)
	}
	if s.Tasks[0].RetryCount != 0 {
		t.Errorf("RetryCount: PASS should not increment; got %d", s.Tasks[0].RetryCount)
	}
	if s.Tasks[0].Status != StatusDone {
		t.Errorf("Status: PASS should keep done; got %s", s.Tasks[0].Status)
	}
}

func TestNextPending(t *testing.T) {
	s := &State{Tasks: []Task{
		{ID: "T01", Status: StatusDone},
		{ID: "T02", Status: StatusPending},
		{ID: "T03", Status: StatusPending},
	}}
	n := s.NextPending()
	if n == nil || n.ID != "T02" {
		t.Errorf("NextPending: got %+v want T02", n)
	}
}

func TestSyncFromTasksMD(t *testing.T) {
	l, _ := setupTicket(t)
	const md = `# Tasks for ENG-1

- [ ] T01 wire-up: Wire up the router
- [x] T02 add-loader: Add the loader
- [ ] T03 migrate-fixtures: Convert fixtures

(some other text)
`
	if err := os.WriteFile(filepath.Join(l.Root, "TASKS.md"), []byte(md), 0o644); err != nil {
		t.Fatal(err)
	}
	s, _ := Load(l, "ENG-1")
	added, err := SyncFromTasksMD(l, s)
	if err != nil {
		t.Fatal(err)
	}
	if added != 3 {
		t.Errorf("added: got %d want 3", added)
	}
	if len(s.Tasks) != 3 {
		t.Fatalf("tasks: got %d want 3", len(s.Tasks))
	}
	if s.Tasks[0].Slug != "wire-up" || s.Tasks[1].Title != "Add the loader" {
		t.Errorf("parse mismatch: %+v", s.Tasks)
	}
	// All tasks come back as pending — sync does not import done state from
	// the markdown checkbox; that's the agent's responsibility to declare.
	for _, tt := range s.Tasks {
		if tt.Status != StatusPending {
			t.Errorf("expected pending for %s; got %s", tt.ID, tt.Status)
		}
	}
}

func TestSyncPreservesExistingState(t *testing.T) {
	l, _ := setupTicket(t)
	const md = `- [ ] T01 wire-up: Wire up the router
- [ ] T02 add-loader: Add the loader (revised title)
`
	if err := os.WriteFile(filepath.Join(l.Root, "TASKS.md"), []byte(md), 0o644); err != nil {
		t.Fatal(err)
	}
	s, _ := Load(l, "ENG-1")
	s.Tasks = []Task{{ID: "T01", Slug: "wire-up", Title: "old", Status: StatusDone, Verdict: VerdictPass, RetryCount: 2}}
	if _, err := SyncFromTasksMD(l, s); err != nil {
		t.Fatal(err)
	}
	t01, _ := s.Find("T01")
	if t01.Status != StatusDone || t01.Verdict != VerdictPass || t01.RetryCount != 2 {
		t.Errorf("existing state lost: %+v", t01)
	}
	if t01.Title != "Wire up the router" {
		t.Errorf("title should refresh from markdown; got %q", t01.Title)
	}
}

func TestDerivePhase(t *testing.T) {
	l, _ := setupTicket(t)
	s, _ := Load(l, "ENG-1")

	if got := DerivePhase(l, s); got != PhaseInit {
		t.Errorf("phase: got %s want init", got)
	}

	// Empty SPEC.md (template only).
	if err := os.WriteFile(l.SpecPath, []byte("<!-- template -->\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := DerivePhase(l, s); got != PhaseSpec {
		t.Errorf("phase: got %s want spec", got)
	}

	// Real SPEC.md, missing PLAN.md.
	if err := os.WriteFile(l.SpecPath, []byte("## Outcomes\n\nThings happen\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := DerivePhase(l, s); got != PhasePlan {
		t.Errorf("phase: got %s want plan", got)
	}

	// Real PLAN.md, no tasks.
	if err := os.WriteFile(l.PlanPath, []byte("## Approach\n\nDo it\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := DerivePhase(l, s); got != PhaseDecompose {
		t.Errorf("phase: got %s want decompose", got)
	}

	// One pending task.
	s.Tasks = []Task{{ID: "T01", Status: StatusPending}}
	if got := DerivePhase(l, s); got != PhaseTasks {
		t.Errorf("phase: got %s want tasks", got)
	}

	// Critic PASS but architect unrun: still in tasks.
	s.Tasks = []Task{{ID: "T01", Status: StatusDone, Verdict: VerdictPass}}
	if got := DerivePhase(l, s); got != PhaseTasks {
		t.Errorf("phase: got %s want tasks (architect owes work)", got)
	}

	// All done + critic PASS + architect PASS.
	s.Tasks = []Task{{ID: "T01", Status: StatusDone, Verdict: VerdictPass, ArchVerdict: VerdictPass}}
	if got := DerivePhase(l, s); got != PhaseComplete {
		t.Errorf("phase: got %s want complete", got)
	}
}

func TestSetArchVerdictFailClearsCriticAndRetries(t *testing.T) {
	l, _ := setupTicket(t)
	s, _ := Load(l, "ENG-1")
	s.Tasks = []Task{{ID: "T01", Slug: "x", Title: "x", Status: StatusDone, Verdict: VerdictPass}}
	if err := s.SetArchVerdict("T01", VerdictFail); err != nil {
		t.Fatal(err)
	}
	got := s.Tasks[0]
	if got.ArchVerdict != VerdictFail {
		t.Errorf("ArchVerdict: got %s want FAIL", got.ArchVerdict)
	}
	if got.Verdict != VerdictNone {
		t.Errorf("Verdict: architect FAIL should clear prior critic PASS; got %s", got.Verdict)
	}
	if got.Status != StatusPending {
		t.Errorf("Status: architect FAIL should flip to pending; got %s", got.Status)
	}
	if got.RetryCount != 1 {
		t.Errorf("RetryCount: got %d want 1", got.RetryCount)
	}
}

func TestSetArchVerdictPassPreservesDone(t *testing.T) {
	l, _ := setupTicket(t)
	s, _ := Load(l, "ENG-1")
	s.Tasks = []Task{{ID: "T01", Slug: "x", Title: "x", Status: StatusDone, Verdict: VerdictPass}}
	if err := s.SetArchVerdict("T01", VerdictPass); err != nil {
		t.Fatal(err)
	}
	got := s.Tasks[0]
	if got.ArchVerdict != VerdictPass || got.Verdict != VerdictPass || got.Status != StatusDone {
		t.Errorf("PASS should keep state: %+v", got)
	}
}

func TestNextArchitect(t *testing.T) {
	s := &State{Tasks: []Task{
		{ID: "T01", Status: StatusDone, Verdict: VerdictPass, ArchVerdict: VerdictPass},
		{ID: "T02", Status: StatusDone, Verdict: VerdictPass},
		{ID: "T03", Status: StatusPending},
	}}
	n := s.NextArchitect()
	if n == nil || n.ID != "T02" {
		t.Errorf("NextArchitect: got %+v want T02", n)
	}
}

func TestAllTasksDoneRequiresArchPass(t *testing.T) {
	s := &State{Tasks: []Task{
		{ID: "T01", Status: StatusDone, Verdict: VerdictPass, ArchVerdict: VerdictPass},
		{ID: "T02", Status: StatusDone, Verdict: VerdictPass},
	}}
	if s.AllTasksDone() {
		t.Error("AllTasksDone: should be false while any task lacks ArchVerdict=PASS")
	}
	s.Tasks[1].ArchVerdict = VerdictPass
	if !s.AllTasksDone() {
		t.Error("AllTasksDone: should be true when every task has both verdicts PASS")
	}
}

func TestBumpRetry(t *testing.T) {
	s := &State{Tasks: []Task{
		{ID: "T01", Slug: "x", Title: "x", Status: StatusPending, Verdict: VerdictNone, RetryCount: 0},
	}}
	if err := s.BumpRetry("T01"); err != nil {
		t.Fatal(err)
	}
	got := s.Tasks[0]
	if got.RetryCount != 1 {
		t.Errorf("RetryCount: got %d want 1", got.RetryCount)
	}
	if got.Status != StatusPending {
		t.Errorf("Status: should stay pending; got %s", got.Status)
	}
	if got.Verdict != VerdictNone {
		t.Errorf("Verdict: should be untouched; got %s", got.Verdict)
	}
	// Calling again increments further.
	_ = s.BumpRetry("T01")
	if s.Tasks[0].RetryCount != 2 {
		t.Errorf("second BumpRetry: got %d want 2", s.Tasks[0].RetryCount)
	}
}

func TestResetAllTasks(t *testing.T) {
	now := time.Now()
	s := &State{
		NeedsHuman: &NeedsHuman{Reason: "stuck"},
		Tasks: []Task{
			{ID: "T01", Status: StatusDone, Verdict: VerdictPass, ArchVerdict: VerdictPass, RetryCount: 2, LastVerifiedAt: &now},
			{ID: "T02", Status: StatusDone, Verdict: VerdictFail, ArchVerdict: VerdictNone, RetryCount: 3, LastArchAt: &now},
			{ID: "T03", Status: StatusPending, Verdict: VerdictNone, RetryCount: 0},
		},
	}
	s.ResetAllTasks()

	if s.NeedsHuman != nil {
		t.Error("NeedsHuman should be cleared")
	}
	for _, tt := range s.Tasks {
		if tt.Status != StatusPending {
			t.Errorf("%s: status=%s want pending", tt.ID, tt.Status)
		}
		if tt.Verdict != VerdictNone {
			t.Errorf("%s: verdict=%q want empty", tt.ID, tt.Verdict)
		}
		if tt.ArchVerdict != VerdictNone {
			t.Errorf("%s: arch_verdict=%q want empty", tt.ID, tt.ArchVerdict)
		}
		if tt.RetryCount != 0 {
			t.Errorf("%s: retry_count=%d want 0", tt.ID, tt.RetryCount)
		}
		if tt.LastVerifiedAt != nil {
			t.Errorf("%s: last_verified_at should be nil", tt.ID)
		}
		if tt.LastArchAt != nil {
			t.Errorf("%s: last_arch_at should be nil", tt.ID)
		}
	}
}
