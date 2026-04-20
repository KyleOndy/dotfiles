package eventrender

import (
	"strings"
	"testing"
)

func TestPiAdapterTextDelta(t *testing.T) {
	a := NewPiAdapter()
	got := a.Parse([]byte(`{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"hello"}}`))
	if len(got) != 1 || got[0].Kind != EventTextDelta || got[0].Text != "hello" {
		t.Fatalf("unexpected events: %+v", got)
	}
}

func TestPiAdapterThinkingStartEnd(t *testing.T) {
	a := NewPiAdapter()
	start := a.Parse([]byte(`{"type":"message_update","assistantMessageEvent":{"type":"thinking_start"}}`))
	if len(start) != 1 || start[0].Kind != EventThinkingStart {
		t.Fatalf("start: %+v", start)
	}
	end := a.Parse([]byte(`{"type":"message_update","assistantMessageEvent":{"type":"thinking_end"}}`))
	if len(end) != 1 || end[0].Kind != EventThinkingEnd {
		t.Fatalf("end: %+v", end)
	}
}

func TestPiAdapterToolExecutionUpdateCarriesPreview(t *testing.T) {
	a := NewPiAdapter()
	line := `{"type":"tool_execution_update","toolCallId":"bash:1","partialResult":{"content":[{"type":"text","text":"/tmp/foo\nhello world"}]}}`
	evs := a.Parse([]byte(line))
	if len(evs) != 1 || evs[0].Kind != EventToolOutput {
		t.Fatalf("update kind: %+v", evs)
	}
	if evs[0].ToolPreview != "/tmp/foo\nhello world" {
		t.Errorf("preview: %q", evs[0].ToolPreview)
	}
}

func TestPiAdapterThinkingDelta(t *testing.T) {
	a := NewPiAdapter()
	got := a.Parse([]byte(`{"type":"message_update","assistantMessageEvent":{"type":"thinking_delta","delta":"hmm"}}`))
	if len(got) != 1 || got[0].Kind != EventThinkingDelta || got[0].Text != "hmm" {
		t.Fatalf("unexpected: %+v", got)
	}
}

func TestPiAdapterToolcallPlanningIsSilent(t *testing.T) {
	// toolcall_start/end fire when the LLM plans a call before execution.
	// The adapter should ignore them — we surface tool_execution_* instead.
	a := NewPiAdapter()
	start := a.Parse([]byte(`{"type":"message_update","assistantMessageEvent":{"type":"toolcall_start","partial":{"content":[{"type":"toolCall","name":"Edit"}]}}}`))
	if len(start) != 0 {
		t.Fatalf("toolcall_start should be silent, got: %+v", start)
	}
	end := a.Parse([]byte(`{"type":"message_update","assistantMessageEvent":{"type":"toolcall_end"}}`))
	if len(end) != 0 {
		t.Fatalf("toolcall_end should be silent, got: %+v", end)
	}
	if u := a.Unknown(); len(u) != 0 {
		t.Fatalf("unexpected unknowns: %v", u)
	}
}

func TestPiAdapterToolExecutionBash(t *testing.T) {
	a := NewPiAdapter()
	start := a.Parse([]byte(`{"type":"tool_execution_start","toolCallId":"functions.bash:5","toolName":"bash","args":{"command":"git rev-parse --show-toplevel"}}`))
	if len(start) != 1 || start[0].Kind != EventToolStart {
		t.Fatalf("start kind: %+v", start)
	}
	if start[0].ToolName != "bash" || start[0].ToolCallID != "functions.bash:5" {
		t.Errorf("start metadata: %+v", start[0])
	}
	if start[0].ToolArgPreview != "git rev-parse --show-toplevel" {
		t.Errorf("arg preview: %q", start[0].ToolArgPreview)
	}

	upd := a.Parse([]byte(`{"type":"tool_execution_update","toolCallId":"functions.bash:5","partialResult":{"content":[{"type":"text","text":"/some/path"}]}}`))
	if len(upd) != 1 || upd[0].Kind != EventToolOutput {
		t.Fatalf("update kind: %+v", upd)
	}
	if upd[0].ToolCallID != "functions.bash:5" || upd[0].ToolOutputSize <= 0 {
		t.Errorf("update metadata: %+v", upd[0])
	}

	end := a.Parse([]byte(`{"type":"tool_execution_end","toolCallId":"functions.bash:5","toolName":"bash"}`))
	if len(end) != 1 || end[0].Kind != EventToolEnd || end[0].ToolCallID != "functions.bash:5" {
		t.Fatalf("end: %+v", end)
	}
}

func TestPiAdapterToolExecutionFindPreview(t *testing.T) {
	a := NewPiAdapter()
	evs := a.Parse([]byte(`{"type":"tool_execution_start","toolCallId":"functions.find:3","toolName":"find","args":{"pattern":"**/handler.go","path":"/path/to/your/repo/main/PROJ-123/T02-add-feature"}}`))
	if len(evs) != 1 {
		t.Fatalf("events: %+v", evs)
	}
	want := "**/handler.go in T02-add-feature"
	if evs[0].ToolArgPreview != want {
		t.Errorf("preview: got %q want %q", evs[0].ToolArgPreview, want)
	}
}

func TestPiAdapterToolExecutionReadPreview(t *testing.T) {
	a := NewPiAdapter()
	evs := a.Parse([]byte(`{"type":"tool_execution_start","toolCallId":"functions.read:2","toolName":"read","args":{"path":"/a/b/c/base_reconciler.go"}}`))
	if len(evs) != 1 || evs[0].ToolArgPreview != "base_reconciler.go" {
		t.Fatalf("preview: %+v", evs)
	}
}

func TestSummarizeArgsClipsLongBash(t *testing.T) {
	long := strings.Repeat("x", 250)
	got := summarizeArgs("bash", map[string]any{"command": long})
	runes := []rune(got)
	if len(runes) != argPreviewMax+1 || runes[len(runes)-1] != '…' {
		t.Errorf("clip: len=%d last=%q", len(runes), runes[len(runes)-1])
	}
}

func TestPiAdapterAutoRetry(t *testing.T) {
	a := NewPiAdapter()
	got := a.Parse([]byte(`{"type":"auto_retry_start","attempt":2,"maxAttempts":5,"errorMessage":"503 service unavailable"}`))
	if len(got) != 1 || got[0].Kind != EventRetryStart || got[0].Attempt != 2 || got[0].MaxAttempts != 5 {
		t.Fatalf("retry start: %+v", got)
	}
	if got[0].ErrorMessage != "503 service unavailable" {
		t.Fatalf("retry start err: %q", got[0].ErrorMessage)
	}
	endOK := a.Parse([]byte(`{"type":"auto_retry_end","success":true}`))
	if len(endOK) != 1 || endOK[0].Kind != EventRetryEnd || !endOK[0].Success {
		t.Fatalf("retry end ok: %+v", endOK)
	}
	endBad := a.Parse([]byte(`{"type":"auto_retry_end","success":false,"finalError":"rate limit exceeded"}`))
	if len(endBad) != 1 || endBad[0].Success || endBad[0].FinalError != "rate limit exceeded" {
		t.Fatalf("retry end bad: %+v", endBad)
	}
}

func TestPiAdapterTurnEndTokens(t *testing.T) {
	a := NewPiAdapter()
	got := a.Parse([]byte(`{"type":"turn_end","message":{"usage":{"totalTokens":1234}}}`))
	if len(got) != 1 || got[0].Kind != EventTurnEnd || got[0].TotalTokens != 1234 {
		t.Fatalf("turn end: %+v", got)
	}
}

func TestPiAdapterIgnoredEvents(t *testing.T) {
	a := NewPiAdapter()
	cases := []string{
		`{"type":"session","id":"s1"}`,
		`{"type":"agent_start"}`,
		`{"type":"message_update","assistantMessageEvent":{"type":"text_start"}}`,
		`{"type":"message_update","assistantMessageEvent":{"type":"toolcall_delta"}}`,
	}
	for _, line := range cases {
		if got := a.Parse([]byte(line)); len(got) != 0 {
			t.Errorf("expected no events for %s, got %+v", line, got)
		}
	}
	if u := a.Unknown(); len(u) != 0 {
		t.Errorf("expected no unknowns, got %v", u)
	}
}

func TestPiAdapterUnknownEventTracked(t *testing.T) {
	a := NewPiAdapter()
	a.Parse([]byte(`{"type":"mystery_event"}`))
	a.Parse([]byte(`{"type":"message_update","assistantMessageEvent":{"type":"unknown_inner"}}`))
	u := a.Unknown()
	if len(u) != 2 {
		t.Fatalf("expected 2 unknowns, got %v", u)
	}
}

func TestPiAdapterMalformedJSON(t *testing.T) {
	a := NewPiAdapter()
	if got := a.Parse([]byte(`not json`)); got != nil {
		t.Errorf("expected nil for malformed, got %+v", got)
	}
	u := a.Unknown()
	if len(u) != 1 || u[0] != "<malformed-json>" {
		t.Errorf("expected <malformed-json> tag, got %v", u)
	}
}
