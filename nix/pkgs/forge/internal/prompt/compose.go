package prompt

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"time"

	"github.com/kyleondy/dotfiles/forge/internal/state"
)

// Composed is a fully rendered prompt plus the file the model's response
// must land in (for backends without tool calls). TargetFile is empty
// when the phase needs tool calls (builder, critic, decompose).
type Composed struct {
	Prompt     string
	TargetFile string // relative to CWD (the ticket root)
}

// readOr returns the file's contents or placeholder when missing/empty.
func readOr(path, placeholder string) string {
	b, err := os.ReadFile(path)
	if err != nil || len(b) == 0 {
		return placeholder
	}
	return string(b)
}

// ComposeSpec renders the spec prompt. Single-file output → SPEC.md.
func ComposeSpec(l state.Layout, ticketID, description string) (Composed, error) {
	existing := readOr(l.SpecPath, "")
	linear := readOr(l.LinearMD, fmt.Sprintf("(none — run `forge flux linear fetch %s` to populate)", ticketID))

	descSlot := description
	if descSlot == "" {
		switch {
		case existing != "":
			descSlot = "(none, revise the existing SPEC.md below)"
		case linear != "" && !isPlaceholder(linear):
			descSlot = "(none, draft the spec from the Linear context below)"
		default:
			return Composed{}, fmt.Errorf("no description, no existing SPEC.md, and no LINEAR.md; provide a description or run `forge flux linear fetch %s`", ticketID)
		}
	}
	if existing == "" {
		existing = "(none, fresh spec)"
	}

	body, err := Render("spec.md", map[string]string{
		"DESCRIPTION":   descSlot,
		"LINEAR":        linear,
		"EXISTING_SPEC": existing,
		"TICKET":        ticketID,
	})
	if err != nil {
		return Composed{}, err
	}
	return Composed{Prompt: body, TargetFile: "SPEC.md"}, nil
}

// ComposePlan renders the plan prompt. Single-file output → PLAN.md.
func ComposePlan(l state.Layout, ticketID string) (Composed, error) {
	spec := readOr(l.SpecPath, "")
	if spec == "" {
		return Composed{}, fmt.Errorf("SPEC.md missing or empty; run `forge flux spec %s` first", ticketID)
	}
	existing := readOr(l.PlanPath, "(none, fresh plan)")
	body, err := Render("plan.md", map[string]string{
		"SPEC":          spec,
		"EXISTING_PLAN": existing,
		"TICKET":        ticketID,
	})
	if err != nil {
		return Composed{}, err
	}
	return Composed{Prompt: body, TargetFile: "PLAN.md"}, nil
}

// ComposeDecompose renders the decompose prompt. Multi-file output (TASKS.md
// plus per-task PLAN.md files) → no TargetFile; needs tool calls.
func ComposeDecompose(l state.Layout, ticketID string) (Composed, error) {
	spec := readOr(l.SpecPath, "")
	if spec == "" {
		return Composed{}, fmt.Errorf("SPEC.md missing or empty")
	}
	plan := readOr(l.PlanPath, "")
	if plan == "" {
		return Composed{}, fmt.Errorf("PLAN.md missing or empty; run `forge flux plan %s` first", ticketID)
	}
	existingTasks := readOr(filepath.Join(l.Root, "TASKS.md"), "(none, fresh decomposition)")
	body, err := Render("decompose.md", map[string]string{
		"SPEC":           spec,
		"PLAN":           plan,
		"EXISTING_TASKS": existingTasks,
		"TICKET":         ticketID,
	})
	if err != nil {
		return Composed{}, err
	}
	return Composed{Prompt: body}, nil
}

// ComposeBuilder renders the builder prompt for a task. Multi-file output
// (SUMMARY.md, code) → needs tool calls; no TargetFile.
func ComposeBuilder(l state.Layout, s *state.State, taskID string) (Composed, error) {
	t, _ := s.Find(taskID)
	if t == nil {
		return Composed{}, fmt.Errorf("task %s not found", taskID)
	}
	taskDir := l.TaskDir(taskID, t.Slug)
	if err := os.MkdirAll(taskDir, 0o755); err != nil {
		return Composed{}, err
	}

	spec := readOr(l.SpecPath, "(no SPEC.md yet)")
	plan := readOr(l.PlanPath, "(no PLAN.md yet)")
	taskPlan := readOr(filepath.Join(taskDir, "PLAN.md"), "(no task plan)")
	decisions := readOr(l.DecPath, "(no decisions logged)")
	prior := readPriorSummaries(l, taskID, t.Slug)

	body, err := Render("builder.md", map[string]string{
		"TASK_ID":         taskID,
		"TASK_SLUG":       t.Slug,
		"SUMMARY_PATH":    filepath.Join(taskDir, "SUMMARY.md"),
		"DECISIONS_PATH":  l.DecPath,
		"SPEC":            spec,
		"PLAN":            plan,
		"TASK_PLAN":       taskPlan,
		"PRIOR_SUMMARIES": prior,
		"DECISIONS":       decisions,
	})
	if err != nil {
		return Composed{}, err
	}
	return Composed{Prompt: body}, nil
}

// ComposeCritic renders the critic prompt for a task. Multi-file output
// (REVIEW.md, VERDICT) → needs tool calls; no TargetFile.
func ComposeCritic(l state.Layout, s *state.State, taskID, worktreePath, diffText string) (Composed, error) {
	t, _ := s.Find(taskID)
	if t == nil {
		return Composed{}, fmt.Errorf("task %s not found", taskID)
	}
	taskDir := l.TaskDir(taskID, t.Slug)
	if err := os.MkdirAll(taskDir, 0o755); err != nil {
		return Composed{}, err
	}
	if diffText == "" {
		diffText = "(no diff available)"
	}

	body, err := Render("critic.md", map[string]string{
		"TASK_ID":         taskID,
		"TASK_SLUG":       t.Slug,
		"REVIEW_PATH":     filepath.Join(taskDir, "REVIEW.md"),
		"VERDICT_PATH":    filepath.Join(taskDir, "VERDICT"),
		"SPEC":            readOr(l.SpecPath, "(no SPEC.md)"),
		"TASK_PLAN":       readOr(filepath.Join(taskDir, "PLAN.md"), "(no task plan)"),
		"BUILDER_SUMMARY": readOr(filepath.Join(taskDir, "SUMMARY.md"), "(no builder summary)"),
		"DIFF":            diffText,
	})
	if err != nil {
		return Composed{}, err
	}
	return Composed{Prompt: body}, nil
}

// ComposeArchitect renders the architect prompt for a task. Multi-file
// output (ARCHITECT.md, ARCH_VERDICT) → needs tool calls; no TargetFile.
func ComposeArchitect(l state.Layout, s *state.State, taskID, worktreePath, diffText string) (Composed, error) {
	t, _ := s.Find(taskID)
	if t == nil {
		return Composed{}, fmt.Errorf("task %s not found", taskID)
	}
	taskDir := l.TaskDir(taskID, t.Slug)
	if err := os.MkdirAll(taskDir, 0o755); err != nil {
		return Composed{}, err
	}
	if diffText == "" {
		diffText = "(no diff available)"
	}

	body, err := Render("architect.md", map[string]string{
		"TASK_ID":           taskID,
		"TASK_SLUG":         t.Slug,
		"ARCHITECT_PATH":    filepath.Join(taskDir, "ARCHITECT.md"),
		"ARCH_VERDICT_PATH": filepath.Join(taskDir, "ARCH_VERDICT"),
		"SPEC":              readOr(l.SpecPath, "(no SPEC.md)"),
		"TASK_PLAN":         readOr(filepath.Join(taskDir, "PLAN.md"), "(no task plan)"),
		"BUILDER_SUMMARY":   readOr(filepath.Join(taskDir, "SUMMARY.md"), "(no builder summary)"),
		"DIFF":              diffText,
		"WORKTREE_PATH":     worktreePath,
		"TICKET_ROOT":       l.Root,
	})
	if err != nil {
		return Composed{}, err
	}
	return Composed{Prompt: body}, nil
}

// ComposeRetro renders the retrospective prompt. Target is the repo-scoped
// common suffix override file that the builder+critic+architect will read
// on future tickets. Caller resolves the target path (depends on config).
func ComposeRetro(l state.Layout, s *state.State, ticketID, targetPath, date string) (Composed, error) {
	if date == "" {
		date = time.Now().Format("2006-01-02")
	}
	spec := readOr(l.SpecPath, "(no SPEC.md)")
	critic := collectReviewArtifacts(l, s, "REVIEW.md")
	if critic == "" {
		critic = "(no critic reviews found)"
	}
	architect := collectReviewArtifacts(l, s, "ARCHITECT.md")
	if architect == "" {
		architect = "(no architect reviews found)"
	}
	existing := readOr(targetPath, "(empty — this is the first retro writing to this file)")

	body, err := Render("retro.md", map[string]string{
		"TICKET":            ticketID,
		"DATE":              date,
		"SPEC":              spec,
		"CRITIC_REVIEWS":    critic,
		"ARCHITECT_REVIEWS": architect,
		"EXISTING_RULES":    existing,
		"TARGET_PATH":       targetPath,
	})
	if err != nil {
		return Composed{}, err
	}
	return Composed{Prompt: body}, nil
}

// collectReviewArtifacts concatenates a named review file (REVIEW.md or
// ARCHITECT.md) across every task, separated by task headers.
func collectReviewArtifacts(l state.Layout, s *state.State, filename string) string {
	var out string
	for _, t := range s.Tasks {
		dir := l.TaskDir(t.ID, t.Slug)
		b, err := os.ReadFile(filepath.Join(dir, filename))
		if err != nil {
			continue
		}
		out += "### " + t.ID + "-" + t.Slug + "\n" + string(b) + "\n\n"
	}
	return out
}

// ComposeStatus renders the status prompt. Single-file output →
// <DATE>-status.md at the ticket root.
func ComposeStatus(l state.Layout, s *state.State, ticketID, date string) (Composed, error) {
	if date == "" {
		date = time.Now().Format("2006-01-02")
	}
	tasks := readOr(filepath.Join(l.Root, "TASKS.md"), "(no TASKS.md)")
	summaries, verdicts := collectTaskOutputs(l, s)
	if summaries == "" {
		summaries = "(no task summaries yet)"
	}
	if verdicts == "" {
		verdicts = "(no verdicts yet)"
	}
	priorStatus := findPriorStatus(l.Root, date)

	body, err := Render("status.md", map[string]string{
		"TICKET":         ticketID,
		"DATE":           date,
		"SPEC":           readOr(l.SpecPath, "(no spec)"),
		"TASKS":          tasks,
		"TASK_SUMMARIES": summaries,
		"TASK_VERDICTS":  verdicts,
		"PRIOR_STATUS":   priorStatus,
	})
	if err != nil {
		return Composed{}, err
	}
	return Composed{Prompt: body, TargetFile: date + "-status.md"}, nil
}

// ComposeIterateSpec renders the bootstrap prompt for an interactive spec
// session. Multi-turn — no TargetFile.
func ComposeIterateSpec(l state.Layout, ticketID string) (Composed, error) {
	if !fileExistsNonEmpty(l.SpecPath) {
		return Composed{}, fmt.Errorf("SPEC.md missing or empty; run `forge flux spec %s` first", ticketID)
	}
	linearNote := "(not present — run `forge flux linear fetch " + ticketID + "` to pull it)"
	if fileExistsNonEmpty(l.LinearMD) {
		linearNote = "present at ./LINEAR.md"
	}
	planNote := "(not present — later phase)"
	if fileExistsNonEmpty(l.PlanPath) {
		planNote = "present at ./PLAN.md"
	}
	body, err := Render("iterate-spec.md", map[string]string{
		"TICKET":      ticketID,
		"LINEAR_NOTE": linearNote,
		"PLAN_NOTE":   planNote,
	})
	if err != nil {
		return Composed{}, err
	}
	return Composed{Prompt: body}, nil
}

// ComposeIteratePlan renders the bootstrap prompt for an interactive plan
// session.
func ComposeIteratePlan(l state.Layout, ticketID string) (Composed, error) {
	if !fileExistsNonEmpty(l.PlanPath) {
		return Composed{}, fmt.Errorf("PLAN.md missing or empty; run `forge flux plan %s` first", ticketID)
	}
	tasksNote := "(not present — run `forge flux decompose " + ticketID + "` to populate)"
	if fileExistsNonEmpty(filepath.Join(l.Root, "TASKS.md")) {
		tasksNote = "present at ./TASKS.md"
	}
	body, err := Render("iterate-plan.md", map[string]string{
		"TICKET":     ticketID,
		"TASKS_NOTE": tasksNote,
	})
	if err != nil {
		return Composed{}, err
	}
	return Composed{Prompt: body}, nil
}

// readPriorSummaries returns concatenated SUMMARY.md content for every
// task other than (taskID, slug), in lex order by directory name.
func readPriorSummaries(l state.Layout, taskID, slug string) string {
	current := taskID + "-" + slug
	entries, err := os.ReadDir(l.TasksDir)
	if err != nil {
		return "(no prior tasks completed)"
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() && e.Name() != current {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)

	var out string
	for _, name := range names {
		path := filepath.Join(l.TasksDir, name, "SUMMARY.md")
		b, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		out += "### " + name + "\n" + string(b) + "\n\n"
	}
	if out == "" {
		return "(no prior tasks completed)"
	}
	return out
}

// collectTaskOutputs concatenates SUMMARY.md content and VERDICT lines for
// the status compose phase.
func collectTaskOutputs(l state.Layout, s *state.State) (summaries, verdicts string) {
	for _, t := range s.Tasks {
		dir := l.TaskDir(t.ID, t.Slug)
		if b, err := os.ReadFile(filepath.Join(dir, "SUMMARY.md")); err == nil {
			summaries += "### " + t.ID + "-" + t.Slug + "\n" + string(b) + "\n\n"
		}
		if t.Verdict != state.VerdictNone {
			verdicts += t.ID + "-" + t.Slug + ": " + string(t.Verdict) + "\n"
		}
	}
	return summaries, verdicts
}

// findPriorStatus returns the most recent <date>-status.md other than today's.
func findPriorStatus(root, today string) string {
	entries, err := os.ReadDir(root)
	if err != nil {
		return "(no prior status)"
	}
	var candidates []string
	for _, e := range entries {
		n := e.Name()
		if e.IsDir() || len(n) < len("YYYY-MM-DD-status.md") {
			continue
		}
		if n == today+"-status.md" {
			continue
		}
		// Loose check: ends with "-status.md".
		if filepath.Ext(n) != ".md" {
			continue
		}
		// Heuristic: starts with a digit (date).
		if n[0] < '0' || n[0] > '9' {
			continue
		}
		candidates = append(candidates, n)
	}
	if len(candidates) == 0 {
		return "(no prior status)"
	}
	sort.Strings(candidates)
	last := candidates[len(candidates)-1]
	b, err := os.ReadFile(filepath.Join(root, last))
	if err != nil {
		return "(no prior status)"
	}
	return last + ":\n\n" + string(b)
}

func fileExistsNonEmpty(p string) bool {
	st, err := os.Stat(p)
	return err == nil && !st.IsDir() && st.Size() > 0
}

func isPlaceholder(s string) bool {
	return len(s) > 0 && s[0] == '('
}
