package cluster

import (
	"context"
	"strings"
	"testing"
)

func TestEnsureComponentsEmptyIsNoOp(t *testing.T) {
	f := &fakeExec{t: t}
	c := Cluster{Name: "forge-1"}
	if err := EnsureComponents(context.Background(), f, "/tmp", c); err != nil {
		t.Errorf("no components should be a no-op, got: %v", err)
	}
}

func TestEnsureIngressNginxAppliesAndAnnotates(t *testing.T) {
	var applied []string
	prev := stdinRunner
	t.Cleanup(func() { stdinRunner = prev })
	stdinRunner = func(_ context.Context, stdin string, name string, args ...string) error {
		applied = append(applied, stdin)
		return nil
	}
	f := &fakeExec{t: t, calls: []fakeCall{
		{match: []string{"kubectl", "wait", "deployment/ingress-nginx-controller"}, exit: 0},
		{match: []string{"kubectl", "annotate", "service", "ingress-nginx-controller"}, exit: 0},
	}}
	c := Cluster{
		Name:        "forge-1",
		MetalLBPool: "172.20.201.0/24",
		Components:  []string{ComponentIngressNginx},
	}
	if err := EnsureComponents(context.Background(), f, "/tmp", c); err != nil {
		t.Fatal(err)
	}
	if len(applied) != 1 {
		t.Fatalf("want 1 kubectl apply call (ingress-nginx manifest), got %d", len(applied))
	}
	if !strings.Contains(applied[0], "ingress-nginx") {
		t.Errorf("applied manifest doesn't look like ingress-nginx: %q…", applied[0][:200])
	}
}

func TestEnsureIngressNginxSkipsAnnotateWithoutPool(t *testing.T) {
	// Stub stdinRunner so apply is captured but doesn't actually run kubectl.
	prev := stdinRunner
	t.Cleanup(func() { stdinRunner = prev })
	stdinRunner = func(_ context.Context, _ string, _ string, _ ...string) error { return nil }

	f := &fakeExec{t: t, calls: []fakeCall{
		{match: []string{"kubectl", "wait", "deployment/ingress-nginx-controller"}, exit: 0},
		// No annotate call — clusters without MetalLB pools skip it.
	}}
	c := Cluster{
		Name:       "forge-1",
		Components: []string{ComponentIngressNginx},
	}
	if err := EnsureComponents(context.Background(), f, "/tmp", c); err != nil {
		t.Fatal(err)
	}
}
