package cluster

import (
	"context"
	"testing"
)

// fakeExecAny is a looser fake that matches any call and records it. Lets
// us assert on call counts rather than precise prefix matches when the
// exact sequence depends on map iteration order.
type fakeExecAny struct {
	t     *testing.T
	calls [][]string
	// reply returns (stdout, exit) for the given cmd invocation.
	reply func(cmd []string) (string, int)
}

func (f *fakeExecAny) Run(_ context.Context, name string, args ...string) (RunResult, error) {
	cmd := append([]string{name}, args...)
	f.calls = append(f.calls, cmd)
	out, exit := "", 0
	if f.reply != nil {
		out, exit = f.reply(cmd)
	}
	res := RunResult{Stdout: out, ExitCode: exit}
	if exit != 0 {
		return res, fakeExitError{exit: exit}
	}
	return res, nil
}

type fakeExitError struct{ exit int }

func (e fakeExitError) Error() string { return "exit " + itoa(e.exit) }
func (e fakeExitError) ExitCode() int { return e.exit }

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var b [8]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		b[i] = '-'
	}
	return string(b[i:])
}

func TestTearDownDownModeDeletesClustersOnly(t *testing.T) {
	cfg, err := Load(writeConfig(t, validConfig))
	if err != nil {
		t.Fatal(err)
	}
	f := &fakeExecAny{t: t, reply: func(cmd []string) (string, int) {
		// `kind get clusters` → list both declared clusters as present.
		if len(cmd) >= 3 && cmd[0] == "kind" && cmd[1] == "get" && cmd[2] == "clusters" {
			return "forge-mgmt\nforge-1\n", 0
		}
		return "", 0
	}}
	if err := TearDown(context.Background(), f, cfg, false); err != nil {
		t.Fatal(err)
	}
	// Must have issued `kind delete cluster` for both. Must NOT have
	// touched mirrors / volumes / dns / network.
	deletes := 0
	for _, c := range f.calls {
		if len(c) >= 3 && c[0] == "kind" && c[1] == "delete" && c[2] == "cluster" {
			deletes++
		}
		if len(c) >= 2 && c[0] == "docker" && (c[1] == "volume" || c[1] == "rm" || c[1] == "network") {
			if c[1] == "volume" && len(c) >= 3 && c[2] == "rm" {
				t.Errorf("down mode should not remove volumes, saw: %v", c)
			}
			if c[1] == "network" && len(c) >= 3 && c[2] == "rm" {
				t.Errorf("down mode should not remove network, saw: %v", c)
			}
		}
	}
	if deletes != 2 {
		t.Errorf("want 2 kind delete calls, got %d", deletes)
	}
}

func TestTearDownNukeModeRemovesEverything(t *testing.T) {
	cfg, err := Load(writeConfig(t, validConfig))
	if err != nil {
		t.Fatal(err)
	}
	f := &fakeExecAny{t: t, reply: func(cmd []string) (string, int) {
		switch {
		case len(cmd) >= 3 && cmd[0] == "kind" && cmd[1] == "get" && cmd[2] == "clusters":
			return "forge-mgmt\nforge-1\n", 0
		case len(cmd) >= 2 && cmd[0] == "docker" && cmd[1] == "inspect":
			return "running", 0 // container present
		case len(cmd) >= 4 && cmd[0] == "docker" && cmd[1] == "network" && cmd[2] == "inspect":
			return "", 0 // network present
		}
		return "", 0
	}}
	if err := TearDown(context.Background(), f, cfg, true); err != nil {
		t.Fatal(err)
	}
	saw := map[string]int{}
	for _, c := range f.calls {
		switch {
		case len(c) >= 3 && c[0] == "kind" && c[1] == "delete" && c[2] == "cluster":
			saw["cluster-delete"]++
		case len(c) >= 3 && c[0] == "docker" && c[1] == "rm" && c[2] == "-f":
			saw["container-rm"]++
		case len(c) >= 3 && c[0] == "docker" && c[1] == "volume" && c[2] == "rm":
			saw["volume-rm"]++
		case len(c) >= 3 && c[0] == "docker" && c[1] == "network" && c[2] == "rm":
			saw["network-rm"]++
		}
	}
	if saw["cluster-delete"] != 2 {
		t.Errorf("cluster-delete = %d, want 2", saw["cluster-delete"])
	}
	if saw["container-rm"] < 2 {
		// 2 mirrors + forge-dns = at least 3, but some may fall through
		// StopMirror paths we don't precisely count. Just sanity check.
		t.Errorf("container-rm = %d, want at least 2 (mirrors + dns)", saw["container-rm"])
	}
	if saw["volume-rm"] < 2 {
		t.Errorf("volume-rm = %d, want at least 2 (mirror volumes)", saw["volume-rm"])
	}
	if saw["network-rm"] != 1 {
		t.Errorf("network-rm = %d, want 1", saw["network-rm"])
	}
}

func TestTearDownDeletesOrphanClusters(t *testing.T) {
	cfg, err := Load(writeConfig(t, validConfig))
	if err != nil {
		t.Fatal(err)
	}
	// Discovered clusters include forge-ghost, which isn't in the config.
	f := &fakeExecAny{t: t, reply: func(cmd []string) (string, int) {
		if len(cmd) >= 3 && cmd[0] == "kind" && cmd[1] == "get" && cmd[2] == "clusters" {
			return "forge-mgmt\nforge-1\nforge-ghost\n", 0
		}
		return "", 0
	}}
	if err := TearDown(context.Background(), f, cfg, false); err != nil {
		t.Fatal(err)
	}
	deleted := map[string]bool{}
	for _, c := range f.calls {
		if len(c) >= 5 && c[0] == "kind" && c[1] == "delete" && c[2] == "cluster" && c[3] == "--name" {
			deleted[c[4]] = true
		}
	}
	for _, name := range []string{"forge-mgmt", "forge-1", "forge-ghost"} {
		if !deleted[name] {
			t.Errorf("did not delete cluster %s; deleted=%v", name, deleted)
		}
	}
}
