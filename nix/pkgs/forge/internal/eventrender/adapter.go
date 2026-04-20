package eventrender

// EventKind identifies the normalized event shape an Adapter emits.
type EventKind int

const (
	EventNone EventKind = iota
	EventTextDelta
	EventThinkingStart
	EventThinkingDelta
	EventThinkingEnd
	EventToolStart
	EventToolOutput
	EventToolEnd
	EventRetryStart
	EventRetryEnd
	EventTurnEnd
)

// Event is the normalized representation of a backend stream event that the
// renderer knows how to surface. Adapters convert backend-specific JSON
// lines into zero or more Events per line.
type Event struct {
	Kind           EventKind
	Text           string // TextDelta / ThinkingDelta payload
	ToolName       string // ToolStart / ToolEnd
	ToolCallID     string // ToolStart / ToolOutput / ToolEnd — correlates the three
	ToolArgPreview string // ToolStart — short one-line summary of args
	ToolOutputSize int64  // ToolOutput — bytes observed for this frame (cumulative done renderer-side)
	ToolPreview    string // ToolOutput — clipped text preview of partial result (may be empty)
	Attempt        int    // RetryStart / RetryEnd
	MaxAttempts    int    // RetryStart
	ErrorMessage   string // RetryStart
	Success        bool   // RetryEnd
	FinalError     string // RetryEnd (on failure)
	TotalTokens    int    // TurnEnd
}

// Adapter turns raw backend stream bytes into normalized Events. Parse is
// called once per scanned line. Unknown returns event-type tags the adapter
// saw but ignored, for diagnostic output at end-of-stream.
type Adapter interface {
	Parse(line []byte) []Event
	Unknown() []string
}
