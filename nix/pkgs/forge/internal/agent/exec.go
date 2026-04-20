package agent

import (
	"context"
	"io"
	"os/exec"
)

// Executor is the seam for tests. Production uses os/exec.
type Executor interface {
	// Run starts a command and blocks until it exits. stdin is fed in;
	// stdout and stderr stream to the writers; cwd is optional.
	Run(ctx context.Context, dir string, stdin io.Reader, stdout, stderr io.Writer, name string, args ...string) error
}

type cmdExecutor struct{}

func (cmdExecutor) Run(ctx context.Context, dir string, stdin io.Reader, stdout, stderr io.Writer, name string, args ...string) error {
	c := exec.CommandContext(ctx, name, args...)
	if dir != "" {
		c.Dir = dir
	}
	c.Stdin = stdin
	c.Stdout = stdout
	c.Stderr = stderr
	return c.Run()
}

// DefaultExecutor returns an Executor backed by os/exec.
func DefaultExecutor() Executor { return cmdExecutor{} }
