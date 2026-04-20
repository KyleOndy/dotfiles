package prompt

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadOverrides_Empty(t *testing.T) {
	tmp := t.TempDir()
	ov := LoadOverrides(tmp, "repo", "plan")
	if ov.Prefix != "" || ov.Suffix != "" || len(ov.Sources) != 0 {
		t.Fatalf("expected zero Overrides, got %+v", ov)
	}
}

func TestLoadOverrides_EmptyInputs(t *testing.T) {
	if ov := LoadOverrides("", "repo", "plan"); ov.Prefix != "" || ov.Suffix != "" {
		t.Fatalf("empty root should produce zero")
	}
	if ov := LoadOverrides("/tmp", "", "plan"); ov.Prefix != "" {
		t.Fatalf("empty repo should produce zero")
	}
	if ov := LoadOverrides("/tmp", "repo", ""); ov.Prefix != "" {
		t.Fatalf("empty phase should produce zero")
	}
}

func TestLoadOverrides_PhaseOnly(t *testing.T) {
	tmp := t.TempDir()
	repo := "myrepo"
	dir := filepath.Join(tmp, repo)
	mkdir(t, dir)
	writeFile(t, filepath.Join(dir, "plan.prefix.md"), "Always add tests.\n")
	writeFile(t, filepath.Join(dir, "plan.suffix.md"), "Run benchmarks when relevant.\n\n")

	ov := LoadOverrides(tmp, repo, "plan")
	if ov.Prefix != "Always add tests." {
		t.Errorf("prefix = %q", ov.Prefix)
	}
	if ov.Suffix != "Run benchmarks when relevant." {
		t.Errorf("suffix = %q", ov.Suffix)
	}
	want := []string{"myrepo/plan.prefix.md", "myrepo/plan.suffix.md"}
	if !equalStrings(ov.Sources, want) {
		t.Errorf("sources = %v, want %v", ov.Sources, want)
	}
}

func TestLoadOverrides_CommonAndPhase(t *testing.T) {
	tmp := t.TempDir()
	repo := "myrepo"
	dir := filepath.Join(tmp, repo)
	mkdir(t, dir)
	writeFile(t, filepath.Join(dir, "_common.prefix.md"), "COMMON-PRE")
	writeFile(t, filepath.Join(dir, "_common.suffix.md"), "COMMON-SUF")
	writeFile(t, filepath.Join(dir, "plan.prefix.md"), "PLAN-PRE")
	writeFile(t, filepath.Join(dir, "plan.suffix.md"), "PLAN-SUF")

	ov := LoadOverrides(tmp, repo, "plan")
	if ov.Prefix != "COMMON-PRE\n\nPLAN-PRE" {
		t.Errorf("prefix = %q", ov.Prefix)
	}
	if ov.Suffix != "PLAN-SUF\n\nCOMMON-SUF" {
		t.Errorf("suffix = %q", ov.Suffix)
	}
	want := []string{
		"myrepo/_common.prefix.md",
		"myrepo/plan.prefix.md",
		"myrepo/plan.suffix.md",
		"myrepo/_common.suffix.md",
	}
	if !equalStrings(ov.Sources, want) {
		t.Errorf("sources = %v, want %v", ov.Sources, want)
	}
}

func TestLoadOverrides_PhaseScoping(t *testing.T) {
	// plan.* files must not leak into the spec phase.
	tmp := t.TempDir()
	repo := "myrepo"
	dir := filepath.Join(tmp, repo)
	mkdir(t, dir)
	writeFile(t, filepath.Join(dir, "plan.prefix.md"), "PLAN-PRE")
	writeFile(t, filepath.Join(dir, "spec.suffix.md"), "SPEC-SUF")

	ov := LoadOverrides(tmp, repo, "spec")
	if ov.Prefix != "" {
		t.Errorf("spec phase picked up plan prefix: %q", ov.Prefix)
	}
	if ov.Suffix != "SPEC-SUF" {
		t.Errorf("suffix = %q", ov.Suffix)
	}
}

func TestApply(t *testing.T) {
	cases := []struct {
		name string
		ov   Overrides
		base string
		want string
	}{
		{
			name: "empty overrides returns base unchanged",
			ov:   Overrides{},
			base: "BASE\n",
			want: "BASE\n",
		},
		{
			name: "prefix only",
			ov:   Overrides{Prefix: "PRE"},
			base: "BASE",
			want: "PRE\n\nBASE",
		},
		{
			name: "suffix only",
			ov:   Overrides{Suffix: "SUF"},
			base: "BASE",
			want: "BASE\n\nSUF",
		},
		{
			name: "both",
			ov:   Overrides{Prefix: "PRE", Suffix: "SUF"},
			base: "BASE",
			want: "PRE\n\nBASE\n\nSUF",
		},
		{
			name: "trailing whitespace on base is trimmed when wrapping",
			ov:   Overrides{Prefix: "PRE"},
			base: "BASE\n\n",
			want: "PRE\n\nBASE",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := c.ov.Apply(c.base)
			if got != c.want {
				t.Errorf("Apply()\n got %q\nwant %q", got, c.want)
			}
		})
	}
}

func TestDetectRepo_Empty(t *testing.T) {
	if got := DetectRepo(""); got != "" {
		t.Errorf("empty cwd → %q, want empty", got)
	}
}

func TestDetectRepo_NonGitFallsBackToBasename(t *testing.T) {
	tmp := t.TempDir()
	sub := filepath.Join(tmp, "some-project")
	mkdir(t, sub)
	got := DetectRepo(sub)
	if got != "some-project" {
		t.Errorf("non-git cwd → %q, want some-project", got)
	}
}

func TestDetectRepo_GitToplevelWins(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not on PATH")
	}
	tmp := t.TempDir()
	repo := filepath.Join(tmp, "myrepo")
	sub := filepath.Join(repo, "deep", "sub", "dir")
	mkdir(t, sub)
	run(t, repo, "git", "init", "-q")

	// From a nested subdir, we should still resolve to the toplevel basename.
	got := DetectRepo(sub)
	if got != "myrepo" {
		t.Errorf("git toplevel detection → %q, want myrepo", got)
	}
}

// --- helpers ---

func mkdir(t *testing.T, p string) {
	t.Helper()
	if err := os.MkdirAll(p, 0o755); err != nil {
		t.Fatal(err)
	}
}

func writeFile(t *testing.T, p, content string) {
	t.Helper()
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func run(t *testing.T, dir, name string, args ...string) {
	t.Helper()
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	// Keep git quiet about user.name/email by setting stubs for the test.
	cmd.Env = append(os.Environ(),
		"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t",
		"GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t",
	)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("%s %s: %v: %s", name, strings.Join(args, " "), err, out)
	}
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
