package eventrender

import (
	"bytes"
	"fmt"
	"strings"
	"testing"
	"time"
)

// Renderer tests use PiAdapter because its fixtures are the shortest; the
// renderer itself is backend-agnostic.

func TestRenderTextDeltaIsSuppressed(t *testing.T) {
	// Text deltas (the model's prose answer) are intentionally not
	// streamed to stdout; they drown the structural view. Only the
	// char counter should advance.
	in := strings.NewReader(`{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"hello "}}
{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"world"}}
`)
	var out, status bytes.Buffer
	r := &Renderer{In: in, Out: &out, Status: &status, Tick: time.Hour, Adapter: NewPiAdapter()}
	if err := r.Run(); err != nil {
		t.Fatal(err)
	}
	if out.Len() != 0 {
		t.Errorf("text deltas should not reach stdout, got %q", out.String())
	}
	if !strings.Contains(status.String(), "text=11") {
		t.Errorf("text char counter should show 11 in status: %q", status.String())
	}
}

func TestRenderToolExecutionIsStateOnly(t *testing.T) {
	// Tool start/end no longer print prose; they only advance counters
	// surfaced in the status line.
	in := strings.NewReader(`{"type":"tool_execution_start","toolCallId":"bash:1","toolName":"bash","args":{"command":"git rev-parse --show-toplevel"}}
{"type":"tool_execution_end","toolCallId":"bash:1","toolName":"bash"}
`)
	var out, status bytes.Buffer
	r := &Renderer{In: in, Out: &out, Status: &status, Tick: time.Hour, Adapter: NewPiAdapter()}
	if err := r.Run(); err != nil {
		t.Fatal(err)
	}
	if out.Len() != 0 {
		t.Errorf("tool lifecycle should not reach stdout, got %q", out.String())
	}
	if !strings.Contains(status.String(), "tools=1/1") {
		t.Errorf("status should show tools=1/1; got %q", status.String())
	}
}

func TestLargeOutputWarningGoesToStatus(t *testing.T) {
	// The SIGKILL-era safety alert still fires when a tool exceeds 1MB
	// of streamed output, but now lands on Status (stderr) rather than
	// stdout so it doesn't pollute the otherwise-quiet prose stream.
	big := strings.Repeat("x", 600*1024)
	in := strings.NewReader(
		`{"type":"tool_execution_start","toolCallId":"bash:1","toolName":"bash","args":{"command":"noisy"}}` + "\n" +
			`{"type":"tool_execution_update","toolCallId":"bash:1","partialResult":{"content":"` + big + `"}}` + "\n" +
			`{"type":"tool_execution_update","toolCallId":"bash:1","partialResult":{"content":"` + big + `"}}` + "\n" +
			`{"type":"tool_execution_end","toolCallId":"bash:1","toolName":"bash"}` + "\n",
	)
	var out, status bytes.Buffer
	r := &Renderer{In: in, Out: &out, Status: &status, Tick: time.Hour, Adapter: NewPiAdapter()}
	if err := r.Run(); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(out.String(), "LARGE OUTPUT") {
		t.Errorf("LARGE OUTPUT should not land in stdout; got %q", out.String())
	}
	if !strings.Contains(status.String(), "[LARGE OUTPUT from bash,") {
		t.Errorf("LARGE OUTPUT should land in status; got %q", status.String())
	}
}

func TestStatusLineNoPerEventPaint(t *testing.T) {
	// Neither TTY nor non-TTY mode should paint after every applied
	// event — only the ticker and the final finish() should write a
	// status line. Feed many events with a tick slow enough it can't
	// fire during the run, and assert we see exactly one status line
	// (from finish()) in both modes.
	var b strings.Builder
	for i := 0; i < 50; i++ {
		b.WriteString(`{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"x"}}` + "\n")
	}
	for _, tty := range []bool{false, true} {
		tty := tty
		t.Run(fmt.Sprintf("tty=%v", tty), func(t *testing.T) {
			var out, status bytes.Buffer
			r := &Renderer{
				In:        strings.NewReader(b.String()),
				Out:       &out,
				Status:    &status,
				StatusTTY: tty,
				Tick:      time.Hour,
				Brand:     "pi",
				Adapter:   NewPiAdapter(),
			}
			if err := r.Run(); err != nil {
				t.Fatal(err)
			}
			// finish() emits a single status line (newline-terminated in
			// non-TTY, CR-prefixed + trailing newline in TTY). Either way,
			// exactly one newline should appear.
			lines := strings.Count(status.String(), "\n")
			if lines > 1 {
				t.Errorf("expected only the final status line, got %d:\n%s", lines, status.String())
			}
		})
	}
}

func TestRenderThinkingIsSuppressed(t *testing.T) {
	// Thinking blocks are fully captured in the JSONL event log; the
	// live renderer should not emit them. Only the think char counter
	// should advance.
	in := strings.NewReader(
		`{"type":"message_update","assistantMessageEvent":{"type":"thinking_start"}}` + "\n" +
			`{"type":"message_update","assistantMessageEvent":{"type":"thinking_delta","delta":"weighing the options"}}` + "\n" +
			`{"type":"message_update","assistantMessageEvent":{"type":"thinking_end"}}` + "\n",
	)
	var out, status bytes.Buffer
	r := &Renderer{In: in, Out: &out, Status: &status, Tick: time.Hour, Adapter: NewPiAdapter()}
	if err := r.Run(); err != nil {
		t.Fatal(err)
	}
	if out.Len() != 0 {
		t.Errorf("thinking should not reach stdout, got %q", out.String())
	}
	if !strings.Contains(status.String(), "think=20") {
		t.Errorf("think char counter should show 20 in status: %q", status.String())
	}
}

func TestStatusLineNoThinkingTail(t *testing.T) {
	in := strings.NewReader(`{"type":"message_update","assistantMessageEvent":{"type":"thinking_delta","delta":"reasoning about the approach"}}` + "\n")
	var out, status bytes.Buffer
	r := &Renderer{In: in, Out: &out, Status: &status, Tick: 10 * time.Millisecond, Brand: "pi", Adapter: NewPiAdapter()}
	if err := r.Run(); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(status.String(), "thinking=") {
		t.Errorf("status line should not include thinking tail; got %q", status.String())
	}
	if !strings.Contains(status.String(), "think=") {
		t.Errorf("status line should still show think= char count; got %q", status.String())
	}
}

func TestStatusLineShowsTokens(t *testing.T) {
	// turn_end's totalTokens is now surfaced only in the status line.
	in := strings.NewReader(`{"type":"turn_end","message":{"usage":{"totalTokens":55252}}}` + "\n")
	var out, status bytes.Buffer
	r := &Renderer{In: in, Out: &out, Status: &status, Tick: time.Hour, Adapter: NewPiAdapter()}
	if err := r.Run(); err != nil {
		t.Fatal(err)
	}
	if out.Len() != 0 {
		t.Errorf("turn_end should not reach stdout; got %q", out.String())
	}
	if !strings.Contains(status.String(), "tokens=55.3k") {
		t.Errorf("status should show tokens=55.3k; got %q", status.String())
	}
}

func TestRenderHandlesMalformedJSON(t *testing.T) {
	// Malformed lines must not abort the stream. The tool frames after
	// the bad line should still advance counters surfaced in status.
	in := strings.NewReader(
		"not json\n" +
			`{"type":"tool_execution_start","toolCallId":"bash:1","toolName":"bash","args":{"command":"ls"}}` + "\n" +
			`{"type":"tool_execution_end","toolCallId":"bash:1","toolName":"bash"}` + "\n",
	)
	var out, status bytes.Buffer
	r := &Renderer{In: in, Out: &out, Status: &status, Tick: time.Hour, Adapter: NewPiAdapter()}
	if err := r.Run(); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(status.String(), "tools=1/1") {
		t.Errorf("malformed line should be skipped and subsequent tool frames still counted; status=%q", status.String())
	}
}

func TestStatusLineBrand(t *testing.T) {
	in := strings.NewReader(`{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"x"}}` + "\n")
	var out, status bytes.Buffer
	r := &Renderer{In: in, Out: &out, Status: &status, Tick: 100 * time.Millisecond, Brand: "claude", Adapter: NewPiAdapter()}
	if err := r.Run(); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(status.String(), "claude ") {
		t.Errorf("status line missing brand; got %q", status.String())
	}
}

func TestStatusLineLabelPrefix(t *testing.T) {
	in := strings.NewReader(`{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"x"}}` + "\n")
	var out, status bytes.Buffer
	r := &Renderer{In: in, Out: &out, Status: &status, Tick: 100 * time.Millisecond, Brand: "pi", Label: "[builder FEAT-42/3]", Adapter: NewPiAdapter()}
	if err := r.Run(); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(status.String(), "[builder FEAT-42/3]  pi ") {
		t.Errorf("status line missing label/brand; got %q", status.String())
	}
}

func TestStatusTTYTruncatesToWidth(t *testing.T) {
	// In TTY mode \033[K only clears the current row. If the heartbeat
	// line is longer than the terminal width, wrap leaves a ghost row
	// in scrollback on every tick. Truncation to width-1 keeps the
	// paint on one row.
	in := strings.NewReader(
		`{"type":"tool_execution_start","toolCallId":"bash:1","toolName":"bash","args":{"command":"noop"}}` + "\n" +
			`{"type":"turn_end","message":{"usage":{"totalTokens":98765}}}` + "\n",
	)
	var out, status bytes.Buffer
	r := &Renderer{
		In:          in,
		Out:         &out,
		Status:      &status,
		StatusTTY:   true,
		StatusWidth: 60,
		Tick:        10 * time.Millisecond,
		Brand:       "pi",
		Label:       "[builder FEAT-42 attempt 7/10 very long label to force wrap]",
		Adapter:     NewPiAdapter(),
	}
	if err := r.Run(); err != nil {
		t.Fatal(err)
	}
	// Every paint in TTY mode is framed by \r\033[K<line>. Split on
	// that marker and verify each rendered segment fits in width-1.
	const marker = "\r\x1b[K"
	segs := strings.Split(status.String(), marker)
	if len(segs) < 2 {
		t.Fatalf("expected at least one TTY paint, got %q", status.String())
	}
	for i, seg := range segs[1:] {
		// Trailing newline from finish() belongs to this segment; ignore it.
		seg = strings.TrimRight(seg, "\n")
		if runes := []rune(seg); len(runes) >= 60 {
			t.Errorf("paint %d exceeded StatusWidth-1 (%d runes): %q", i, len(runes), seg)
		}
	}
}

func TestStatusTTYNoTruncationWhenWidthZero(t *testing.T) {
	// StatusWidth=0 (unknown terminal width) keeps the previous
	// behavior — emit the full line and rely on the terminal.
	in := strings.NewReader(
		`{"type":"tool_execution_start","toolCallId":"bash:1","toolName":"bash","args":{"command":"noop"}}` + "\n",
	)
	var out, status bytes.Buffer
	longLabel := "[" + strings.Repeat("x", 200) + "]"
	r := &Renderer{
		In:        in,
		Out:       &out,
		Status:    &status,
		StatusTTY: true,
		Tick:      10 * time.Millisecond,
		Brand:     "pi",
		Label:     longLabel,
		Adapter:   NewPiAdapter(),
	}
	if err := r.Run(); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(status.String(), longLabel) {
		t.Errorf("width=0 should not truncate; label missing from status=%q", status.String())
	}
}

func TestHumanTime(t *testing.T) {
	cases := []struct {
		d    time.Duration
		want string
	}{
		{30 * time.Second, "30s"},
		{90 * time.Second, "1m30s"},
		{3661 * time.Second, "1h01m"},
	}
	for _, c := range cases {
		if got := humanTime(c.d); got != c.want {
			t.Errorf("humanTime(%v): got %q want %q", c.d, got, c.want)
		}
	}
}

func TestHumanCount(t *testing.T) {
	cases := []struct {
		n    int64
		want string
	}{
		{42, "42"},
		{1500, "1.5k"},
		{2500000, "2.5M"},
	}
	for _, c := range cases {
		if got := humanCount(c.n); got != c.want {
			t.Errorf("humanCount(%d): got %q want %q", c.n, got, c.want)
		}
	}
}

func TestTruncErr(t *testing.T) {
	if got := truncErr("  foo\nbar\tbaz ", 0); got != "foo bar baz" {
		t.Errorf("truncErr whitespace: got %q", got)
	}
	if got := truncErr("abcdefghij", 5); got != "abcde…" {
		t.Errorf("truncErr clip: got %q", got)
	}
}
