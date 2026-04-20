package prompt

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/kyleondy/dotfiles/forge/internal/state"
)

func TestRenderSubstitutes(t *testing.T) {
	out, err := Render("spec.md", map[string]string{
		"DESCRIPTION":   "Make X work",
		"LINEAR":        "linear context here",
		"EXISTING_SPEC": "(none, fresh spec)",
		"TICKET":        "ENG-1",
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "Make X work") {
		t.Errorf("DESCRIPTION not substituted")
	}
	if strings.Contains(out, "{{DESCRIPTION}}") {
		t.Errorf("placeholder still present")
	}
}

func TestRenderUnknownTemplate(t *testing.T) {
	if _, err := Render("nonexistent.md", nil); err == nil {
		t.Error("expected error for missing template")
	}
}

func TestNamesIncludesExpected(t *testing.T) {
	names := Names()
	want := []string{"builder.md", "critic.md", "decompose.md", "iterate-plan.md", "iterate-spec.md", "plan.md", "spec.md", "status.md"}
	got := map[string]bool{}
	for _, n := range names {
		got[n] = true
	}
	for _, w := range want {
		if !got[w] {
			t.Errorf("missing template: %s", w)
		}
	}
}

func TestComposeSpecSetsTargetFile(t *testing.T) {
	root := t.TempDir()
	l := state.LayoutFor(root, "ENG-1")
	if err := state.EnsureLayout(l); err != nil {
		t.Fatal(err)
	}
	c, err := ComposeSpec(l, "ENG-1", "test description")
	if err != nil {
		t.Fatal(err)
	}
	if c.TargetFile != "SPEC.md" {
		t.Errorf("TargetFile: got %q want SPEC.md", c.TargetFile)
	}
	if !strings.Contains(c.Prompt, "test description") {
		t.Error("description missing from prompt")
	}
}

func TestComposeSpecRefusesEmptyInput(t *testing.T) {
	root := t.TempDir()
	l := state.LayoutFor(root, "ENG-1")
	state.EnsureLayout(l)
	if _, err := ComposeSpec(l, "ENG-1", ""); err == nil {
		t.Error("expected error when no description, no SPEC.md, no LINEAR.md")
	}
}

func TestComposePlanRequiresSpec(t *testing.T) {
	root := t.TempDir()
	l := state.LayoutFor(root, "ENG-1")
	state.EnsureLayout(l)
	if _, err := ComposePlan(l, "ENG-1"); err == nil {
		t.Error("expected error when SPEC.md missing")
	}
	// With SPEC.md present, succeeds.
	os.WriteFile(l.SpecPath, []byte("## Outcomes\n\nx\n"), 0o644)
	c, err := ComposePlan(l, "ENG-1")
	if err != nil {
		t.Fatal(err)
	}
	if c.TargetFile != "PLAN.md" {
		t.Errorf("TargetFile: got %q", c.TargetFile)
	}
}

func TestComposeBuilderHasNoTargetFile(t *testing.T) {
	root := t.TempDir()
	l := state.LayoutFor(root, "ENG-1")
	state.EnsureLayout(l)
	s := &state.State{Tasks: []state.Task{{ID: "T01", Slug: "wire", Title: "Wire it", Status: state.StatusPending}}}
	c, err := ComposeBuilder(l, s, "T01")
	if err != nil {
		t.Fatal(err)
	}
	if c.TargetFile != "" {
		t.Errorf("Builder TargetFile should be empty (needs tools); got %q", c.TargetFile)
	}
	if !strings.Contains(c.Prompt, "T01") {
		t.Error("task ID not substituted")
	}
}

func TestComposeStatusFilenameIncludesDate(t *testing.T) {
	root := t.TempDir()
	l := state.LayoutFor(root, "ENG-1")
	state.EnsureLayout(l)
	s := &state.State{Tasks: []state.Task{}}
	c, err := ComposeStatus(l, s, "ENG-1", "2026-04-18")
	if err != nil {
		t.Fatal(err)
	}
	if c.TargetFile != "2026-04-18-status.md" {
		t.Errorf("TargetFile: got %q want 2026-04-18-status.md", c.TargetFile)
	}
}

func TestComposeBuilderIncludesPriorSummaries(t *testing.T) {
	root := t.TempDir()
	l := state.LayoutFor(root, "ENG-1")
	state.EnsureLayout(l)

	// Pre-existing summary for T01.
	t01 := l.TaskDir("T01", "earlier")
	os.MkdirAll(t01, 0o755)
	os.WriteFile(filepath.Join(t01, "SUMMARY.md"), []byte("did it"), 0o644)

	s := &state.State{Tasks: []state.Task{
		{ID: "T01", Slug: "earlier", Title: "Earlier", Status: state.StatusDone},
		{ID: "T02", Slug: "current", Title: "Current", Status: state.StatusPending},
	}}
	c, err := ComposeBuilder(l, s, "T02")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(c.Prompt, "T01-earlier") {
		t.Error("prior task summary missing")
	}
	if !strings.Contains(c.Prompt, "did it") {
		t.Error("prior summary content missing")
	}
}
