package agent

import (
	"context"
	"fmt"
)

// Router holds the configured default backend plus any tool-capable
// alternatives. Pick(phase) returns the right backend for the phase.
type Router struct {
	Default   Backend
	Available map[string]Backend
}

// NewRouter builds a router. The default is the named backend; available
// is keyed by Backend.Name().
func NewRouter(def Backend, all []Backend) *Router {
	avail := map[string]Backend{}
	for _, b := range all {
		avail[b.Name()] = b
	}
	if _, ok := avail[def.Name()]; !ok {
		avail[def.Name()] = def
	}
	return &Router{Default: def, Available: avail}
}

// Pick returns the backend that should handle a phase. If the default
// cannot handle the phase (e.g. no tool calls for builder/critic) and a
// tool-capable backend exists in Available, that one is returned instead.
func (r *Router) Pick(p Phase) (Backend, error) {
	def := r.Default
	caps := def.Capabilities()
	if !p.NeedsToolCalls() {
		return def, nil
	}
	if caps.ToolCalls {
		return def, nil
	}
	// Default lacks tool calls but the phase needs them. Find any
	// available backend with ToolCalls=true.
	for _, b := range r.Available {
		if b.Name() == def.Name() {
			continue
		}
		if b.Capabilities().ToolCalls {
			return b, nil
		}
	}
	return nil, fmt.Errorf("%w: phase %s needs tool calls; default backend %s lacks them and no tool-capable alternative is available", ErrMissingToolCalls, p, def.Name())
}

// Dispatch picks the right backend, runs preflight, validates the request
// shape, and forwards the dispatch.
func (r *Router) Dispatch(ctx context.Context, req Request) (Result, error) {
	b, err := r.Pick(req.Phase)
	if err != nil {
		return Result{}, err
	}
	caps := b.Capabilities()
	if !caps.ToolCalls && req.TargetFile == "" {
		return Result{}, fmt.Errorf("%w: backend %s for phase %s requires a TargetFile", ErrMissingTarget, b.Name(), req.Phase)
	}
	if err := b.Preflight(ctx); err != nil {
		return Result{}, fmt.Errorf("%w (%s): %v", ErrPreflight, b.Name(), err)
	}
	return b.Dispatch(ctx, req)
}
