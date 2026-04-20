// Package eventrender turns a backend's JSONL event stream into prose + a
// live heartbeat. Backend-specific parsing is delegated to an Adapter; the
// renderer itself is source-agnostic.
package eventrender

import (
	"bufio"
	"fmt"
	"io"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Renderer reads a line-delimited event stream from In, asks Adapter to
// normalize each line, writes prose deltas to Out, and repaints a
// heartbeat to Status. Status may be nil to disable the heartbeat.
//
// Returns when In hits EOF. Errors from In are returned; parse failures
// inside Adapter are the adapter's problem (it reports them via Unknown()).
type Renderer struct {
	In          io.Reader
	Out         io.Writer
	Status      io.Writer
	Tick        time.Duration // heartbeat repaint cadence
	StatusTTY   bool          // if true, repaint Status with \r; else newline per tick
	StatusWidth int           // terminal width in columns; 0 disables truncation. Required in TTY mode to prevent wrap-induced ghost rows in scrollback.
	Label       string        // optional prefix shown on every status line, e.g. "[builder FEAT-42/3]"
	Brand       string        // backend name in the status line ("pi", "claude")
	Adapter     Adapter       // required: turns raw lines into normalized Events
}

// toolOutputWarnBytes flags a single tool call whose streamed output
// exceeds this size. A runaway tool streaming unbounded output is the
// most likely cause of a stuck/killed agent; the inline warning makes it
// obvious which call is responsible.
const toolOutputWarnBytes = 1 << 20

type stats struct {
	textChars   atomic.Int64
	thinkChars  atomic.Int64
	toolStarted atomic.Int64
	toolEnded   atomic.Int64
	events      atomic.Int64
	tokens      atomic.Int64 // last-seen cumulative token total from turn_end

	mu           sync.Mutex
	currentTool  string
	toolStarts   map[string]time.Time
	toolOutSize  map[string]int64
	toolNames    map[string]string
	retryAttempt int
	retryMax     int
	retryErr     string
}

// Run reads the stream and blocks until EOF.
func (r *Renderer) Run() error {
	if r.Tick == 0 {
		// Non-TTY output scrolls — a 1s heartbeat drowns the prose and
		// was the main source of noise in piped logs. Slow it down. TTY
		// mode still gets 1s because the paint overwrites in place.
		if r.StatusTTY {
			r.Tick = 1 * time.Second
		} else {
			r.Tick = 15 * time.Second
		}
	}
	if r.Brand == "" {
		r.Brand = "agent"
	}
	st := &stats{
		toolStarts:  map[string]time.Time{},
		toolOutSize: map[string]int64{},
		toolNames:   map[string]string{},
	}
	start := time.Now()
	stop := make(chan struct{})

	if r.Status != nil {
		go func() {
			ticker := time.NewTicker(r.Tick)
			defer ticker.Stop()
			for {
				select {
				case <-stop:
					return
				case <-ticker.C:
					r.paint(st, start)
				}
			}
		}()
	}

	scanner := bufio.NewScanner(r.In)
	scanner.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		if r.Adapter == nil {
			continue
		}
		events := r.Adapter.Parse(line)
		for _, ev := range events {
			r.apply(ev, st)
			st.events.Add(1)
		}
		// Intentionally no per-event paint. The ticker goroutine is
		// the only source of heartbeat updates; in a TTY the in-place
		// overwrite is invisible to the user but captured verbatim by
		// tmux scrollback, so painting 30-60 times a second produces
		// a wall of near-duplicate lines on copy-paste. 1 Hz is plenty.
	}
	close(stop)
	r.finish(st, start)
	return scanner.Err()
}

func (r *Renderer) apply(ev Event, st *stats) {
	switch ev.Kind {
	case EventTextDelta:
		// Text (the model's final prose answer) is deliberately not
		// rendered to stdout — it floods the live view during long
		// runs. The full text still lands in the JSONL event log for
		// post-hoc reading. Only the char counter advances so the
		// status line's text= column is still useful.
		st.textChars.Add(int64(len(ev.Text)))
	case EventThinkingStart, EventThinkingEnd:
		// Same as text deltas: structural-only rendering. Thinking
		// blocks are fully captured in the event log; surfacing them
		// live produced more noise than signal.
	case EventThinkingDelta:
		st.thinkChars.Add(int64(len(ev.Text)))
	case EventToolStart:
		name := ev.ToolName
		if name == "" {
			name = "?"
		}
		st.toolStarted.Add(1)
		st.mu.Lock()
		st.currentTool = name
		if ev.ToolCallID != "" {
			st.toolStarts[ev.ToolCallID] = time.Now()
			st.toolNames[ev.ToolCallID] = name
		}
		st.mu.Unlock()
	case EventToolOutput:
		if ev.ToolCallID == "" {
			return
		}
		st.mu.Lock()
		if ev.ToolOutputSize > 0 {
			st.toolOutSize[ev.ToolCallID] += ev.ToolOutputSize
		}
		st.mu.Unlock()
	case EventToolEnd:
		st.toolEnded.Add(1)
		name := ev.ToolName
		st.mu.Lock()
		if name == "" {
			name = st.toolNames[ev.ToolCallID]
		}
		size := st.toolOutSize[ev.ToolCallID]
		delete(st.toolStarts, ev.ToolCallID)
		delete(st.toolOutSize, ev.ToolCallID)
		delete(st.toolNames, ev.ToolCallID)
		st.currentTool = ""
		st.mu.Unlock()
		if name == "" {
			name = "?"
		}
		if size >= toolOutputWarnBytes && r.Status != nil {
			// Route the safety alert to the status stream so it surfaces
			// on stderr without polluting the otherwise-empty stdout.
			// Leading newline nudges it off the in-place heartbeat line.
			fmt.Fprintf(r.Status, "\n[LARGE OUTPUT from %s, %s]\n", name, humanBytes(size))
		}
	case EventRetryStart:
		st.mu.Lock()
		st.retryAttempt = ev.Attempt
		st.retryMax = ev.MaxAttempts
		st.retryErr = ev.ErrorMessage
		st.mu.Unlock()
	case EventRetryEnd:
		st.mu.Lock()
		st.retryAttempt = 0
		st.retryMax = 0
		st.retryErr = ""
		st.mu.Unlock()
	case EventTurnEnd:
		if ev.TotalTokens > 0 {
			st.tokens.Store(int64(ev.TotalTokens))
		}
	}
}

func (r *Renderer) paint(st *stats, start time.Time) {
	if r.Status == nil {
		return
	}
	st.mu.Lock()
	tool := st.currentTool
	retryAttempt := st.retryAttempt
	retryMax := st.retryMax
	retryErr := st.retryErr
	st.mu.Unlock()

	elapsed := time.Since(start)
	rate := 0.0
	if elapsed.Seconds() > 0 {
		rate = float64(st.events.Load()) / elapsed.Seconds()
	}
	toolBit := ""
	if tool != "" {
		toolBit = fmt.Sprintf("  tool=%s", tool)
	}
	retryBit := ""
	if retryAttempt > 0 {
		retryBit = fmt.Sprintf("  retry=%d/%d err=%q", retryAttempt, retryMax, truncErr(retryErr, 80))
	}
	tokensBit := ""
	if tok := st.tokens.Load(); tok > 0 {
		tokensBit = fmt.Sprintf("  tokens=%s", humanCount(tok))
	}
	prefix := ""
	if r.Label != "" {
		prefix = r.Label + "  "
	}
	line := fmt.Sprintf("%s%s %s  text=%s  think=%s%s  tools=%d/%d%s%s  ev/s=%.1f",
		prefix,
		r.Brand,
		humanTime(elapsed),
		humanCount(st.textChars.Load()),
		humanCount(st.thinkChars.Load()),
		tokensBit,
		st.toolStarted.Load(),
		st.toolEnded.Load(),
		toolBit,
		retryBit,
		rate,
	)
	if r.StatusTTY {
		// \033[K only erases the current terminal row, so a line that
		// wraps leaves the first row as a ghost in scrollback on every
		// tick. Truncate to width-1 to keep the paint on one row; the
		// -1 avoids writing the final column, which some terminals
		// treat as a wrap trigger.
		if r.StatusWidth > 0 {
			if runes := []rune(line); len(runes) >= r.StatusWidth {
				line = string(runes[:r.StatusWidth-1])
			}
		}
		fmt.Fprintf(r.Status, "\r\033[K%s", line)
	} else {
		fmt.Fprintln(r.Status, line)
	}
}

func (r *Renderer) finish(st *stats, start time.Time) {
	r.paint(st, start)
	if r.StatusTTY && r.Status != nil {
		fmt.Fprintln(r.Status)
	}
	if r.Adapter == nil || r.Status == nil {
		return
	}
	unknown := r.Adapter.Unknown()
	if len(unknown) == 0 {
		return
	}
	fmt.Fprint(r.Status, "(unknown event types seen: ")
	for i, k := range unknown {
		if i > 0 {
			fmt.Fprint(r.Status, ", ")
		}
		fmt.Fprint(r.Status, k)
	}
	fmt.Fprintln(r.Status, ")")
}

func humanTime(d time.Duration) string {
	s := int(d.Seconds())
	switch {
	case s < 60:
		return fmt.Sprintf("%ds", s)
	case s < 3600:
		return fmt.Sprintf("%dm%02ds", s/60, s%60)
	default:
		h := s / 3600
		m := (s % 3600) / 60
		return fmt.Sprintf("%dh%02dm", h, m)
	}
}

func humanCount(n int64) string {
	switch {
	case n < 1000:
		return fmt.Sprintf("%d", n)
	case n < 1_000_000:
		return fmt.Sprintf("%.1fk", float64(n)/1000)
	default:
		return fmt.Sprintf("%.1fM", float64(n)/1_000_000)
	}
}

// humanBytes is like humanCount but with byte-unit suffixes. Used for
// tool-output size reporting where the unit matters.
func humanBytes(n int64) string {
	switch {
	case n < 1000:
		return fmt.Sprintf("%dB", n)
	case n < 1_000_000:
		return fmt.Sprintf("%.1fkB", float64(n)/1000)
	default:
		return fmt.Sprintf("%.1fMB", float64(n)/1_000_000)
	}
}

// truncErr collapses whitespace and clips an error message to n runes for
// status-line display.
func truncErr(s string, n int) string {
	s = strings.Join(strings.Fields(s), " ")
	if n > 0 && len(s) > n {
		return s[:n] + "…"
	}
	return s
}
