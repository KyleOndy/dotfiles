package eventrender

import (
	"encoding/json"
	"path/filepath"
	"sort"
	"strings"
	"sync"
)

// PiAdapter parses the pi CLI's `--mode json` JSONL output. The schema is
// documented implicitly by pi itself; this mirrors the event handling that
// lived in the old pirender package.
type PiAdapter struct {
	mu      sync.Mutex
	unknown map[string]struct{}
}

// NewPiAdapter returns a ready-to-use PiAdapter. Callers should reuse one
// instance per stream so unknown-event tracking accumulates.
func NewPiAdapter() *PiAdapter { return &PiAdapter{} }

func (p *PiAdapter) addUnknown(t string) {
	p.mu.Lock()
	if p.unknown == nil {
		p.unknown = map[string]struct{}{}
	}
	p.unknown[t] = struct{}{}
	p.mu.Unlock()
}

// Parse turns one JSONL line into normalized events.
func (p *PiAdapter) Parse(line []byte) []Event {
	var evt map[string]any
	if err := json.Unmarshal(line, &evt); err != nil {
		p.addUnknown("<malformed-json>")
		return nil
	}
	etype, _ := evt["type"].(string)
	switch etype {
	case "message_update":
		inner, _ := evt["assistantMessageEvent"].(map[string]any)
		if inner == nil {
			return nil
		}
		itype, _ := inner["type"].(string)
		switch itype {
		case "text_delta":
			delta, _ := inner["delta"].(string)
			return []Event{{Kind: EventTextDelta, Text: delta}}
		case "thinking_delta":
			delta, _ := inner["delta"].(string)
			return []Event{{Kind: EventThinkingDelta, Text: delta}}
		case "thinking_start":
			return []Event{{Kind: EventThinkingStart}}
		case "thinking_end":
			return []Event{{Kind: EventThinkingEnd}}
		case "toolcall_start", "toolcall_end", "toolcall_delta", "text_start", "text_end":
			// toolcall_{start,end} fire when the LLM *plans* the call —
			// before it runs. We surface the execution frames below
			// (tool_execution_*) instead; those carry real args and
			// timing. text_start/end are already implied by delta
			// streaming.
			return nil
		case "":
			return nil
		default:
			p.addUnknown("message_update/" + itype)
			return nil
		}
	case "turn_end":
		msg, _ := evt["message"].(map[string]any)
		usage, _ := msg["usage"].(map[string]any)
		tokens := 0
		if total, ok := usage["totalTokens"].(float64); ok {
			tokens = int(total)
		}
		return []Event{{Kind: EventTurnEnd, TotalTokens: tokens}}
	case "tool_execution_start":
		id, _ := evt["toolCallId"].(string)
		name, _ := evt["toolName"].(string)
		args, _ := evt["args"].(map[string]any)
		return []Event{{
			Kind:           EventToolStart,
			ToolCallID:     id,
			ToolName:       name,
			ToolArgPreview: summarizeArgs(name, args),
		}}
	case "tool_execution_update":
		id, _ := evt["toolCallId"].(string)
		preview := ""
		if pr, _ := evt["partialResult"].(map[string]any); pr != nil {
			preview = extractContentText(pr["content"], toolPreviewMax)
		}
		return []Event{{
			Kind:           EventToolOutput,
			ToolCallID:     id,
			ToolOutputSize: int64(len(line)),
			ToolPreview:    preview,
		}}
	case "tool_execution_end":
		id, _ := evt["toolCallId"].(string)
		name, _ := evt["toolName"].(string)
		return []Event{{Kind: EventToolEnd, ToolCallID: id, ToolName: name}}
	case "auto_retry_start":
		return []Event{{
			Kind:         EventRetryStart,
			Attempt:      intFromAny(evt["attempt"]),
			MaxAttempts:  intFromAny(evt["maxAttempts"]),
			ErrorMessage: stringFromAny(evt["errorMessage"]),
		}}
	case "auto_retry_end":
		success, _ := evt["success"].(bool)
		final, _ := evt["finalError"].(string)
		return []Event{{Kind: EventRetryEnd, Success: success, FinalError: final}}
	case "session", "agent_start", "agent_end", "turn_start", "message_start", "message_end", "":
		return nil
	default:
		p.addUnknown(etype)
		return nil
	}
}

// Unknown returns the sorted set of event tags seen but not rendered.
func (p *PiAdapter) Unknown() []string {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := make([]string, 0, len(p.unknown))
	for k := range p.unknown {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// summarizeArgs renders a one-line preview of a pi tool_execution_start's
// args. Empty string if there's nothing useful to show. Output is clipped
// to argPreviewMax runes so it fits on one terminal line.
func summarizeArgs(name string, args map[string]any) string {
	s := ""
	switch name {
	case "bash":
		s, _ = args["command"].(string)
	case "find":
		pat, _ := args["pattern"].(string)
		path, _ := args["path"].(string)
		s = pat
		if base := filepath.Base(strings.TrimRight(path, "/")); path != "" && base != "." && base != "/" {
			s = pat + " in " + base
		}
	case "grep":
		s, _ = args["pattern"].(string)
	case "read", "write", "edit", "ls":
		if p, _ := args["path"].(string); p != "" {
			s = filepath.Base(p)
		}
	}
	if s == "" && len(args) > 0 {
		if b, err := json.Marshal(args); err == nil {
			s = string(b)
		}
	}
	s = strings.Join(strings.Fields(s), " ")
	return clipRunes(s, argPreviewMax)
}

// clipRunes truncates s to n runes, appending an ellipsis if clipped.
func clipRunes(s string, n int) string {
	if n <= 0 || len(s) == 0 {
		return s
	}
	i, count := 0, 0
	for i = range s {
		if count == n {
			return s[:i] + "…"
		}
		count++
	}
	return s
}

const argPreviewMax = 100

// toolPreviewMax caps how much tool-result text a single update event
// carries through the pipeline. 2 KiB is enough for five lines of test
// output or a short file read without dragging megabytes of streamed
// content through the renderer.
const toolPreviewMax = 2048

// extractContentText flattens pi's partialResult.content array into a
// string, pulling "text"-typed entries and joining them. Returns at most
// max bytes (UTF-8 boundary-aware).
func extractContentText(v any, max int) string {
	items, _ := v.([]any)
	if len(items) == 0 {
		return ""
	}
	var b strings.Builder
	for _, it := range items {
		m, _ := it.(map[string]any)
		if m == nil {
			continue
		}
		t, _ := m["type"].(string)
		if t != "text" && t != "" {
			continue
		}
		s, _ := m["text"].(string)
		if s == "" {
			continue
		}
		if b.Len() > 0 {
			b.WriteString("\n")
		}
		b.WriteString(s)
		if b.Len() >= max {
			break
		}
	}
	out := b.String()
	if len(out) <= max {
		return out
	}
	// Trim back to a rune boundary.
	for i := max; i > 0; i-- {
		if (out[i]&0xC0) != 0x80 && i < len(out) {
			return out[:i]
		}
	}
	return out[:max]
}

func intFromAny(v any) int {
	f, _ := v.(float64)
	return int(f)
}

func stringFromAny(v any) string {
	s, _ := v.(string)
	return s
}
