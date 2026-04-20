package cluster

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"
)

// RunResult is the captured output from one external command.
type RunResult struct {
	Stdout   string
	Stderr   string
	ExitCode int
}

// Executor is the seam for shelling out to docker / kind / kubectl. Tests
// swap in a fake; production uses os/exec.
type Executor interface {
	Run(ctx context.Context, name string, args ...string) (RunResult, error)
}

type execExecutor struct{}

// DefaultExecutor returns a production Executor backed by os/exec.
func DefaultExecutor() Executor { return execExecutor{} }

func (execExecutor) Run(ctx context.Context, name string, args ...string) (RunResult, error) {
	c := exec.CommandContext(ctx, name, args...)
	var out, errbuf bytes.Buffer
	c.Stdout = &out
	c.Stderr = &errbuf
	err := c.Run()
	res := RunResult{
		Stdout:   strings.TrimRight(out.String(), "\n"),
		Stderr:   strings.TrimRight(errbuf.String(), "\n"),
		ExitCode: 0,
	}
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			res.ExitCode = ee.ExitCode()
			// Returning err alongside — callers decide whether a non-zero
			// exit is a real failure (e.g. "already exists" is fine).
			return res, err
		}
		return res, err
	}
	return res, nil
}

// splitLines returns non-empty lines from s. Trailing blank lines from a
// command's output are discarded.
func splitLines(s string) []string {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil
	}
	return strings.Split(s, "\n")
}

// CheckPrerequisites verifies that each required CLI is reachable on PATH.
// Returns nil on success, a joined error listing missing tools otherwise.
func CheckPrerequisites(tools ...string) error {
	var missing []string
	for _, t := range tools {
		if _, err := exec.LookPath(t); err != nil {
			missing = append(missing, t)
		}
	}
	if len(missing) > 0 {
		return fmt.Errorf("missing required tools: %s", strings.Join(missing, ", "))
	}
	return nil
}
