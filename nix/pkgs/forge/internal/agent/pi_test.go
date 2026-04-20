package agent

import (
	"bytes"
	"context"
	"io"
	"testing"
	"time"
)

// fakeExec runs a user-supplied func that can write to stdout/stderr, instead
// of spawning a real process.
type fakeExec struct {
	run func(stdout, stderr io.Writer) error
}

func (f *fakeExec) Run(_ context.Context, _ string, _ io.Reader, stdout, stderr io.Writer, _ string, _ ...string) error {
	return f.run(stdout, stderr)
}

// TestPiVerboseTeesJSONLToEventLog pins the tee behavior: in verbose
// mode (Stdout non-nil, Quiet false), pi's JSONL must land in r.EventLog
// verbatim AND flow through eventrender. Stdout stays empty — the
// renderer no longer emits per-event prose.
func TestPiVerboseTeesJSONLToEventLog(t *testing.T) {
	payload := `{"type":"tool_execution_start","toolCallId":"bash:1","toolName":"bash","args":{"command":"echo hi"}}` + "\n" +
		`{"type":"tool_execution_end","toolCallId":"bash:1","toolName":"bash"}` + "\n"

	var eventLog, stdout, stderr bytes.Buffer
	p := &Pi{
		Model:    "fake-model",
		APIKey:   "k",
		LookPath: func(string) (string, error) { return "/usr/bin/pi", nil },
		Now:      time.Now,
		Exec: &fakeExec{
			run: func(w io.Writer, _ io.Writer) error {
				_, err := io.WriteString(w, payload)
				return err
			},
		},
	}

	_, err := p.Dispatch(context.Background(), Request{
		Prompt:   "ignored",
		Phase:    PhaseBuilder,
		Model:    "fake-model",
		EventLog: &eventLog,
		Stdout:   &stdout,
		Stderr:   &stderr,
	})
	if err != nil {
		t.Fatalf("Dispatch: %v", err)
	}

	if got := eventLog.String(); got != payload {
		t.Errorf("event log missing JSONL; got %q want %q", got, payload)
	}
	if stdout.Len() != 0 {
		t.Errorf("structural-only renderer should not emit to stdout; got %q", stdout.String())
	}
}

// TestPiQuietStillSinksJSONLToEventLog preserves existing quiet-mode behavior.
func TestPiQuietStillSinksJSONLToEventLog(t *testing.T) {
	payload := `{"type":"agent_end"}` + "\n"

	var eventLog bytes.Buffer
	p := &Pi{
		Model:    "fake-model",
		APIKey:   "k",
		LookPath: func(string) (string, error) { return "/usr/bin/pi", nil },
		Now:      time.Now,
		Exec: &fakeExec{
			run: func(w io.Writer, _ io.Writer) error {
				_, err := io.WriteString(w, payload)
				return err
			},
		},
	}

	_, err := p.Dispatch(context.Background(), Request{
		Prompt:   "ignored",
		Phase:    PhaseBuilder,
		Model:    "fake-model",
		EventLog: &eventLog,
		Quiet:    true,
	})
	if err != nil {
		t.Fatalf("Dispatch: %v", err)
	}

	if got := eventLog.String(); got != payload {
		t.Errorf("event log missing JSONL in quiet mode; got %q want %q", got, payload)
	}
}
