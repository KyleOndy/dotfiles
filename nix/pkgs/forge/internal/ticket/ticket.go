// Package ticket validates ticket IDs and resolves on-disk paths.
//
// Accepted IDs:
//   - PROJ-123      Linear-style (any uppercase prefix + digits)
//   - ADHOC-<name>  unscoped local work
//   - OR-<name>     org-research notes
//   - ONDY-<name>   personal projects
package ticket

import (
	"errors"
	"fmt"
	"path/filepath"
	"regexp"
)

var (
	linearRE = regexp.MustCompile(`^[A-Z]+-[0-9]+$`)
	localRE  = regexp.MustCompile(`^(ADHOC|OR|ONDY)[-_].+$`)
)

// IsLinear reports whether the ID matches the Linear PROJ-123 shape.
func IsLinear(id string) bool { return linearRE.MatchString(id) }

// Validate returns nil for an acceptable ticket ID.
func Validate(id string) error {
	if id == "" {
		return errors.New("ticket id is required (e.g. PROJ-1019, ADHOC-test)")
	}
	if linearRE.MatchString(id) || localRE.MatchString(id) {
		return nil
	}
	return fmt.Errorf("ticket %q does not match PROJ-123 or ADHOC-* / OR-* / ONDY-* convention", id)
}

// Root returns the per-ticket directory: <ticketsRoot>/<id>.
// Does not create anything; use state.EnsureLayout to scaffold.
func Root(ticketsRoot, id string) string {
	return filepath.Join(ticketsRoot, id)
}

// ForgeDir returns the .forge subdir holding machine state for a ticket.
func ForgeDir(ticketsRoot, id string) string {
	return filepath.Join(Root(ticketsRoot, id), ".forge")
}

// TasksDir returns <root>/tasks where per-task agent artifacts live.
func TasksDir(ticketsRoot, id string) string {
	return filepath.Join(Root(ticketsRoot, id), "tasks")
}

// TaskDir returns <root>/tasks/<id>-<slug> for a specific task.
func TaskDir(ticketsRoot, ticketID, taskID, slug string) string {
	return filepath.Join(TasksDir(ticketsRoot, ticketID), taskID+"-"+slug)
}
