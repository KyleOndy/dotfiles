package eventrender

import (
	"encoding/json"
	"sort"
	"strconv"
	"sync"
)

// ClaudeAdapter parses the Claude Code CLI's `--output-format stream-json`
// NDJSON output (with --include-partial-messages --verbose).
//
// The stream contains three kinds of lines:
//   - Top-level claude-code frames: {"type":"system"|"assistant"|"user"|"result", ...}
//   - Wrapped Anthropic SDK streaming events: {"type":"stream_event","event":{...}}
//   - Interleaved api_retry notices from the claude-code transport layer.
//
// See https://code.claude.com/docs/en/headless#stream-responses
type ClaudeAdapter struct {
	mu      sync.Mutex
	unknown map[string]struct{}
	blocks  map[int]string // index -> block type (text|thinking|tool_use)
	inRetry bool
}

// NewClaudeAdapter returns a ready-to-use ClaudeAdapter. Reuse one instance
// per stream so block-index tracking stays consistent.
func NewClaudeAdapter() *ClaudeAdapter {
	return &ClaudeAdapter{blocks: map[int]string{}}
}

func (c *ClaudeAdapter) addUnknown(t string) {
	c.mu.Lock()
	if c.unknown == nil {
		c.unknown = map[string]struct{}{}
	}
	c.unknown[t] = struct{}{}
	c.mu.Unlock()
}

// Parse turns one NDJSON line into normalized events.
func (c *ClaudeAdapter) Parse(line []byte) []Event {
	var evt map[string]any
	if err := json.Unmarshal(line, &evt); err != nil {
		c.addUnknown("<malformed-json>")
		return nil
	}
	top, _ := evt["type"].(string)
	switch top {
	case "stream_event":
		inner, _ := evt["event"].(map[string]any)
		if inner == nil {
			return nil
		}
		return c.parseStreamEvent(inner)
	case "system":
		sub, _ := evt["subtype"].(string)
		switch sub {
		case "api_retry":
			c.mu.Lock()
			c.inRetry = true
			c.mu.Unlock()
			return []Event{{
				Kind:         EventRetryStart,
				Attempt:      intFromAny(evt["attempt"]),
				MaxAttempts:  intFromAny(evt["max_retries"]),
				ErrorMessage: retryErrorMessage(evt),
			}}
		case "init", "plugin_install", "status":
			return nil
		default:
			if sub != "" {
				c.addUnknown("system/" + sub)
			}
			return nil
		}
	case "assistant", "user":
		// Full assembled messages — we've already rendered deltas. Ignore,
		// but treat their arrival after a retry as "retry succeeded".
		return c.maybeEndRetry(true)
	case "result":
		usage, _ := evt["usage"].(map[string]any)
		tokens := intFromAny(usage["input_tokens"]) + intFromAny(usage["output_tokens"])
		sub, _ := evt["subtype"].(string)
		out := c.maybeEndRetry(sub == "success")
		return append(out, Event{Kind: EventTurnEnd, TotalTokens: tokens})
	case "":
		return nil
	default:
		c.addUnknown(top)
		return nil
	}
}

// parseStreamEvent handles an Anthropic-SDK-shaped event (content_block_*,
// message_delta, message_start/stop, etc.).
func (c *ClaudeAdapter) parseStreamEvent(inner map[string]any) []Event {
	itype, _ := inner["type"].(string)
	switch itype {
	case "content_block_start":
		idx := intFromAny(inner["index"])
		block, _ := inner["content_block"].(map[string]any)
		btype, _ := block["type"].(string)
		c.mu.Lock()
		c.blocks[idx] = btype
		c.mu.Unlock()
		if btype == "tool_use" {
			name, _ := block["name"].(string)
			out := c.maybeEndRetry(true)
			return append(out, Event{Kind: EventToolStart, ToolName: name})
		}
		// Entering text/thinking block after a retry means the retry worked.
		return c.maybeEndRetry(true)
	case "content_block_delta":
		delta, _ := inner["delta"].(map[string]any)
		dtype, _ := delta["type"].(string)
		switch dtype {
		case "text_delta":
			txt, _ := delta["text"].(string)
			return []Event{{Kind: EventTextDelta, Text: txt}}
		case "thinking_delta":
			txt, _ := delta["thinking"].(string)
			return []Event{{Kind: EventThinkingDelta, Text: txt}}
		case "input_json_delta", "signature_delta":
			// Tool args / thinking signatures — not surfaced.
			return nil
		case "":
			return nil
		default:
			c.addUnknown("content_block_delta/" + dtype)
			return nil
		}
	case "content_block_stop":
		idx := intFromAny(inner["index"])
		c.mu.Lock()
		btype := c.blocks[idx]
		delete(c.blocks, idx)
		c.mu.Unlock()
		if btype == "tool_use" {
			return []Event{{Kind: EventToolEnd}}
		}
		return nil
	case "message_start", "message_delta", "message_stop", "ping":
		return nil
	case "":
		return nil
	default:
		c.addUnknown("stream_event/" + itype)
		return nil
	}
}

// maybeEndRetry emits a RetryEnd if a retry was in flight. success encodes
// whether we're resolving cleanly or giving up.
func (c *ClaudeAdapter) maybeEndRetry(success bool) []Event {
	c.mu.Lock()
	if !c.inRetry {
		c.mu.Unlock()
		return nil
	}
	c.inRetry = false
	c.mu.Unlock()
	return []Event{{Kind: EventRetryEnd, Success: success}}
}

// Unknown returns the sorted set of event tags seen but not rendered.
func (c *ClaudeAdapter) Unknown() []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make([]string, 0, len(c.unknown))
	for k := range c.unknown {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// retryErrorMessage extracts a human-readable string from either a plain
// `error` field or a nested `{message|status|...}` object.
func retryErrorMessage(evt map[string]any) string {
	if s, ok := evt["error"].(string); ok && s != "" {
		return s
	}
	if m, ok := evt["error"].(map[string]any); ok {
		if s, ok := m["message"].(string); ok && s != "" {
			return s
		}
	}
	if s, ok := evt["error_status"].(string); ok && s != "" {
		return s
	}
	if n, ok := evt["error_status"].(float64); ok {
		return httpStatusText(int(n))
	}
	return ""
}

func httpStatusText(code int) string {
	switch code {
	case 429:
		return "429 too many requests"
	case 500:
		return "500 internal error"
	case 502:
		return "502 bad gateway"
	case 503:
		return "503 service unavailable"
	case 504:
		return "504 gateway timeout"
	}
	if code > 0 {
		return "http " + strconv.Itoa(code)
	}
	return ""
}
