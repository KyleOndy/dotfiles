package cluster

import (
	"context"
	"strings"
	"testing"
)

func TestForgeTestServerBlock(t *testing.T) {
	block := forgeTestServerBlock("172.20.0.2")
	for _, want := range []string{
		"forge.test:53 {",
		"forward . 172.20.0.2",
		"cache 30",
	} {
		if !strings.Contains(block, want) {
			t.Errorf("block missing %q:\n%s", want, block)
		}
	}
}

func TestPatchCoreDNSSkipsWhenAlreadyPatched(t *testing.T) {
	f := &fakeExec{t: t, calls: []fakeCall{
		{match: []string{"kubectl", "get", "configmap", "coredns"}, out: `.:53 {
    cache 30
}
forge.test:53 {
    forward . 172.20.0.2
}`},
		// No patch / restart should be attempted; fakeExec fails on unexpected.
	}}
	if err := PatchCoreDNS(context.Background(), f, "/tmp", "forge-1", "172.20.0.2"); err != nil {
		t.Fatal(err)
	}
}

func TestPatchCoreDNSPatchesWhenAbsent(t *testing.T) {
	f := &fakeExec{t: t, calls: []fakeCall{
		{match: []string{"kubectl", "get", "configmap", "coredns"}, out: `.:53 {
    cache 30
}`},
		{match: []string{"kubectl", "patch", "configmap", "coredns"}, exit: 0},
		{match: []string{"kubectl", "rollout", "restart", "deployment/coredns"}, exit: 0},
	}}
	if err := PatchCoreDNS(context.Background(), f, "/tmp", "forge-1", "172.20.0.2"); err != nil {
		t.Fatal(err)
	}
}
