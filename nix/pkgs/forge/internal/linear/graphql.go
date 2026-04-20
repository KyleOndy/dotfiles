package linear

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"
)

const linearEndpoint = "https://api.linear.app/graphql"

// AssignedIssue is the shape we cache for completion. Fields beyond these
// aren't used yet; extend the query and struct together when needed.
type AssignedIssue struct {
	Identifier    string     `json:"identifier"`
	Title         string     `json:"title"`
	StateType     string     `json:"stateType"`
	StateName     string     `json:"stateName,omitempty"`
	StatePosition float64    `json:"statePosition,omitempty"`
	Priority      int        `json:"priority,omitempty"`
	CompletedAt   *time.Time `json:"completedAt,omitempty"`
	UpdatedAt     time.Time  `json:"updatedAt"`
}

const assignedIssuesQuery = `query($filter: IssueFilter, $after: String) {
  issues(first: 100, after: $after, filter: $filter) {
    nodes {
      identifier title completedAt updatedAt priority
      state { name type position }
    }
    pageInfo { hasNextPage endCursor }
  }
}`

// FetchAssignedIssues returns issues assigned to the viewer. Active states
// (triage/backlog/unstarted/started) come first, sorted by status
// (closest-to-done → most speculative), then priority (Urgent first), then
// ID ascending. Tickets completed in the last 24h trail at the bottom,
// sorted by ID ascending.
func FetchAssignedIssues(ctx context.Context, apiKey string) ([]AssignedIssue, error) {
	if apiKey == "" {
		return nil, fmt.Errorf("%w: LINEAR_API_KEY not set", MissingAuth)
	}
	client := &http.Client{Timeout: 30 * time.Second}

	active, err := runAssignedQuery(ctx, client, apiKey, activeFilter())
	if err != nil {
		return nil, err
	}
	closedSince := time.Now().Add(-24 * time.Hour).UTC().Format(time.RFC3339)
	closed, err := runAssignedQuery(ctx, client, apiKey, recentlyClosedFilter(closedSince))
	if err != nil {
		return nil, err
	}
	sortActive(active)
	SortByIDAsc(closed)

	// Dedup: an issue that just transitioned to completed a few seconds ago
	// could match both buckets on subsequent refreshes due to clock skew.
	seen := make(map[string]struct{}, len(active))
	out := make([]AssignedIssue, 0, len(active)+len(closed))
	for _, iss := range active {
		if _, ok := seen[iss.Identifier]; ok {
			continue
		}
		seen[iss.Identifier] = struct{}{}
		out = append(out, iss)
	}
	for _, iss := range closed {
		if _, ok := seen[iss.Identifier]; ok {
			continue
		}
		seen[iss.Identifier] = struct{}{}
		out = append(out, iss)
	}
	return out, nil
}

func activeFilter() map[string]any {
	return map[string]any{
		"assignee": map[string]any{"isMe": map[string]any{"eq": true}},
		"state":    map[string]any{"type": map[string]any{"in": []string{"triage", "backlog", "unstarted", "started"}}},
	}
}

func recentlyClosedFilter(since string) map[string]any {
	return map[string]any{
		"assignee":    map[string]any{"isMe": map[string]any{"eq": true}},
		"completedAt": map[string]any{"gt": since},
	}
}

// sortActive orders the active bucket by:
//
//  1. typeRank ASC — started < unstarted < backlog < triage
//  2. statePosition DESC — within same type, later-workflow states first
//     (so "In Review" appears above "In Progress" when both are `started`)
//  3. priorityRank ASC — Urgent (1) first; no-priority (0) last
//  4. ID ASC — numeric on the suffix, lexical on the prefix
func sortActive(xs []AssignedIssue) {
	sort.SliceStable(xs, func(i, j int) bool {
		a, b := xs[i], xs[j]
		if ra, rb := typeRank(a.StateType), typeRank(b.StateType); ra != rb {
			return ra < rb
		}
		if a.StatePosition != b.StatePosition {
			return a.StatePosition > b.StatePosition
		}
		if pa, pb := priorityRank(a.Priority), priorityRank(b.Priority); pa != pb {
			return pa < pb
		}
		return compareIssueIDs(a.Identifier, b.Identifier) < 0
	})
}

func SortByIDAsc(xs []AssignedIssue) {
	sort.SliceStable(xs, func(i, j int) bool {
		return compareIssueIDs(xs[i].Identifier, xs[j].Identifier) < 0
	})
}

func typeRank(t string) int {
	switch t {
	case "started":
		return 1
	case "unstarted":
		return 2
	case "backlog":
		return 3
	case "triage":
		return 4
	default:
		return 99
	}
}

// priorityRank maps Linear's priority (0..4) into a comparable rank. Linear
// uses 0 for "no priority" and 1..4 for Urgent..Low. We want Urgent first and
// "no priority" last, so 0 gets pushed to the end.
func priorityRank(p int) int {
	if p == 0 {
		return 99
	}
	return p
}

// compareIssueIDs orders two Linear-style identifiers like "PROJ-123".
// Splits on the last '-': lexical on the team prefix, integer on the numeric
// suffix. Falls back to full-string lexical compare if either side doesn't
// parse. Returns negative, zero, or positive like strings.Compare.
func compareIssueIDs(a, b string) int {
	ap, an, aok := splitIssueID(a)
	bp, bn, bok := splitIssueID(b)
	if !aok || !bok {
		return strings.Compare(a, b)
	}
	if c := strings.Compare(ap, bp); c != 0 {
		return c
	}
	switch {
	case an < bn:
		return -1
	case an > bn:
		return 1
	default:
		return 0
	}
}

func splitIssueID(id string) (prefix string, num int, ok bool) {
	i := strings.LastIndex(id, "-")
	if i <= 0 || i == len(id)-1 {
		return "", 0, false
	}
	n, err := strconv.Atoi(id[i+1:])
	if err != nil {
		return "", 0, false
	}
	return id[:i], n, true
}

type gqlRequest struct {
	Query     string         `json:"query"`
	Variables map[string]any `json:"variables"`
}

type gqlError struct {
	Message string `json:"message"`
}

type issuesPage struct {
	Data struct {
		Issues struct {
			Nodes []struct {
				Identifier  string     `json:"identifier"`
				Title       string     `json:"title"`
				Priority    float64    `json:"priority"`
				State       *stateNode `json:"state"`
				CompletedAt *time.Time `json:"completedAt"`
				UpdatedAt   time.Time  `json:"updatedAt"`
			} `json:"nodes"`
			PageInfo struct {
				HasNextPage bool   `json:"hasNextPage"`
				EndCursor   string `json:"endCursor"`
			} `json:"pageInfo"`
		} `json:"issues"`
	} `json:"data"`
	Errors []gqlError `json:"errors"`
}

type stateNode struct {
	Name     string  `json:"name"`
	Type     string  `json:"type"`
	Position float64 `json:"position"`
}

func runAssignedQuery(ctx context.Context, client *http.Client, apiKey string, filter map[string]any) ([]AssignedIssue, error) {
	var (
		out    []AssignedIssue
		cursor string
	)
	for {
		vars := map[string]any{"filter": filter}
		if cursor != "" {
			vars["after"] = cursor
		}
		body, err := json.Marshal(gqlRequest{Query: assignedIssuesQuery, Variables: vars})
		if err != nil {
			return nil, fmt.Errorf("marshal graphql request: %w", err)
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, linearEndpoint, bytes.NewReader(body))
		if err != nil {
			return nil, err
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Authorization", apiKey)

		resp, err := client.Do(req)
		if err != nil {
			return nil, fmt.Errorf("linear graphql: %w", err)
		}
		raw, readErr := io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		if readErr != nil {
			return nil, fmt.Errorf("read linear response: %w", readErr)
		}
		if resp.StatusCode/100 != 2 {
			return nil, fmt.Errorf("linear graphql: http %d: %s", resp.StatusCode, truncate(string(raw), 400))
		}
		var page issuesPage
		if err := json.Unmarshal(raw, &page); err != nil {
			return nil, fmt.Errorf("parse linear response: %w", err)
		}
		if len(page.Errors) > 0 {
			return nil, fmt.Errorf("linear graphql: %s", page.Errors[0].Message)
		}
		for _, n := range page.Data.Issues.Nodes {
			var stateType, stateName string
			var statePos float64
			if n.State != nil {
				stateType = n.State.Type
				stateName = n.State.Name
				statePos = n.State.Position
			}
			out = append(out, AssignedIssue{
				Identifier:    n.Identifier,
				Title:         n.Title,
				StateType:     stateType,
				StateName:     stateName,
				StatePosition: statePos,
				Priority:      int(n.Priority + 0.5),
				CompletedAt:   n.CompletedAt,
				UpdatedAt:     n.UpdatedAt,
			})
		}
		if !page.Data.Issues.PageInfo.HasNextPage {
			break
		}
		cursor = page.Data.Issues.PageInfo.EndCursor
		if cursor == "" {
			break
		}
	}
	return out, nil
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
