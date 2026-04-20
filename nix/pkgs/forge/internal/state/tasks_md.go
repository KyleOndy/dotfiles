package state

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"time"
)

// taskLineRE matches a TASKS.md checklist item:
//
//   - [ ] T01 wire-up-router: Wire up the router
var taskLineRE = regexp.MustCompile(`^\s*-\s*\[([ xX])\]\s+(T\d+)\s+([a-z0-9-]+)\s*:\s*(.+)$`)

// SyncFromTasksMD parses <root>/TASKS.md and merges tasks into the state.
// New tasks are appended in pending status. Existing tasks (matched by ID)
// keep their status/verdict/retry counts; only the title and slug refresh.
func SyncFromTasksMD(l Layout, s *State) (added int, err error) {
	path := filepath.Join(l.Root, "TASKS.md")
	f, err := os.Open(path)
	if err != nil {
		return 0, fmt.Errorf("open TASKS.md: %w", err)
	}
	defer f.Close()

	now := time.Now().UTC()
	seen := map[string]bool{}
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		m := taskLineRE.FindStringSubmatch(scanner.Text())
		if m == nil {
			continue
		}
		id, slug, title := m[2], m[3], m[4]
		seen[id] = true
		if t, _ := s.Find(id); t != nil {
			t.Slug = slug
			t.Title = title
			continue
		}
		s.Tasks = append(s.Tasks, Task{
			ID:     id,
			Slug:   slug,
			Title:  title,
			Status: StatusPending,
		})
		added++
	}
	if err := scanner.Err(); err != nil {
		return added, fmt.Errorf("scan TASKS.md: %w", err)
	}
	if len(s.Tasks) == 0 {
		return 0, fmt.Errorf("TASKS.md has no recognized task lines (need `- [ ] T0N <slug>: title`)")
	}
	if s.CreatedAt.IsZero() {
		s.CreatedAt = now
	}
	s.SortTasks()
	return added, nil
}
