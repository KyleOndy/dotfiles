package cluster

import (
	"context"
	"errors"
	"os/exec"
	"strings"
	"testing"
)

// fakeExec is an Executor that matches (name, args...) prefixes to canned
// results. The first matching mapping wins. Unmatched invocations fail the
// test.
type fakeExec struct {
	t     *testing.T
	calls []fakeCall
}

type fakeCall struct {
	match  []string // expected prefix of (name, args...)
	out    string
	errOut string
	exit   int
}

func (f *fakeExec) Run(_ context.Context, name string, args ...string) (RunResult, error) {
	cmd := append([]string{name}, args...)
	for _, c := range f.calls {
		if prefixMatch(cmd, c.match) {
			res := RunResult{Stdout: c.out, Stderr: c.errOut, ExitCode: c.exit}
			if c.exit != 0 {
				return res, &exec.ExitError{ProcessState: nil} // minimal stand-in
			}
			return res, nil
		}
	}
	f.t.Fatalf("unexpected exec call: %v", cmd)
	return RunResult{}, errors.New("unreachable")
}

func prefixMatch(cmd, want []string) bool {
	if len(cmd) < len(want) {
		return false
	}
	for i, w := range want {
		if cmd[i] != w {
			return false
		}
	}
	return true
}

func TestDiscoverNetwork(t *testing.T) {
	cases := []struct {
		name     string
		exit     int
		expected bool
	}{
		{"present", 0, true},
		{"absent", 1, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := &fakeExec{t: t, calls: []fakeCall{
				{match: []string{"docker", "network", "inspect", "forge"}, exit: tc.exit},
			}}
			got, err := DiscoverNetwork(context.Background(), f, "forge")
			if err != nil {
				t.Fatal(err)
			}
			if got != tc.expected {
				t.Errorf("got %v, want %v", got, tc.expected)
			}
		})
	}
}

func TestDiscoverForgeClusters(t *testing.T) {
	f := &fakeExec{t: t, calls: []fakeCall{
		{match: []string{"kind", "get", "clusters"}, out: "forge-mgmt\nforge-1\nother-cluster\n"},
	}}
	got, err := DiscoverForgeClusters(context.Background(), f)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"forge-mgmt", "forge-1"}
	if !strings.EqualFold(strings.Join(got, ","), strings.Join(want, ",")) {
		t.Errorf("got %v, want %v", got, want)
	}
}

func TestDiscoverMirrorContainers(t *testing.T) {
	f := &fakeExec{t: t, calls: []fakeCall{
		{match: []string{"docker", "ps"}, out: "forge-mirror-dockerio\nforge-mirror-ghcrio\n"},
	}}
	got, err := DiscoverMirrorContainers(context.Background(), f)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0] != "forge-mirror-dockerio" {
		t.Errorf("got %v", got)
	}
}

func TestDiscoverMirrorContainersFiltersNonPrefix(t *testing.T) {
	// Docker's name=<prefix> filter is substring, not strict prefix. The
	// discovery call must also filter client-side.
	f := &fakeExec{t: t, calls: []fakeCall{
		{match: []string{"docker", "ps"}, out: "some-other-container-with-forge-mirror-in-name\nforge-mirror-dockerio\n"},
	}}
	got, err := DiscoverMirrorContainers(context.Background(), f)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0] != "forge-mirror-dockerio" {
		t.Errorf("got %v", got)
	}
}

func TestDiscoverDNSContainer(t *testing.T) {
	cases := []struct {
		name string
		out  string
		exp  bool
	}{
		{"present", "forge-dns\n", true},
		{"absent", "", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := &fakeExec{t: t, calls: []fakeCall{
				{match: []string{"docker", "ps"}, out: tc.out},
			}}
			got, err := DiscoverDNSContainer(context.Background(), f)
			if err != nil {
				t.Fatal(err)
			}
			if got != tc.exp {
				t.Errorf("got %v, want %v", got, tc.exp)
			}
		})
	}
}
