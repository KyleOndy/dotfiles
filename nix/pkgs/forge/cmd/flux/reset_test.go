package flux

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/kyleondy/dotfiles/forge/internal/gitwt"
	"github.com/kyleondy/dotfiles/forge/internal/state"
)

// fakeExec for flux-level tests — same pattern as gitwt_test.go but in this package.
type fakeExec struct {
	responses map[string]fakeResponse
}

type fakeResponse struct {
	out []byte
	err error
}

func (f *fakeExec) Run(_ context.Context, dir, name string, args ...string) ([]byte, error) {
	key := strings.Join(append([]string{name}, args...), " ")
	r, ok := f.responses[key]
	if !ok {
		return nil, errors.New("no response wired: " + key + " (dir=" + dir + ")")
	}
	return r.out, r.err
}

var _ gitwt.Executor = (*fakeExec)(nil)

// wtListOut builds a minimal porcelain output for a single worktree entry.
func wtListOut(entries []struct{ path, branch string }) string {
	var sb strings.Builder
	for _, e := range entries {
		sb.WriteString("worktree " + e.path + "\nHEAD abc\nbranch refs/heads/" + e.branch + "\n\n")
	}
	return sb.String()
}

func makeState(ticket string, tasks []state.Task) *state.State {
	return &state.State{
		Version: state.StateVersion,
		Ticket:  ticket,
		Tasks:   tasks,
	}
}

func TestForgeTargetsAllTasks(t *testing.T) {
	s := makeState("ENG-1", []state.Task{
		{ID: "T01", Slug: "wire-up"},
		{ID: "T02", Slug: "add-tests"},
	})
	targets := forgeTargets("/root", s, "")
	if len(targets) != 2 {
		t.Fatalf("got %d targets, want 2", len(targets))
	}
	if targets[0].path != "/root/ENG-1/T01-wire-up" {
		t.Errorf("path: %q", targets[0].path)
	}
	if targets[0].branch != "ENG-1-T01-wire-up" {
		t.Errorf("branch: %q", targets[0].branch)
	}
}

func TestForgeTargetsSingleTask(t *testing.T) {
	s := makeState("ENG-1", []state.Task{
		{ID: "T01", Slug: "wire-up"},
		{ID: "T02", Slug: "add-tests"},
	})
	targets := forgeTargets("/root", s, "T01")
	if len(targets) != 1 {
		t.Fatalf("got %d targets, want 1", len(targets))
	}
	if targets[0].branch != "ENG-1-T01-wire-up" {
		t.Errorf("branch: %q", targets[0].branch)
	}
}

func TestForgeTargetsNoTasks(t *testing.T) {
	s := makeState("ENG-1", nil)
	targets := forgeTargets("/root", s, "")
	if len(targets) != 0 {
		t.Fatalf("expected no targets, got %d", len(targets))
	}
}

func TestCleanForgeArtifactsRemovesBoth(t *testing.T) {
	s := makeState("ENG-1", []state.Task{
		{ID: "T01", Slug: "wire-up"},
	})
	wtOut := wtListOut([]struct{ path, branch string }{
		{"/root/ENG-1/T01-wire-up", "ENG-1-T01-wire-up"},
	})
	f := &fakeExec{responses: map[string]fakeResponse{
		"git worktree list --porcelain":               {out: []byte(wtOut)},
		"git status --porcelain":                      {out: []byte("")},
		"git rev-list --count @{upstream}..HEAD":      {out: []byte("0\n")},
		"git worktree remove /root/ENG-1/T01-wire-up": {},
		"git branch -d ENG-1-T01-wire-up":             {},
	}}
	err := cleanForgeArtifacts(context.Background(), f, "/repo", "/root", s, "", false)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestCleanForgeArtifactsRefusesDirty(t *testing.T) {
	s := makeState("ENG-1", []state.Task{
		{ID: "T01", Slug: "wire-up"},
	})
	wtOut := wtListOut([]struct{ path, branch string }{
		{"/root/ENG-1/T01-wire-up", "ENG-1-T01-wire-up"},
	})
	f := &fakeExec{responses: map[string]fakeResponse{
		"git worktree list --porcelain": {out: []byte(wtOut)},
		"git status --porcelain":        {out: []byte(" M dirty.go\n")},
	}}
	err := cleanForgeArtifacts(context.Background(), f, "/repo", "/root", s, "", false)
	if err == nil {
		t.Fatal("expected error for dirty worktree")
	}
	if !strings.Contains(err.Error(), "uncommitted changes") {
		t.Errorf("error should mention uncommitted changes: %v", err)
	}
}

func TestCleanForgeArtifactsRefusesUnpushed(t *testing.T) {
	s := makeState("ENG-1", []state.Task{
		{ID: "T01", Slug: "wire-up"},
	})
	wtOut := wtListOut([]struct{ path, branch string }{
		{"/root/ENG-1/T01-wire-up", "ENG-1-T01-wire-up"},
	})
	f := &fakeExec{responses: map[string]fakeResponse{
		"git worktree list --porcelain":          {out: []byte(wtOut)},
		"git status --porcelain":                 {out: []byte("")},
		"git rev-list --count @{upstream}..HEAD": {out: []byte("1\n")},
	}}
	err := cleanForgeArtifacts(context.Background(), f, "/repo", "/root", s, "", false)
	if err == nil {
		t.Fatal("expected error for unpushed commits")
	}
	if !strings.Contains(err.Error(), "unpushed commits") {
		t.Errorf("error should mention unpushed commits: %v", err)
	}
}

func TestCleanForgeArtifactsForceDirty(t *testing.T) {
	s := makeState("ENG-1", []state.Task{
		{ID: "T01", Slug: "wire-up"},
	})
	wtOut := wtListOut([]struct{ path, branch string }{
		{"/root/ENG-1/T01-wire-up", "ENG-1-T01-wire-up"},
	})
	f := &fakeExec{responses: map[string]fakeResponse{
		"git worktree list --porcelain":                       {out: []byte(wtOut)},
		"git worktree remove --force /root/ENG-1/T01-wire-up": {},
		"git branch -D ENG-1-T01-wire-up":                     {},
	}}
	err := cleanForgeArtifacts(context.Background(), f, "/repo", "/root", s, "", true)
	if err != nil {
		t.Fatalf("force should succeed: %v", err)
	}
}

func TestCleanForgeArtifactsNoWorktreeOnDisk(t *testing.T) {
	s := makeState("ENG-1", []state.Task{
		{ID: "T01", Slug: "wire-up"},
	})
	// Worktree list shows a different (human-made) worktree, not the forge one.
	wtOut := wtListOut([]struct{ path, branch string }{
		{"/root/ENG-1/manual-poke", "ENG-1-manual-poke"},
	})
	f := &fakeExec{responses: map[string]fakeResponse{
		"git worktree list --porcelain": {out: []byte(wtOut)},
	}}
	err := cleanForgeArtifacts(context.Background(), f, "/repo", "/root", s, "", false)
	if err != nil {
		t.Fatalf("should be no-op when worktree not on disk: %v", err)
	}
}

func TestCleanForgeArtifactsSingleTaskScope(t *testing.T) {
	s := makeState("ENG-1", []state.Task{
		{ID: "T01", Slug: "wire-up"},
		{ID: "T02", Slug: "add-tests"},
	})
	// Both worktrees exist on disk.
	wtOut := wtListOut([]struct{ path, branch string }{
		{"/root/ENG-1/T01-wire-up", "ENG-1-T01-wire-up"},
		{"/root/ENG-1/T02-add-tests", "ENG-1-T02-add-tests"},
	})
	f := &fakeExec{responses: map[string]fakeResponse{
		"git worktree list --porcelain":               {out: []byte(wtOut)},
		"git status --porcelain":                      {out: []byte("")},
		"git rev-list --count @{upstream}..HEAD":      {out: []byte("0\n")},
		"git worktree remove /root/ENG-1/T01-wire-up": {},
		"git branch -d ENG-1-T01-wire-up":             {},
	}}
	// Only T01 should be cleaned.
	err := cleanForgeArtifacts(context.Background(), f, "/repo", "/root", s, "T01", false)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	// T02 verification is implicit: fakeExec returns an error for any unwired
	// command, so the t.Fatalf above would have caught it.
}

func TestCleanForgeArtifactsNoTasks(t *testing.T) {
	s := makeState("ENG-1", nil)
	f := &fakeExec{responses: map[string]fakeResponse{}}
	err := cleanForgeArtifacts(context.Background(), f, "/repo", "/root", s, "", false)
	if err != nil {
		t.Fatalf("no-op with no tasks: %v", err)
	}
}
