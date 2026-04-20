package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/kyleondy/dotfiles/forge/internal/eventrender"
	"golang.org/x/term"
)

// Pi dispatches via the `pi` CLI in non-interactive (`-p`) mode with
// JSONL events. Tool-capable. The JSONL stream is teed to the event log
// and rendered to prose by eventrender (with PiAdapter).
type Pi struct {
	Model         string
	APIKey        string
	OpenAIBaseURL string // used to look up matching pi provider in ~/.pi/agent/models.json
	Exec          Executor
	LookPath      func(string) (string, error)
	Now           func() time.Time
}

func NewPi(model, apiKey, openAIBaseURL string) *Pi {
	return &Pi{
		Model:         model,
		APIKey:        apiKey,
		OpenAIBaseURL: openAIBaseURL,
		Exec:          DefaultExecutor(),
		LookPath:      exec.LookPath,
		Now:           time.Now,
	}
}

func (p *Pi) Name() string { return "pi" }

func (p *Pi) Capabilities() Capabilities {
	return Capabilities{StreamingText: true, ToolCalls: true, FileWrites: false}
}

func (p *Pi) Preflight(ctx context.Context) error {
	if _, err := p.LookPath("pi"); err != nil {
		return errors.New("pi CLI not found on PATH")
	}
	if p.Model == "" {
		return errors.New("FORGE_MODEL not set (required for pi)")
	}
	if p.APIKey == "" {
		return errors.New("OPENAI_API_KEY not set (required for pi)")
	}
	return nil
}

func (p *Pi) Dispatch(ctx context.Context, r Request) (Result, error) {
	model := r.Model
	if model == "" {
		model = p.Model
	}
	args := []string{"-p", "--no-session", "--mode", "json", "--model", model}

	// If pi has a provider configured with the same baseUrl as the openai-
	// compat endpoint, pass it as --provider so an unprefixed model id
	// (kimi-k2.5) routes correctly.
	if p.OpenAIBaseURL != "" {
		if provider, ok := matchPiProvider(p.OpenAIBaseURL); ok {
			args = append(args, "--provider", provider)
		}
	}

	if p.APIKey != "" {
		args = append(args, "--api-key", p.APIKey)
	}

	// Translate canonical tool names to pi's lowercase set. Glob → find.
	if tools := translateToolsForPi(r.AllowedTools); tools != "" {
		args = append(args, "--tools", tools)
	}

	args = append(args, r.Prompt)

	// pi takes the prompt as a positional arg and emits JSONL on stdout.
	// We need to tee that JSONL to (a) the event log and (b) eventrender
	// for human-readable prose.
	pr, pw := io.Pipe()
	var teed io.Writer = pw
	if r.EventLog != nil {
		teed = io.MultiWriter(pw, r.EventLog)
	}
	if r.Quiet || r.Stdout == nil {
		// In quiet mode, skip eventrender entirely; just sink JSONL into the log.
		stdout := io.Discard
		if r.EventLog != nil {
			stdout = r.EventLog
		}
		stderr := r.Stderr
		if stderr == nil {
			stderr = io.Discard
		}
		start := p.Now()
		timedCtx := ctx
		if r.Timeout > 0 {
			var cancel context.CancelFunc
			timedCtx, cancel = context.WithTimeout(ctx, r.Timeout)
			defer cancel()
		}
		if err := p.Exec.Run(timedCtx, r.CWD, nil, stdout, stderr, "pi", args...); err != nil {
			return Result{}, fmt.Errorf("pi exited with error: %w", err)
		}
		return Result{DurationMs: time.Since(start).Milliseconds()}, nil
	}

	// Verbose path: tee to event log + eventrender.
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
		Brand:       "pi",
		Adapter:     eventrender.NewPiAdapter(),
	}
	done := make(chan error, 1)
	go func() { done <- rend.Run() }()

	stdoutWriter := teed
	stderr := r.Stderr
	if stderr == nil {
		stderr = io.Discard
	}

	start := p.Now()
	timedCtx := ctx
	if r.Timeout > 0 {
		var cancel context.CancelFunc
		timedCtx, cancel = context.WithTimeout(ctx, r.Timeout)
		defer cancel()
	}
	runErr := p.Exec.Run(timedCtx, r.CWD, nil, stdoutWriter, stderr, "pi", args...)
	pw.Close()
	<-done
	if runErr != nil {
		return Result{}, fmt.Errorf("pi exited with error: %w", runErr)
	}
	return Result{DurationMs: time.Since(start).Milliseconds()}, nil
}

// matchPiProvider returns the pi provider name whose configured baseUrl
// matches openAIBaseURL. Reads ~/.pi/agent/models.json silently; absence
// or parse failure means "no match" — pi will fall back to its own
// defaults.
func matchPiProvider(openAIBaseURL string) (string, bool) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", false
	}
	b, err := os.ReadFile(filepath.Join(home, ".pi", "agent", "models.json"))
	if err != nil {
		return "", false
	}
	var doc struct {
		Providers map[string]struct {
			BaseURL string `json:"baseUrl"`
		} `json:"providers"`
	}
	if err := json.Unmarshal(b, &doc); err != nil {
		return "", false
	}
	for name, p := range doc.Providers {
		if p.BaseURL == openAIBaseURL {
			return name, true
		}
	}
	return "", false
}

// translateToolsForPi maps canonical tool names (Edit, Write, Glob…) to pi's
// expected lowercase names (and Glob → find).
func translateToolsForPi(in []string) string {
	if len(in) == 0 {
		return ""
	}
	out := make([]string, 0, len(in))
	for _, t := range in {
		switch t {
		case "Glob":
			out = append(out, "find")
		default:
			out = append(out, strings.ToLower(t))
		}
	}
	return strings.Join(out, ",")
}
