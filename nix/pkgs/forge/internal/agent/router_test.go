package agent

import (
	"context"
	"errors"
	"testing"
)

type fakeBackend struct {
	name string
	caps Capabilities

	preflightErr error
	dispatchErr  error
	lastReq      Request
}

func (f *fakeBackend) Name() string                      { return f.name }
func (f *fakeBackend) Capabilities() Capabilities        { return f.caps }
func (f *fakeBackend) Preflight(_ context.Context) error { return f.preflightErr }
func (f *fakeBackend) Dispatch(_ context.Context, r Request) (Result, error) {
	f.lastReq = r
	if f.dispatchErr != nil {
		return Result{}, f.dispatchErr
	}
	return Result{}, nil
}

func TestRouterPicksDefaultForNonToolPhase(t *testing.T) {
	def := &fakeBackend{name: "file-only", caps: Capabilities{FileWrites: true}}
	pi := &fakeBackend{name: "pi", caps: Capabilities{ToolCalls: true}}
	r := NewRouter(def, []Backend{def, pi})

	got, err := r.Pick(PhaseSpec)
	if err != nil {
		t.Fatal(err)
	}
	if got.Name() != "file-only" {
		t.Errorf("Pick(spec): got %q want file-only", got.Name())
	}
}

func TestRouterSwapsToToolBackendForBuilder(t *testing.T) {
	def := &fakeBackend{name: "file-only", caps: Capabilities{FileWrites: true}}
	pi := &fakeBackend{name: "pi", caps: Capabilities{ToolCalls: true}}
	r := NewRouter(def, []Backend{def, pi})

	got, err := r.Pick(PhaseBuilder)
	if err != nil {
		t.Fatal(err)
	}
	if got.Name() != "pi" {
		t.Errorf("Pick(builder): got %q want pi", got.Name())
	}
}

func TestRouterErrorsWhenNoToolBackend(t *testing.T) {
	def := &fakeBackend{name: "file-only", caps: Capabilities{FileWrites: true}}
	r := NewRouter(def, []Backend{def})

	_, err := r.Pick(PhaseBuilder)
	if !errors.Is(err, ErrMissingToolCalls) {
		t.Errorf("expected ErrMissingToolCalls; got %v", err)
	}
}

func TestRouterDispatchRefusesEmptyTargetForFileBackend(t *testing.T) {
	def := &fakeBackend{name: "file-only", caps: Capabilities{FileWrites: true}}
	r := NewRouter(def, []Backend{def})

	_, err := r.Dispatch(context.Background(), Request{Phase: PhaseSpec, TargetFile: ""})
	if !errors.Is(err, ErrMissingTarget) {
		t.Errorf("expected ErrMissingTarget; got %v", err)
	}
}

func TestRouterDispatchRunsPreflight(t *testing.T) {
	def := &fakeBackend{name: "file-only", caps: Capabilities{FileWrites: true}, preflightErr: errors.New("missing key")}
	r := NewRouter(def, []Backend{def})

	_, err := r.Dispatch(context.Background(), Request{Phase: PhaseSpec, TargetFile: "SPEC.md"})
	if !errors.Is(err, ErrPreflight) {
		t.Errorf("expected ErrPreflight; got %v", err)
	}
}

func TestRouterDispatchSuccessForwards(t *testing.T) {
	def := &fakeBackend{name: "claude", caps: Capabilities{ToolCalls: true, StreamingText: true}}
	r := NewRouter(def, []Backend{def})

	_, err := r.Dispatch(context.Background(), Request{Phase: PhaseBuilder, Prompt: "hi"})
	if err != nil {
		t.Fatal(err)
	}
	if def.lastReq.Prompt != "hi" {
		t.Errorf("backend didn't receive request")
	}
}
