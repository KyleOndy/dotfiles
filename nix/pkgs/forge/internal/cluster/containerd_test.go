package cluster

import (
	"context"
	"strings"
	"testing"
)

func TestHostsTomlRender(t *testing.T) {
	body := hostsToml("https://registry-1.docker.io", "forge-mirror-dockerio")
	for _, want := range []string{
		`server = "https://registry-1.docker.io"`,
		`[host."http://forge-mirror-dockerio:5000"]`,
		`capabilities = ["pull", "resolve", "push"]`,
	} {
		if !strings.Contains(body, want) {
			t.Errorf("hosts.toml missing %q:\n%s", want, body)
		}
	}
}

func TestConfigureNodeMirrorsNoOpWhenEmpty(t *testing.T) {
	f := &fakeExec{t: t}
	if err := ConfigureNodeMirrors(context.Background(), f, "forge-1", nil); err != nil {
		t.Errorf("empty mirrors should be a no-op, got: %v", err)
	}
}

func TestConfigureNodeMirrorsWritesPerNodePerMirror(t *testing.T) {
	// Stub stdinRunner to record invocations instead of really shelling.
	type call struct {
		cmd   string
		args  []string
		stdin string
	}
	var recorded []call
	prev := stdinRunner
	t.Cleanup(func() { stdinRunner = prev })
	stdinRunner = func(_ context.Context, stdin string, name string, args ...string) error {
		recorded = append(recorded, call{cmd: name, args: args, stdin: stdin})
		return nil
	}

	f := &fakeExec{t: t, calls: []fakeCall{
		{match: []string{"kind", "get", "nodes", "--name", "forge-1"}, out: "forge-1-control-plane\nforge-1-worker\n"},
		// mkdir calls — two nodes × one mirror = 2 mkdirs
		{match: []string{"docker", "exec", "forge-1-control-plane", "mkdir", "-p", "/etc/containerd/certs.d/docker.io"}, exit: 0},
		{match: []string{"docker", "exec", "forge-1-worker", "mkdir", "-p", "/etc/containerd/certs.d/docker.io"}, exit: 0},
	}}
	mirrors := []Mirror{{
		Name:     "dockerio",
		Upstream: "https://registry-1.docker.io",
		Registry: "docker.io",
		HostPort: 5100,
	}}
	if err := ConfigureNodeMirrors(context.Background(), f, "forge-1", mirrors); err != nil {
		t.Fatal(err)
	}
	if len(recorded) != 2 {
		t.Fatalf("want 2 tee calls (2 nodes × 1 mirror), got %d: %+v", len(recorded), recorded)
	}
	for _, c := range recorded {
		if !strings.Contains(c.stdin, "forge-mirror-dockerio") {
			t.Errorf("hosts.toml missing mirror container ref: %q", c.stdin)
		}
	}
}
