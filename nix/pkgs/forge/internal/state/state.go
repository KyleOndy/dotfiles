// Package state owns the on-disk ledger for a ticket.
//
// The canonical machine state is .forge/state.json under the ticket dir.
// Mutations write atomically (tempfile + rename). Phase is computed on
// read from the artifacts on disk plus the task list — never stored.
package state

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"time"
)

const StateVersion = 1

// Status of a single task.
type Status string

const (
	StatusPending Status = "pending"
	StatusDone    Status = "done"
)

// Verdict assigned by the critic. Empty until verify runs.
type Verdict string

const (
	VerdictNone Verdict = ""
	VerdictPass Verdict = "PASS"
	VerdictFail Verdict = "FAIL"
)

// Task is one decomposed unit of work.
type Task struct {
	ID               string     `json:"id"`
	Slug             string     `json:"slug"`
	Title            string     `json:"title"`
	Status           Status     `json:"status"`
	Verdict          Verdict    `json:"verdict"`
	ArchVerdict      Verdict    `json:"arch_verdict"`
	RetryCount       int        `json:"retry_count"`
	LastDispatchedAt *time.Time `json:"last_dispatched_at,omitempty"`
	LastVerifiedAt   *time.Time `json:"last_verified_at,omitempty"`
	LastArchAt       *time.Time `json:"last_arch_at,omitempty"`
}

// NeedsHuman is set when the auto loop bails out and wants attention.
type NeedsHuman struct {
	Reason string    `json:"reason"`
	TaskID string    `json:"task_id,omitempty"`
	At     time.Time `json:"at"`
}

// State is the full ledger persisted to .forge/state.json.
type State struct {
	Version    int         `json:"version"`
	Ticket     string      `json:"ticket"`
	Tasks      []Task      `json:"tasks"`
	NeedsHuman *NeedsHuman `json:"needs_human,omitempty"`
	CreatedAt  time.Time   `json:"created_at"`
	UpdatedAt  time.Time   `json:"updated_at"`
}

// Phase is the orchestrator's current step for a ticket.
type Phase string

const (
	PhaseInit      Phase = "init"
	PhaseSpec      Phase = "spec"
	PhasePlan      Phase = "plan"
	PhaseDecompose Phase = "decompose"
	PhaseTasks     Phase = "tasks"
	PhaseComplete  Phase = "complete"
)

// Layout names the on-disk paths for a single ticket.
type Layout struct {
	Root      string // <tickets_root>/<ticket>
	ForgeDir  string // <root>/.forge
	StatePath string // <root>/.forge/state.json
	EventsDir string // <root>/.forge/events
	LocksDir  string // <root>/.forge/locks
	TasksDir  string // <root>/tasks
	SpecPath  string // <root>/SPEC.md
	PlanPath  string // <root>/PLAN.md
	DecPath   string // <root>/DECISIONS.md
	LinearMD  string // <root>/LINEAR.md
}

// LayoutFor builds the path bundle for a ticket. Pure; does not touch disk.
func LayoutFor(ticketsRoot, ticketID string) Layout {
	root := filepath.Join(ticketsRoot, ticketID)
	forge := filepath.Join(root, ".forge")
	return Layout{
		Root:      root,
		ForgeDir:  forge,
		StatePath: filepath.Join(forge, "state.json"),
		EventsDir: filepath.Join(forge, "events"),
		LocksDir:  filepath.Join(forge, "locks"),
		TasksDir:  filepath.Join(root, "tasks"),
		SpecPath:  filepath.Join(root, "SPEC.md"),
		PlanPath:  filepath.Join(root, "PLAN.md"),
		DecPath:   filepath.Join(root, "DECISIONS.md"),
		LinearMD:  filepath.Join(root, "LINEAR.md"),
	}
}

// EnsureLayout creates every directory needed for a ticket. Idempotent.
func EnsureLayout(l Layout) error {
	for _, d := range []string{l.ForgeDir, l.EventsDir, l.LocksDir, l.TasksDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return fmt.Errorf("mkdir %s: %w", d, err)
		}
	}
	return nil
}

// Load reads state.json. Returns a fresh zero-tasks State if absent.
func Load(l Layout, ticketID string) (*State, error) {
	b, err := os.ReadFile(l.StatePath)
	if err != nil {
		if os.IsNotExist(err) {
			now := time.Now().UTC()
			return &State{
				Version:   StateVersion,
				Ticket:    ticketID,
				Tasks:     []Task{},
				CreatedAt: now,
				UpdatedAt: now,
			}, nil
		}
		return nil, fmt.Errorf("read state: %w", err)
	}
	var s State
	if err := json.Unmarshal(b, &s); err != nil {
		return nil, fmt.Errorf("parse state: %w", err)
	}
	if s.Version != StateVersion {
		return nil, fmt.Errorf("state version %d not supported (want %d)", s.Version, StateVersion)
	}
	return &s, nil
}

// Save writes state.json atomically: tempfile in same dir, then rename.
func Save(l Layout, s *State) error {
	if err := os.MkdirAll(l.ForgeDir, 0o755); err != nil {
		return fmt.Errorf("mkdir forge dir: %w", err)
	}
	s.UpdatedAt = time.Now().UTC()
	b, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal state: %w", err)
	}
	tmp, err := os.CreateTemp(l.ForgeDir, "state-*.json.tmp")
	if err != nil {
		return fmt.Errorf("tempfile: %w", err)
	}
	if _, err := tmp.Write(b); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return fmt.Errorf("write tempfile: %w", err)
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		return fmt.Errorf("close tempfile: %w", err)
	}
	if err := os.Rename(tmp.Name(), l.StatePath); err != nil {
		os.Remove(tmp.Name())
		return fmt.Errorf("rename: %w", err)
	}
	return nil
}

// Find returns the task by ID and its index, or (nil, -1).
func (s *State) Find(taskID string) (*Task, int) {
	for i := range s.Tasks {
		if s.Tasks[i].ID == taskID {
			return &s.Tasks[i], i
		}
	}
	return nil, -1
}

// NextPending returns the first pending task, or nil if none.
func (s *State) NextPending() *Task {
	for i := range s.Tasks {
		if s.Tasks[i].Status == StatusPending {
			return &s.Tasks[i]
		}
	}
	return nil
}

// NextArchitect returns the first task that has critic PASS but no architect
// verdict yet. These are tasks where the builder+critic completed but the
// architect phase has not run; they should be picked up before any remaining
// pending work so the pipeline reaches a consistent state.
func (s *State) NextArchitect() *Task {
	for i := range s.Tasks {
		t := &s.Tasks[i]
		if t.Status == StatusDone && t.Verdict == VerdictPass && t.ArchVerdict == VerdictNone {
			return t
		}
	}
	return nil
}

// MarkDone flips a task to done and stamps last_dispatched_at.
func (s *State) MarkDone(taskID string) error {
	t, _ := s.Find(taskID)
	if t == nil {
		return fmt.Errorf("task %s not found", taskID)
	}
	t.Status = StatusDone
	now := time.Now().UTC()
	t.LastDispatchedAt = &now
	return nil
}

// MarkPending flips a task back to pending. Verdict and retry_count are
// preserved; the verifier or reset path manages those separately.
func (s *State) MarkPending(taskID string) error {
	t, _ := s.Find(taskID)
	if t == nil {
		return fmt.Errorf("task %s not found", taskID)
	}
	t.Status = StatusPending
	return nil
}

// BumpRetry increments retry_count and resets status to pending. Used when the
// builder itself failed (no commit, dirty worktree, missing summary) before the
// critic ran — same net state transition as a critic FAIL without touching Verdict.
func (s *State) BumpRetry(taskID string) error {
	t, _ := s.Find(taskID)
	if t == nil {
		return fmt.Errorf("task %s not found", taskID)
	}
	t.RetryCount++
	t.Status = StatusPending
	return nil
}

// SetVerdict records the critic's call and updates retry_count on FAIL.
func (s *State) SetVerdict(taskID string, v Verdict) error {
	t, _ := s.Find(taskID)
	if t == nil {
		return fmt.Errorf("task %s not found", taskID)
	}
	t.Verdict = v
	now := time.Now().UTC()
	t.LastVerifiedAt = &now
	if v == VerdictFail {
		t.RetryCount++
		t.Status = StatusPending
	}
	return nil
}

// SetArchVerdict records the architect's call. On FAIL, clears the prior
// critic PASS so the task re-enters the full builder→critic→architect
// sequence; architect findings feed the next builder via per-task PLAN.md.
func (s *State) SetArchVerdict(taskID string, v Verdict) error {
	t, _ := s.Find(taskID)
	if t == nil {
		return fmt.Errorf("task %s not found", taskID)
	}
	t.ArchVerdict = v
	now := time.Now().UTC()
	t.LastArchAt = &now
	if v == VerdictFail {
		t.RetryCount++
		t.Status = StatusPending
		t.Verdict = VerdictNone
	}
	return nil
}

// ResetTask clears verdict and retry count. Used by `forge flux reset`.
func (s *State) ResetTask(taskID string) error {
	t, _ := s.Find(taskID)
	if t == nil {
		return fmt.Errorf("task %s not found", taskID)
	}
	t.Verdict = VerdictNone
	t.ArchVerdict = VerdictNone
	t.RetryCount = 0
	t.Status = StatusPending
	t.LastVerifiedAt = nil
	t.LastArchAt = nil
	return nil
}

// ResetAll clears verdict + retry on every task with FAIL; preserves PASS.
// Mirrors the global reset semantics.
func (s *State) ResetAll() {
	s.NeedsHuman = nil
	for i := range s.Tasks {
		t := &s.Tasks[i]
		t.RetryCount = 0
		if t.Verdict == VerdictFail {
			t.Verdict = VerdictNone
			t.Status = StatusPending
		}
		if t.ArchVerdict == VerdictFail {
			t.ArchVerdict = VerdictNone
			t.Status = StatusPending
		}
	}
}

// ResetAllTasks resets every task unconditionally — including PASS — back to
// pending. Used by `forge flux reset --all` when the caller wants a clean run
// from T01 rather than just re-driving failed tasks.
func (s *State) ResetAllTasks() {
	s.NeedsHuman = nil
	for i := range s.Tasks {
		t := &s.Tasks[i]
		t.Verdict = VerdictNone
		t.ArchVerdict = VerdictNone
		t.RetryCount = 0
		t.Status = StatusPending
		t.LastVerifiedAt = nil
		t.LastArchAt = nil
	}
}

// TaskDir returns the per-task artifact dir under <root>/tasks/<id>-<slug>.
func (l Layout) TaskDir(taskID, slug string) string {
	return filepath.Join(l.TasksDir, taskID+"-"+slug)
}

// AllTasksDone reports whether every task has status=done with both critic
// and architect PASS.
func (s *State) AllTasksDone() bool {
	if len(s.Tasks) == 0 {
		return false
	}
	for _, t := range s.Tasks {
		if t.Status != StatusDone || t.Verdict != VerdictPass || t.ArchVerdict != VerdictPass {
			return false
		}
	}
	return true
}

// SortTasks orders tasks by ID lex (T01, T02, ..., T10).
func (s *State) SortTasks() {
	sort.SliceStable(s.Tasks, func(i, j int) bool { return s.Tasks[i].ID < s.Tasks[j].ID })
}
