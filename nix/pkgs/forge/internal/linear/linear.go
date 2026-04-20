// Package linear wraps the `linear` CLI for ticket fetch and comment posting.
package linear

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"strings"
)

// Executor is the seam for tests.
type Executor interface {
	Run(ctx context.Context, dir string, name string, args ...string) ([]byte, []byte, error)
}

type cmdExecutor struct{}

func (cmdExecutor) Run(ctx context.Context, dir, name string, args ...string) ([]byte, []byte, error) {
	c := exec.CommandContext(ctx, name, args...)
	if dir != "" {
		c.Dir = dir
	}
	var out, errBuf strings.Builder
	c.Stdout = &out
	c.Stderr = &errBuf
	err := c.Run()
	return []byte(out.String()), []byte(errBuf.String()), err
}

// Default returns an Executor backed by os/exec.
func Default() Executor { return cmdExecutor{} }

// FetchIssueJSON returns the raw JSON for a Linear issue. The CLI is
// invoked from the given dir so any attachments it downloads land there.
func FetchIssueJSON(ctx context.Context, exe Executor, attachmentsDir, ticketID string) ([]byte, error) {
	out, _, err := exe.Run(ctx, attachmentsDir, "linear", "issue", "view", ticketID, "--json", "--no-pager")
	if err != nil {
		return nil, fmt.Errorf("linear issue view %s failed: %w", ticketID, err)
	}
	return out, nil
}

// IssueToMarkdown formats Linear's JSON shape into a stable markdown
// document. Comment shape can be either a top-level array or an object
// with .nodes; both are handled.
func IssueToMarkdown(raw []byte) (string, error) {
	var issue struct {
		Identifier  string `json:"identifier"`
		Title       string `json:"title"`
		URL         string `json:"url"`
		Description string `json:"description"`
		State       any    `json:"state"`
		Assignee    any    `json:"assignee"`
		Comments    any    `json:"comments"`
	}
	if err := json.Unmarshal(raw, &issue); err != nil {
		return "", fmt.Errorf("parse linear json: %w", err)
	}

	state := unwrap(issue.State, "name", "(unknown)")
	assignee := unwrapMulti(issue.Assignee, []string{"name", "displayName"}, "(unassigned)")
	id := issue.Identifier
	if id == "" {
		id = "(unknown)"
	}

	var b strings.Builder
	fmt.Fprintf(&b, "# Linear: %s\n\n", id)
	fmt.Fprintf(&b, "**Title:** %s\n", orPlaceholder(issue.Title, "(no title)"))
	fmt.Fprintf(&b, "**State:** %s\n", state)
	fmt.Fprintf(&b, "**Assignee:** %s\n", assignee)
	fmt.Fprintf(&b, "**URL:** %s\n\n", issue.URL)
	fmt.Fprintf(&b, "## Description\n\n%s\n\n", orPlaceholder(issue.Description, "(no description)"))
	fmt.Fprintf(&b, "## Recent comments\n\n")

	comments := extractComments(issue.Comments)
	if len(comments) == 0 {
		fmt.Fprintln(&b, "(no comments)")
		return b.String(), nil
	}
	for _, c := range comments {
		fmt.Fprintf(&b, "### %s -- %s\n\n%s\n\n", c.Author, c.Date, c.Body)
	}
	return b.String(), nil
}

type comment struct {
	Author string
	Date   string
	Body   string
}

func extractComments(in any) []comment {
	var raw []any
	switch v := in.(type) {
	case []any:
		raw = v
	case map[string]any:
		nodes, _ := v["nodes"].([]any)
		raw = nodes
	}
	out := make([]comment, 0, len(raw))
	for _, r := range raw {
		m, _ := r.(map[string]any)
		if m == nil {
			continue
		}
		c := comment{
			Author: unwrapMulti(m["user"], []string{"name", "displayName"}, "(unknown)"),
			Body:   strFromAny(m["body"]),
		}
		if date := strFromAny(m["createdAt"]); len(date) >= 10 {
			c.Date = date[:10]
		}
		out = append(out, c)
	}
	// Newest first by raw date string (ISO-8601 sorts correctly).
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	return out
}

// PostComment runs `linear issue comment add <ticket> --body <body>`.
func PostComment(ctx context.Context, exe Executor, ticketID, body string) error {
	_, errBuf, err := exe.Run(ctx, "", "linear", "issue", "comment", "add", ticketID, "--body", body)
	if err != nil {
		return fmt.Errorf("linear issue comment add: %w (%s)", err, strings.TrimSpace(string(errBuf)))
	}
	return nil
}

// MissingAuth is returned when the linear CLI binary or API key is unavailable.
var MissingAuth = errors.New("linear CLI or LINEAR_API_KEY missing")

// Preflight checks that the linear CLI is on PATH and an API key is set.
func Preflight(apiKey string) error {
	if _, err := exec.LookPath("linear"); err != nil {
		return fmt.Errorf("%w: linear CLI not found", MissingAuth)
	}
	if apiKey == "" {
		return fmt.Errorf("%w: LINEAR_API_KEY not set", MissingAuth)
	}
	return nil
}

// helpers ---------------------------------------------------------------

func orPlaceholder(s, ph string) string {
	if s == "" {
		return ph
	}
	return s
}

func strFromAny(v any) string {
	s, _ := v.(string)
	return s
}

func unwrap(v any, key, ph string) string {
	if s, ok := v.(string); ok && s != "" {
		return s
	}
	if m, ok := v.(map[string]any); ok {
		if s, ok := m[key].(string); ok && s != "" {
			return s
		}
	}
	return ph
}

func unwrapMulti(v any, keys []string, ph string) string {
	m, ok := v.(map[string]any)
	if !ok {
		return ph
	}
	for _, k := range keys {
		if s, ok := m[k].(string); ok && s != "" {
			return s
		}
	}
	return ph
}
