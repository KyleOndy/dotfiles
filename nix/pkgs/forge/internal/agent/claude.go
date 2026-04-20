package agent

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/kyleondy/dotfiles/forge/internal/eventrender"
	"golang.org/x/term"
)

// Claude dispatches via the `claude` CLI in non-interactive (`-p`) mode
// with stream-json output. The model can use Edit/Write/Bash tools. The
// stream-json NDJSON is teed to the event log and rendered to prose by
// eventrender with ClaudeAdapter.
type Claude struct {
	Model          string
	PermissionMode string
	Exec           Executor
	LookPath       func(string) (string, error)
	Now            func() time.Time
}

func NewClaude(model, permissionMode string) *Claude {
	return &Claude{
		Model:          model,
		PermissionMode: permissionMode,
		Exec:           DefaultExecutor(),
		LookPath:       exec.LookPath,
		Now:            time.Now,
	}
}

func (c *Claude) Name() string { return "claude" }

func (c *Claude) Capabilities() Capabilities {
	return Capabilities{StreamingText: true, ToolCalls: true, FileWrites: false}
}

func (c *Claude) Preflight(ctx context.Context) error {
	if _, err := c.LookPath("claude"); err != nil {
		return errors.New("claude CLI not found on PATH")
	}
	return nil
}

func (c *Claude) Dispatch(ctx context.Context, r Request) (Result, error) {
	args := []string{
		"-p",
		"--output-format", "stream-json",
		"--include-partial-messages",
		"--verbose",
		"--permission-mode", c.PermissionMode,
	}
	model := r.Model
	if model == "" {
		model = c.Model
	}
	if model != "" {
		args = append(args, "--model", model)
	}
	for _, d := range r.ExtraDirs {
		if d != "" {
			args = append(args, "--add-dir", d)
		}
	}
	if len(r.AllowedTools) > 0 {
		args = append(args, "--allowedTools")
		args = append(args, r.AllowedTools...)
	}

	stdin := strings.NewReader(r.Prompt)

	timedCtx := ctx
	if r.Timeout > 0 {
		var cancel context.CancelFunc
		timedCtx, cancel = context.WithTimeout(ctx, r.Timeout)
		defer cancel()
	}

	// Quiet path: no prose rendering. Sink raw NDJSON into the event log.
	if r.Quiet || r.Stdout == nil {
		stdout := io.Discard
		if r.EventLog != nil {
			stdout = r.EventLog
		}
		stderr := r.Stderr
		if stderr == nil {
			stderr = io.Discard
		}
		start := c.Now()
		if err := c.Exec.Run(timedCtx, r.CWD, stdin, stdout, stderr, "claude", args...); err != nil {
			return Result{}, fmt.Errorf("claude exited with error: %w", err)
		}
		return Result{DurationMs: time.Since(start).Milliseconds()}, nil
	}

	// Verbose path: tee claude's NDJSON to (a) the event log and (b)
	// eventrender for human-readable prose.
	pr, pw := io.Pipe()
	var teed io.Writer = pw
	if r.EventLog != nil {
		teed = io.MultiWriter(pw, r.EventLog)
	}

	stderrIsTTY := false
	stderrWidth := 0
	if f, ok := r.Stderr.(*os.File); ok {
		stderrIsTTY = term.IsTerminal(int(f.Fd()))
		if stderrIsTTY {
			if w, _, err := term.GetSize(int(f.Fd())); err == nil {
				stderrWidth = w
			}
		}
	}
	label := fmt.Sprintf("[%s]", r.Phase)
	if r.TicketID != "" {
		label = fmt.Sprintf("[%s %s", r.Phase, r.TicketID)
		if r.TaskID != "" {
			label += " " + r.TaskID
			if r.TaskTotal > 0 {
				label += fmt.Sprintf("/T%02d", r.TaskTotal)
			}
		}
		if r.RetryMax > 0 {
			label += fmt.Sprintf(" attempt %d/%d", r.RetryAttempt+1, r.RetryMax)
		}
		label += "]"
	}
	rend := &eventrender.Renderer{
		In:          pr,
		Out:         r.Stdout,
		Status:      r.Stderr,
		StatusTTY:   stderrIsTTY,
		StatusWidth: stderrWidth,
		Label:       label,
		Brand:       "claude",
		Adapter:     eventrender.NewClaudeAdapter(),
	}
	done := make(chan error, 1)
	go func() { done <- rend.Run() }()

	stderr := r.Stderr
	if stderr == nil {
		stderr = io.Discard
	}

	start := c.Now()
	runErr := c.Exec.Run(timedCtx, r.CWD, stdin, teed, stderr, "claude", args...)
	pw.Close()
	<-done
	if runErr != nil {
		return Result{}, fmt.Errorf("claude exited with error: %w", runErr)
	}
	return Result{DurationMs: time.Since(start).Milliseconds()}, nil
}
