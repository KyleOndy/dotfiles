package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
)

type piEvent struct {
	Type                  string             `json:"type"`
	AssistantMessageEvent *assistantMsgEvent `json:"assistantMessageEvent,omitempty"`
	Message               *piMessage         `json:"message,omitempty"`

	// tool_execution_* fields (top-level events, not inside message_update)
	ToolName string          `json:"toolName,omitempty"`
	Result   json.RawMessage `json:"result,omitempty"`
	IsError  bool            `json:"isError,omitempty"`

	// agent_end
	Messages []piMessage `json:"messages,omitempty"`
}

type assistantMsgEvent struct {
	Type         string `json:"type"`
	Delta        string `json:"delta"`
	ContentIndex int    `json:"contentIndex"`
}

type piMessage struct {
	Role       string         `json:"role"`
	Content    []contentBlock `json:"content"`
	StopReason string         `json:"stopReason,omitempty"`
	ErrorMsg   string         `json:"errorMessage,omitempty"`
	Usage      *usageInfo     `json:"usage,omitempty"`
}

type contentBlock struct {
	Type string `json:"type"`
	Name string `json:"name,omitempty"`
}

type usageInfo struct {
	Input       int `json:"input"`
	Output      int `json:"output"`
	TotalTokens int `json:"totalTokens"`
}

func streamEvents(r io.Reader, eventLog io.Writer) {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 256*1024), 256*1024)

	for scanner.Scan() {
		line := bytes.TrimRight(scanner.Bytes(), "\r")
		if len(line) == 0 {
			continue
		}

		if eventLog != nil {
			eventLog.Write(line)
			eventLog.Write([]byte("\n"))
		}

		var ev piEvent
		if err := json.Unmarshal(line, &ev); err != nil {
			continue
		}

		switch ev.Type {
		case "message_update":
			handleMessageUpdate(ev)

		case "tool_execution_end":
			handleToolResult(ev)

		case "message_end":
			handleMessageEnd(ev)

		case "agent_end":
			handleAgentEnd(ev)
			return // pi is done; don't wait for the process to exit on its own

		case "turn_end":
			fmt.Println()
		}
	}
}

func handleMessageUpdate(ev piEvent) {
	ame := ev.AssistantMessageEvent
	if ame == nil {
		return
	}
	switch ame.Type {
	case "text_start", "text_end":
		// no-op; text_delta handles content
	case "text_delta":
		fmt.Print(ame.Delta)
	case "thinking_start":
		// no-op; thinking_delta handles content
	case "thinking_delta":
		fmt.Fprintf(os.Stderr, "%s", ame.Delta)
	case "thinking_end":
		fmt.Fprintln(os.Stderr)
	case "toolcall_start":
		name := toolName(ev)
		fmt.Fprintf(os.Stderr, "[tool: %s] ", name)
	case "toolcall_delta":
		fmt.Fprint(os.Stderr, ".")
	case "toolcall_end":
		fmt.Fprintln(os.Stderr)
	default:
		fmt.Fprintf(os.Stderr, "[unhandled: %s] ", ame.Type)
	}
}

func handleToolResult(ev piEvent) {
	if ev.IsError {
		fmt.Fprintf(os.Stderr, "[%s error] %s\n", ev.ToolName, resultText(ev.Result))
		return
	}
	text := resultText(ev.Result)
	if text == "" {
		return
	}
	// Show tool output, truncated to keep it readable
	lines := strings.SplitN(text, "\n", 6)
	if len(lines) > 5 {
		lines = append(lines[:5], "...")
	}
	for _, l := range lines {
		fmt.Fprintf(os.Stderr, "  %s\n", truncate(l, 120))
	}
}

func handleMessageEnd(ev piEvent) {
	if ev.Message == nil {
		return
	}
	switch ev.Message.StopReason {
	case "error", "aborted":
		msg := ev.Message.ErrorMsg
		if msg == "" {
			msg = "request " + ev.Message.StopReason
		}
		fmt.Fprintf(os.Stderr, "[error] %s\n", msg)
	}
}

func handleAgentEnd(ev piEvent) {
	var total usageInfo
	for _, msg := range ev.Messages {
		if msg.Role == "assistant" && msg.Usage != nil {
			total.Input += msg.Usage.Input
			total.Output += msg.Usage.Output
			total.TotalTokens += msg.Usage.TotalTokens
		}
	}
	if total.TotalTokens > 0 {
		fmt.Fprintf(os.Stderr, "[tokens] in=%d out=%d total=%d\n",
			total.Input, total.Output, total.TotalTokens)
	}
}

func toolName(ev piEvent) string {
	if ev.Message == nil {
		return "?"
	}
	idx := ev.AssistantMessageEvent.ContentIndex
	if idx < len(ev.Message.Content) {
		if name := ev.Message.Content[idx].Name; name != "" {
			return name
		}
	}
	return "?"
}

// resultText extracts a readable string from a tool result.
// Results vary: plain string, content block array, or
// {"content":[{"type":"text","text":"..."}],"details":{}} wrapper.
func resultText(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	// Try plain string
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	// Try {"content":[...],...} wrapper (common for tool results)
	var wrapper struct {
		Content []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"content"`
	}
	if json.Unmarshal(raw, &wrapper) == nil && len(wrapper.Content) > 0 {
		var parts []string
		for _, b := range wrapper.Content {
			if b.Text != "" {
				parts = append(parts, b.Text)
			}
		}
		if len(parts) > 0 {
			return strings.Join(parts, "\n")
		}
	}
	// Try bare content block array
	if json.Unmarshal(raw, &wrapper.Content) == nil {
		var parts []string
		for _, b := range wrapper.Content {
			if b.Text != "" {
				parts = append(parts, b.Text)
			}
		}
		if len(parts) > 0 {
			return strings.Join(parts, "\n")
		}
	}
	return ""
}

func truncate(s string, max int) string {
	if len(s) <= max {
		return s
	}
	return s[:max] + "..."
}
