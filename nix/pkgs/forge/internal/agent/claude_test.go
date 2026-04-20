package agent

import (
	"bytes"
	"context"
	"io"
	"testing"
	"time"
)

// TestClaudeVerboseTeesStreamJSONToEventLog confirms claude's verbose
// path tees stream-json to the event log AND hands it to eventrender.
// Stdout stays empty — the renderer no longer emits per-event prose.
func TestClaudeVerboseTeesStreamJSONToEventLog(t *testing.T) {
	payload := `{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"Bash","input":{}}}}` + "\n" +
		`{"type":"stream_event","event":{"type":"content_block_stop","index":0}}` + "\n"

	var eventLog, stdout, stderr bytes.Buffer
	c := &Claude{
		Model:          "claude-opus-4-7[1m]",
		PermissionMode: "bypassPermissions",
		LookPath:       func(string) (string, error) { return "/usr/bin/claude", nil },
		Now:            time.Now,
		Exec: &fakeExec{
			run: func(w io.Writer, _ io.Writer) error {
				_, err := io.WriteString(w, payload)
				return err
			},
		},
	}

	_, err := c.Dispatch(context.Background(), Request{
		Prompt:   "ignored",
		Phase:    PhaseBuilder,
		EventLog: &eventLog,
		Stdout:   &stdout,
		Stderr:   &stderr,
	})
	if err != nil {
		t.Fatalf("Dispatch: %v", err)
	}

	if got := eventLog.String(); got != payload {
		t.Errorf("event log mismatch:\n got: %q\nwant: %q", got, payload)
	}
	if stdout.Len() != 0 {
		t.Errorf("structural-only renderer should not emit to stdout; got %q", stdout.String())
	}
}

// TestClaudeQuietSinksStreamJSONToEventLog preserves quiet-mode behavior:
// no prose on stdout, raw NDJSON into the event log.
func TestClaudeQuietSinksStreamJSONToEventLog(t *testing.T) {
	payload := `{"type":"result","subtype":"success","usage":{"input_tokens":1,"output_tokens":2}}` + "\n"

	var eventLog, stdout bytes.Buffer
	c := &Claude{
		Model:          "claude-opus-4-7[1m]",
		PermissionMode: "bypassPermissions",
		LookPath:       func(string) (string, error) { return "/usr/bin/claude", nil },
		Now:            time.Now,
		Exec: &fakeExec{
			run: func(w io.Writer, _ io.Writer) error {
				_, err := io.WriteString(w, payload)
				return err
			},
		},
	}

	_, err := c.Dispatch(context.Background(), Request{
		Prompt:   "ignored",
		Phase:    PhaseBuilder,
		EventLog: &eventLog,
		Stdout:   &stdout,
		Quiet:    true,
	})
	if err != nil {
		t.Fatalf("Dispatch: %v", err)
	}

	if got := eventLog.String(); got != payload {
		t.Errorf("event log missing JSONL; got %q want %q", got, payload)
	}
	if stdout.Len() != 0 {
		t.Errorf("quiet mode should not emit to stdout; got %q", stdout.String())
	}
}
