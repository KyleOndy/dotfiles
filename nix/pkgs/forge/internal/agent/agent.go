// Package agent dispatches a composed prompt to one of three configured
// backends: claude (CLI) or pi (CLI).
//
// Phase routing is owned by Router (capability-based), not the backends.
// Backends only know how to dispatch; the router picks who based on what
// the phase needs.
package agent

import (
	"context"
	"errors"
	"io"
	"time"
)

// Phase identifies which orchestrator step is dispatching. Used by Router
// to pick a capability-matched backend.
type Phase string

const (
	PhaseSpec      Phase = "spec"
	PhasePlan      Phase = "plan"
	PhaseDecompose Phase = "decompose"
	PhaseBuilder   Phase = "builder"
	PhaseCritic    Phase = "critic"
	PhaseArchitect Phase = "architect"
	PhaseRetro     Phase = "retro"
	PhaseStatus    Phase = "status"
	PhaseIterate   Phase = "iterate"
)

// NeedsToolCalls returns true for phases that mutate the filesystem
// (multi-file write, tool calls, code edits).
func (p Phase) NeedsToolCalls() bool {
	switch p {
	case PhaseDecompose, PhaseBuilder, PhaseCritic, PhaseArchitect, PhaseRetro:
		return true
	}
	return false
}

// Capabilities describes what a backend can do.
type Capabilities struct {
	ToolCalls     bool
	StreamingText bool
	FileWrites    bool // backend writes the target file directly (no tool calls)
}

// Request is one dispatch.
type Request struct {
	Prompt       string
	Phase        Phase
	TicketID     string
	TaskID       string
	TargetFile   string // relative to CWD; empty when the phase needs tool calls
	CWD          string
	ExtraDirs    []string
	AllowedTools []string
	Timeout      time.Duration
	Quiet        bool
	EventLog     io.Writer // backend tees its raw stream here
	Stdout       io.Writer // user-facing prose; defaults to os.Stdout
	Stderr       io.Writer // status/heartbeat; defaults to os.Stderr
	Model        string
	RetryAttempt int // flux-loop retry count for this task (0 = first attempt)
	RetryMax     int // flux-loop retry cap; 0 means "not known — omit from label"
	TaskTotal    int // total tasks in this ticket; 0 means unknown — omit from label
}

// Result of a dispatch.
type Result struct {
	Wrote      []string
	ExitStatus int
	DurationMs int64
}

// Backend is one configured agent transport.
type Backend interface {
	Name() string
	Preflight(ctx context.Context) error
	Capabilities() Capabilities
	Dispatch(ctx context.Context, r Request) (Result, error)
}

// Errors returned by backends and the router.
var (
	ErrMissingToolCalls = errors.New("backend lacks tool-call capability for this phase")
	ErrMissingTarget    = errors.New("backend has no target file and cannot write multi-file output")
	ErrPreflight        = errors.New("preflight failed")
	ErrUnknownBackend   = errors.New("unknown backend")
)
