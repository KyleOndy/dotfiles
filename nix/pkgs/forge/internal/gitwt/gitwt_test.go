package gitwt

import (
	"context"
	"errors"
	"strings"
	"testing"
)

// fakeExec records calls and returns canned responses.
type fakeExec struct {
	responses map[string]fakeResponse
	calls     []string
}

type fakeResponse struct {
	out []byte
	err error
}

func (f *fakeExec) Run(_ context.Context, dir, name string, args ...string) ([]byte, error) {
	key := strings.Join(append([]string{name}, args...), " ")
	f.calls = append(f.calls, key)
	r, ok := f.responses[key]
	if !ok {
		return nil, errors.New("no response wired for: " + key)
	}
	return r.out, r.err
}

func TestFindRootParsesWorktreeList(t *testing.T) {
	const out = `worktree /home/me/src/myrepo/main
HEAD abc
branch refs/heads/main

worktree /home/me/src/myrepo/.bare
bare

worktree /home/me/src/myrepo/feature-x
HEAD def
branch refs/heads/feature-x
`
	f := &fakeExec{responses: map[string]fakeResponse{
		"git worktree list --porcelain": {out: []byte(out)},
	}}
	root, err := FindRoot(context.Background(), f, "/anywhere")
	if err != nil {
		t.Fatal(err)
	}
	if root != "/home/me/src/myrepo" {
		t.Errorf("root: got %q want /home/me/src/myrepo", root)
	}
}

func TestFindRootReturnsEmptyWhenNoBare(t *testing.T) {
	const out = `worktree /home/me/src/regular
HEAD abc
branch refs/heads/main
`
	f := &fakeExec{responses: map[string]fakeResponse{
		"git worktree list --porcelain": {out: []byte(out)},
	}}
	root, err := FindRoot(context.Background(), f, "/anywhere")
	if err != nil {
		t.Fatal(err)
	}
	if root != "" {
		t.Errorf("root: got %q want empty", root)
	}
}

func TestRequireRootErrorsOnEmpty(t *testing.T) {
	f := &fakeExec{responses: map[string]fakeResponse{
		"git worktree list --porcelain": {out: []byte("")},
	}}
	if _, err := RequireRoot(context.Background(), f, "/anywhere"); err == nil {
		t.Error("expected error when not in worktree-based repo")
	}
}

func TestDefaultBranchSymbolicRefWins(t *testing.T) {
	f := &fakeExec{responses: map[string]fakeResponse{
		"git symbolic-ref refs/remotes/origin/HEAD --short": {out: []byte("origin/develop\n")},
	}}
	br, err := DefaultBranch(context.Background(), f, "/repo")
	if err != nil {
		t.Fatal(err)
	}
	if br != "origin/develop" {
		t.Errorf("default branch: got %q", br)
	}
}

func TestDefaultBranchFallsBackToMain(t *testing.T) {
	f := &fakeExec{responses: map[string]fakeResponse{
		"git symbolic-ref refs/remotes/origin/HEAD --short":      {err: errors.New("nope")},
		"git show-ref --verify --quiet refs/remotes/origin/main": {},
	}}
	br, _ := DefaultBranch(context.Background(), f, "/repo")
	if br != "origin/main" {
		t.Errorf("default branch: got %q want origin/main", br)
	}
}

func TestListWorktrees(t *testing.T) {
	const out = `worktree /home/me/repo/.bare
bare

worktree /home/me/repo/main
HEAD abc123
branch refs/heads/main

worktree /home/me/repo/ENG-1/T01-do-thing
HEAD def456
branch refs/heads/ENG-1-T01-do-thing

`
	f := &fakeExec{responses: map[string]fakeResponse{
		"git worktree list --porcelain": {out: []byte(out)},
	}}
	wts, err := ListWorktrees(context.Background(), f, "/anywhere")
	if err != nil {
		t.Fatal(err)
	}
	if len(wts) != 3 {
		t.Fatalf("got %d worktrees, want 3", len(wts))
	}
	bare := wts[0]
	if !bare.Bare || bare.Path != "/home/me/repo/.bare" {
		t.Errorf("unexpected bare entry: %+v", bare)
	}
	task := wts[2]
	if task.Path != "/home/me/repo/ENG-1/T01-do-thing" {
		t.Errorf("task path: got %q", task.Path)
	}
	if task.Branch != "refs/heads/ENG-1-T01-do-thing" {
		t.Errorf("task branch: got %q", task.Branch)
	}
}

func TestIsDirtyClean(t *testing.T) {
	f := &fakeExec{responses: map[string]fakeResponse{
		"git status --porcelain": {out: []byte("")},
	}}
	dirty, err := IsDirty(context.Background(), f, "/wt")
	if err != nil {
		t.Fatal(err)
	}
	if dirty {
		t.Error("expected clean")
	}
}

func TestIsDirtyDirty(t *testing.T) {
	f := &fakeExec{responses: map[string]fakeResponse{
		"git status --porcelain": {out: []byte(" M some/file.go\n")},
	}}
	dirty, err := IsDirty(context.Background(), f, "/wt")
	if err != nil {
		t.Fatal(err)
	}
	if !dirty {
		t.Error("expected dirty")
	}
}

func TestHasUnpushedWithUpstream(t *testing.T) {
	f := &fakeExec{responses: map[string]fakeResponse{
		"git rev-list --count @{upstream}..HEAD": {out: []byte("2\n")},
	}}
	up, err := HasUnpushed(context.Background(), f, "/wt")
	if err != nil {
		t.Fatal(err)
	}
	if !up {
		t.Error("expected unpushed")
	}
}

func TestHasUnpushedCleanWithUpstream(t *testing.T) {
	f := &fakeExec{responses: map[string]fakeResponse{
		"git rev-list --count @{upstream}..HEAD": {out: []byte("0\n")},
	}}
	up, err := HasUnpushed(context.Background(), f, "/wt")
	if err != nil {
		t.Fatal(err)
	}
	if up {
		t.Error("expected not unpushed")
	}
}

func TestHasUnpushedNoUpstreamFallsBackToDefault(t *testing.T) {
	f := &fakeExec{responses: map[string]fakeResponse{
		"git rev-list --count @{upstream}..HEAD":            {err: errors.New("no upstream")},
		"git symbolic-ref refs/remotes/origin/HEAD --short": {out: []byte("origin/main\n")},
		"git rev-list --count origin/main..HEAD":            {out: []byte("3\n")},
	}}
	up, err := HasUnpushed(context.Background(), f, "/wt")
	if err != nil {
		t.Fatal(err)
	}
	if !up {
		t.Error("expected unpushed when no upstream and commits ahead of default")
	}
}

func TestRemoveWorktree(t *testing.T) {
	f := &fakeExec{responses: map[string]fakeResponse{
		"git worktree remove /path/to/wt": {},
	}}
	if err := RemoveWorktree(context.Background(), f, "/repo", "/path/to/wt", false); err != nil {
		t.Fatal(err)
	}
}

func TestRemoveWorktreeForce(t *testing.T) {
	f := &fakeExec{responses: map[string]fakeResponse{
		"git worktree remove --force /path/to/wt": {},
	}}
	if err := RemoveWorktree(context.Background(), f, "/repo", "/path/to/wt", true); err != nil {
		t.Fatal(err)
	}
}

func TestDeleteBranch(t *testing.T) {
	f := &fakeExec{responses: map[string]fakeResponse{
		"git branch -d my-branch": {},
	}}
	if err := DeleteBranch(context.Background(), f, "/repo", "my-branch", false); err != nil {
		t.Fatal(err)
	}
}

func TestDeleteBranchForce(t *testing.T) {
	f := &fakeExec{responses: map[string]fakeResponse{
		"git branch -D my-branch": {},
	}}
	if err := DeleteBranch(context.Background(), f, "/repo", "my-branch", true); err != nil {
		t.Fatal(err)
	}
}
