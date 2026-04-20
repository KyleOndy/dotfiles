package eventrender

import (
	"testing"
)

func TestClaudeAdapterTextDelta(t *testing.T) {
	a := NewClaudeAdapter()
	// A text block must be opened so the delta resolves to a text event.
	a.Parse([]byte(`{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}`))
	got := a.Parse([]byte(`{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}}`))
	if len(got) != 1 || got[0].Kind != EventTextDelta || got[0].Text != "hi" {
		t.Fatalf("text_delta: %+v", got)
	}
}

func TestClaudeAdapterThinkingDelta(t *testing.T) {
	a := NewClaudeAdapter()
	a.Parse([]byte(`{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}}`))
	got := a.Parse([]byte(`{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"let me think"}}}`))
	if len(got) != 1 || got[0].Kind != EventThinkingDelta || got[0].Text != "let me think" {
		t.Fatalf("thinking_delta: %+v", got)
	}
}

func TestClaudeAdapterToolUseBlock(t *testing.T) {
	a := NewClaudeAdapter()
	start := a.Parse([]byte(`{"type":"stream_event","event":{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"Edit","input":{}}}}`))
	if len(start) != 1 || start[0].Kind != EventToolStart || start[0].ToolName != "Edit" {
		t.Fatalf("tool start: %+v", start)
	}
	// input_json_delta is ignored (tool arg bytes).
	if got := a.Parse([]byte(`{"type":"stream_event","event":{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"a\":"}}}`)); len(got) != 0 {
		t.Fatalf("input_json_delta should produce no events, got %+v", got)
	}
	stop := a.Parse([]byte(`{"type":"stream_event","event":{"type":"content_block_stop","index":2}}`))
	if len(stop) != 1 || stop[0].Kind != EventToolEnd {
		t.Fatalf("tool stop: %+v", stop)
	}
}

func TestClaudeAdapterNonToolBlockStopDoesNotEmit(t *testing.T) {
	a := NewClaudeAdapter()
	a.Parse([]byte(`{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}`))
	if got := a.Parse([]byte(`{"type":"stream_event","event":{"type":"content_block_stop","index":0}}`)); len(got) != 0 {
		t.Fatalf("text block stop should not emit ToolEnd, got %+v", got)
	}
}

func TestClaudeAdapterApiRetryThenRecovery(t *testing.T) {
	a := NewClaudeAdapter()
	retry := a.Parse([]byte(`{"type":"system","subtype":"api_retry","attempt":1,"max_retries":10,"retry_delay_ms":1000,"error_status":429}`))
	if len(retry) != 1 || retry[0].Kind != EventRetryStart || retry[0].Attempt != 1 || retry[0].MaxAttempts != 10 {
		t.Fatalf("retry start: %+v", retry)
	}
	if retry[0].ErrorMessage == "" {
		t.Fatalf("expected derived error message, got empty")
	}
	// Next real event should synthesize RetryEnd(success=true).
	events := a.Parse([]byte(`{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}`))
	if len(events) < 1 || events[0].Kind != EventRetryEnd || !events[0].Success {
		t.Fatalf("expected synthesized retry end, got %+v", events)
	}
}

func TestClaudeAdapterResultEmitsTurnEndAndTokens(t *testing.T) {
	a := NewClaudeAdapter()
	got := a.Parse([]byte(`{"type":"result","subtype":"success","usage":{"input_tokens":100,"output_tokens":250,"cache_read_input_tokens":50}}`))
	if len(got) != 1 || got[0].Kind != EventTurnEnd || got[0].TotalTokens != 350 {
		t.Fatalf("result: %+v", got)
	}
}

func TestClaudeAdapterResultAfterRetryFailure(t *testing.T) {
	a := NewClaudeAdapter()
	a.Parse([]byte(`{"type":"system","subtype":"api_retry","attempt":10,"max_retries":10}`))
	// Failure subtype.
	got := a.Parse([]byte(`{"type":"result","subtype":"error_max_turns","usage":{"input_tokens":10,"output_tokens":5}}`))
	if len(got) != 2 {
		t.Fatalf("expected RetryEnd + TurnEnd, got %+v", got)
	}
	if got[0].Kind != EventRetryEnd || got[0].Success {
		t.Fatalf("retry end should be failure: %+v", got[0])
	}
	if got[1].Kind != EventTurnEnd {
		t.Fatalf("expected turn end, got %+v", got[1])
	}
}

func TestClaudeAdapterSystemInitIgnored(t *testing.T) {
	a := NewClaudeAdapter()
	if got := a.Parse([]byte(`{"type":"system","subtype":"init","model":"claude-opus-4-7[1m]","session_id":"abc"}`)); len(got) != 0 {
		t.Fatalf("system/init should be ignored, got %+v", got)
	}
	if u := a.Unknown(); len(u) != 0 {
		t.Fatalf("unknowns leaked: %v", u)
	}
}

func TestClaudeAdapterMessageFramesIgnored(t *testing.T) {
	a := NewClaudeAdapter()
	cases := []string{
		`{"type":"stream_event","event":{"type":"message_start","message":{"id":"m1"}}}`,
		`{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"end_turn"}}}`,
		`{"type":"stream_event","event":{"type":"message_stop"}}`,
		`{"type":"stream_event","event":{"type":"ping"}}`,
	}
	for _, line := range cases {
		if got := a.Parse([]byte(line)); len(got) != 0 {
			t.Errorf("expected no events for %s, got %+v", line, got)
		}
	}
	if u := a.Unknown(); len(u) != 0 {
		t.Errorf("unknowns: %v", u)
	}
}

func TestClaudeAdapterUnknownEventTracked(t *testing.T) {
	a := NewClaudeAdapter()
	a.Parse([]byte(`{"type":"mystery"}`))
	a.Parse([]byte(`{"type":"stream_event","event":{"type":"weird"}}`))
	u := a.Unknown()
	if len(u) != 2 {
		t.Fatalf("expected 2 unknowns, got %v", u)
	}
}

func TestClaudeAdapterMalformed(t *testing.T) {
	a := NewClaudeAdapter()
	if got := a.Parse([]byte(`not json`)); got != nil {
		t.Errorf("expected nil, got %+v", got)
	}
	if u := a.Unknown(); len(u) != 1 || u[0] != "<malformed-json>" {
		t.Errorf("expected malformed tag, got %v", u)
	}
}
