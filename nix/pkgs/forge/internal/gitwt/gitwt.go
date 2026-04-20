// Package gitwt resolves the worktree-based repo root and shells out to
// git for branch detection and per-task worktree creation.
//
// "Worktree-based" here means a layout with a .bare directory holding the
// git data and per-branch checkouts as siblings, e.g.:
//
//	~/src/myrepo/
//	  .bare/
//	  main/
//	  ENG-1234/T01-wire-up/
package gitwt

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"
)

// Executor is the seam for tests. Production uses os/exec.
type Executor interface {
	Run(ctx context.Context, dir string, name string, args ...string) ([]byte, error)
}

type cmdExecutor struct{}

func (cmdExecutor) Run(ctx context.Context, dir, name string, args ...string) ([]byte, error) {
	c := exec.CommandContext(ctx, name, args...)
	if dir != "" {
		c.Dir = dir
	}
	return c.CombinedOutput()
}

// Default returns an Executor backed by os/exec.
func Default() Executor { return cmdExecutor{} }

// FindRoot returns the worktree root for the cwd, or an empty string when
// not inside a worktree-based repo.
//
// Strategy: parse `git worktree list --porcelain` output, find the entry
// whose path ends in `/.bare`, and return its parent dir.
func FindRoot(ctx context.Context, exe Executor, cwd string) (string, error) {
	out, err := exe.Run(ctx, cwd, "git", "worktree", "list", "--porcelain")
	if err != nil {
		return "", fmt.Errorf("git worktree list: %w", err)
	}
	scanner := bufio.NewScanner(strings.NewReader(string(out)))
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "worktree ") {
			continue
		}
		path := strings.TrimPrefix(line, "worktree ")
		if strings.HasSuffix(path, "/.bare") {
			return strings.TrimSuffix(path, "/.bare"), nil
		}
	}
	return "", nil
}

// RequireRoot returns the worktree root or an actionable error.
func RequireRoot(ctx context.Context, exe Executor, cwd string) (string, error) {
	root, err := FindRoot(ctx, exe, cwd)
	if err != nil {
		return "", err
	}
	if root == "" {
		return "", errors.New("not inside a worktree-based repository (no .bare found); set up with `git wt-clone <url>`")
	}
	return root, nil
}

// DefaultBranch returns the upstream's default branch ref (e.g. "origin/main").
// Falls back to "origin/main" when nothing else is detectable.
func DefaultBranch(ctx context.Context, exe Executor, cwd string) (string, error) {
	if out, err := exe.Run(ctx, cwd, "git", "symbolic-ref", "refs/remotes/origin/HEAD", "--short"); err == nil {
		return strings.TrimSpace(string(out)), nil
	}
	if _, err := exe.Run(ctx, cwd, "git", "show-ref", "--verify", "--quiet", "refs/remotes/origin/main"); err == nil {
		return "origin/main", nil
	}
	if _, err := exe.Run(ctx, cwd, "git", "show-ref", "--verify", "--quiet", "refs/remotes/origin/master"); err == nil {
		return "origin/master", nil
	}
	return "origin/main", nil
}

// CreateFeatureBranch shells out to `git wt-feature-branch <ticket> <name>`,
// which creates a branch and a worktree under <root>/<ticket>/<name>.
// Returns the worktree path.
func CreateFeatureBranch(ctx context.Context, exe Executor, cwd, ticket, name string) (string, error) {
	if _, err := exe.Run(ctx, cwd, "git", "wt-feature-branch", ticket, name); err != nil {
		return "", fmt.Errorf("git wt-feature-branch %s %s: %w", ticket, name, err)
	}
	root, err := RequireRoot(ctx, exe, cwd)
	if err != nil {
		return "", err
	}
	return root + "/" + ticket + "/" + name, nil
}

// CurrentBranch returns the current branch in dir.
func CurrentBranch(ctx context.Context, exe Executor, dir string) (string, error) {
	out, err := exe.Run(ctx, dir, "git", "rev-parse", "--abbrev-ref", "HEAD")
	if err != nil {
		return "", fmt.Errorf("git rev-parse: %w", err)
	}
	return strings.TrimSpace(string(out)), nil
}

// UpstreamRef returns the upstream branch ref for the current HEAD, or the
// repo default branch if no upstream is set.
func UpstreamRef(ctx context.Context, exe Executor, dir string) (string, error) {
	if out, err := exe.Run(ctx, dir, "git", "rev-parse", "--abbrev-ref", "@{upstream}"); err == nil {
		return strings.TrimSpace(string(out)), nil
	}
	return DefaultBranch(ctx, exe, dir)
}

// Diff returns `git diff <baseRef>...HEAD` for dir. Empty string when there
// are no committed changes vs base.
func Diff(ctx context.Context, exe Executor, dir, baseRef string) (string, error) {
	out, err := exe.Run(ctx, dir, "git", "diff", baseRef+"...HEAD")
	if err != nil {
		return "", fmt.Errorf("git diff: %w", err)
	}
	return string(out), nil
}

// DisableSigning sets commit.gpgsign and tag.gpgsign to false in dir, so
// agent-driven commits don't trigger pinentry under non-interactive
// dispatch. Best effort; errors are returned but most callers ignore them.
func DisableSigning(ctx context.Context, exe Executor, dir string) error {
	if _, err := exe.Run(ctx, dir, "git", "config", "commit.gpgsign", "false"); err != nil {
		return err
	}
	_, err := exe.Run(ctx, dir, "git", "config", "tag.gpgsign", "false")
	return err
}

// Worktree represents one entry from `git worktree list --porcelain`.
type Worktree struct {
	Path   string
	HEAD   string
	Branch string // empty when detached
	Bare   bool
}

// ListWorktrees parses `git worktree list --porcelain` and returns all entries.
func ListWorktrees(ctx context.Context, exe Executor, cwd string) ([]Worktree, error) {
	out, err := exe.Run(ctx, cwd, "git", "worktree", "list", "--porcelain")
	if err != nil {
		return nil, fmt.Errorf("git worktree list: %w", err)
	}
	var wts []Worktree
	var cur Worktree
	scanner := bufio.NewScanner(strings.NewReader(string(out)))
	for scanner.Scan() {
		line := scanner.Text()
		switch {
		case strings.HasPrefix(line, "worktree "):
			if cur.Path != "" {
				wts = append(wts, cur)
			}
			cur = Worktree{Path: strings.TrimPrefix(line, "worktree ")}
		case strings.HasPrefix(line, "HEAD "):
			cur.HEAD = strings.TrimPrefix(line, "HEAD ")
		case strings.HasPrefix(line, "branch "):
			cur.Branch = strings.TrimPrefix(line, "branch ")
		case line == "bare":
			cur.Bare = true
		}
	}
	if cur.Path != "" {
		wts = append(wts, cur)
	}
	return wts, nil
}

// IsDirty reports whether dir has uncommitted changes (staged or unstaged).
func IsDirty(ctx context.Context, exe Executor, dir string) (bool, error) {
	out, err := exe.Run(ctx, dir, "git", "status", "--porcelain")
	if err != nil {
		return false, fmt.Errorf("git status: %w", err)
	}
	return strings.TrimSpace(string(out)) != "", nil
}

// HasUnpushed reports whether dir has commits not present on its upstream.
// When no upstream is configured, it compares against the repo default branch,
// so a branch that was never pushed is always considered unpushed.
func HasUnpushed(ctx context.Context, exe Executor, dir string) (bool, error) {
	out, err := exe.Run(ctx, dir, "git", "rev-list", "--count", "@{upstream}..HEAD")
	if err != nil {
		// No upstream — compare against default branch.
		def, defErr := DefaultBranch(ctx, exe, dir)
		if defErr != nil {
			return true, nil // can't tell; assume unpushed
		}
		out, err = exe.Run(ctx, dir, "git", "rev-list", "--count", def+"..HEAD")
		if err != nil {
			return true, nil
		}
	}
	n := strings.TrimSpace(string(out))
	return n != "" && n != "0", nil
}

// RemoveWorktree removes a linked worktree. Pass force=true to use --force.
func RemoveWorktree(ctx context.Context, exe Executor, cwd, path string, force bool) error {
	args := []string{"worktree", "remove"}
	if force {
		args = append(args, "--force")
	}
	args = append(args, path)
	if _, err := exe.Run(ctx, cwd, "git", args...); err != nil {
		return fmt.Errorf("git worktree remove %s: %w", path, err)
	}
	return nil
}

// DeleteBranch deletes a branch. Pass force=true to use -D (force-delete
// even if not merged); false uses -d (refuses if unmerged).
func DeleteBranch(ctx context.Context, exe Executor, cwd, branch string, force bool) error {
	flag := "-d"
	if force {
		flag = "-D"
	}
	if _, err := exe.Run(ctx, cwd, "git", "branch", flag, branch); err != nil {
		return fmt.Errorf("git branch %s %s: %w", flag, branch, err)
	}
	return nil
}
