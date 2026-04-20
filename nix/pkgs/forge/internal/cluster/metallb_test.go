package cluster

import (
	"context"
	"strings"
	"testing"
)

func TestRenderMetalLBPool(t *testing.T) {
	body := renderMetalLBPool("172.20.201.0/24")
	for _, want := range []string{
		"kind: IPAddressPool",
		"kind: L2Advertisement",
		"namespace: metallb-system",
		"- 172.20.201.0/24",
		"avoidBuggyIPs: true",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("rendered pool missing %q:\n%s", want, body)
		}
	}
}

func TestEnsureMetalLBSkipsWhenNoPool(t *testing.T) {
	f := &fakeExec{t: t}
	c := Cluster{Name: "forge-1"} // no MetalLBPool
	if err := EnsureMetalLB(context.Background(), f, "/tmp", c); err != nil {
		t.Errorf("no-pool cluster should be skipped, got: %v", err)
	}
}

func TestEnsureMetalLBHappyPath(t *testing.T) {
	// Stub stdinRunner to capture applied manifests.
	var applied []string
	prev := stdinRunner
	t.Cleanup(func() { stdinRunner = prev })
	stdinRunner = func(_ context.Context, stdin string, name string, args ...string) error {
		applied = append(applied, stdin)
		return nil
	}
	f := &fakeExec{t: t, calls: []fakeCall{
		{match: []string{"kubectl", "wait", "--for=condition=established", "crd/ipaddresspools.metallb.io"}, exit: 0},
		{match: []string{"kubectl", "wait", "--for=condition=established", "crd/l2advertisements.metallb.io"}, exit: 0},
		{match: []string{"kubectl", "wait", "deployment/controller", "--for=condition=available"}, exit: 0},
	}}
	c := Cluster{Name: "forge-1", MetalLBPool: "172.20.201.0/24"}
	if err := EnsureMetalLB(context.Background(), f, "/tmp", c); err != nil {
		t.Fatal(err)
	}
	if len(applied) != 2 {
		t.Fatalf("want 2 kubectl apply calls (MetalLB + pool), got %d", len(applied))
	}
	if !strings.Contains(applied[1], "172.20.201.0/24") {
		t.Errorf("pool apply missing pool range: %s", applied[1])
	}
}
