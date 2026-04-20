package cluster

import (
	"context"
	"strings"
	"testing"
)

func TestRenderKindConfig(t *testing.T) {
	c := Cluster{
		Name: "forge-1",
		Nodes: []Node{
			{Role: "control-plane"},
			{Role: "worker"},
		},
	}
	out := RenderKindConfig(c)
	// must declare apiVersion, containerdConfigPatches, and each node role
	for _, want := range []string{
		"apiVersion: kind.x-k8s.io/v1alpha4",
		"containerdConfigPatches:",
		`config_path = "/etc/containerd/certs.d"`,
		"- role: control-plane",
		"- role: worker",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("RenderKindConfig output missing %q\n--- got ---\n%s", want, out)
		}
	}
}

func TestKindClusterExists(t *testing.T) {
	cases := []struct {
		name   string
		stdout string
		target string
		want   bool
	}{
		{"present", "forge-mgmt\nforge-1\nother\n", "forge-1", true},
		{"absent", "forge-mgmt\nother\n", "forge-1", false},
		{"empty", "", "forge-1", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := &fakeExec{t: t, calls: []fakeCall{
				{match: []string{"kind", "get", "clusters"}, out: tc.stdout},
			}}
			got, err := KindClusterExists(context.Background(), f, tc.target)
			if err != nil {
				t.Fatal(err)
			}
			if got != tc.want {
				t.Errorf("got %v, want %v", got, tc.want)
			}
		})
	}
}

func TestKindDeleteClusterAbsent(t *testing.T) {
	// Deleting a non-existent cluster must be a no-op (idempotent).
	f := &fakeExec{t: t, calls: []fakeCall{
		{match: []string{"kind", "get", "clusters"}, out: ""},
	}}
	if err := KindDeleteCluster(context.Background(), f, "forge-1"); err != nil {
		t.Errorf("unexpected error on absent cluster: %v", err)
	}
}
