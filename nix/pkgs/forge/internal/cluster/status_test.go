package cluster

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCollectAllAbsent(t *testing.T) {
	// Isolate $HOME so the test doesn't see any real ~/.kube/configs/*
	// files that might exist on the dev host from previous runs.
	t.Setenv("HOME", t.TempDir())
	cfg, err := Load(writeConfig(t, validConfig))
	if err != nil {
		t.Fatal(err)
	}
	f := &fakeExec{t: t, calls: []fakeCall{
		{match: []string{"docker", "network", "inspect"}, exit: 1},
		{match: []string{"docker", "ps"}, out: ""},
		{match: []string{"kind", "get", "clusters"}, out: ""},
		{match: []string{"docker", "volume"}, out: ""},
	}}
	lines := Collect(context.Background(), f, cfg)
	// Expect: 1 network + 2 mirrors + 2 clusters (mgmt + forge-1) + 2 kubeconfigs + 1 dns = 8
	if len(lines) != 8 {
		t.Fatalf("got %d lines, want 8\n%v", len(lines), linesToStrings(lines))
	}
	for _, l := range lines {
		if l.Level != StatusAbsent {
			t.Errorf("want all absent, got %+v", l)
		}
	}
}

func TestCollectAllPresent(t *testing.T) {
	cfg, err := Load(writeConfig(t, validConfig))
	if err != nil {
		t.Fatal(err)
	}

	// Materialize kubeconfig files on disk so the kubeconfig check passes.
	home := t.TempDir()
	t.Setenv("HOME", home)
	kcDir := filepath.Join(home, ".kube", "configs")
	if err := os.MkdirAll(kcDir, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"forge-mgmt", "forge-1"} {
		if err := os.WriteFile(filepath.Join(kcDir, name), []byte("---"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	f := &fakeExec{t: t, calls: []fakeCall{
		{match: []string{"docker", "network", "inspect"}, exit: 0},
		{match: []string{"docker", "ps", "-a", "--filter", "name=forge-mirror-"}, out: "forge-mirror-dockerio\nforge-mirror-ecr\n"},
		{match: []string{"docker", "ps", "-a", "--filter", "name=forge-dns"}, out: "forge-dns\n"},
		{match: []string{"kind", "get", "clusters"}, out: "forge-mgmt\nforge-1\n"},
		{match: []string{"docker", "volume"}, out: "forge-mirror-dockerio-data\nforge-mirror-ecr-data\n"},
	}}
	lines := Collect(context.Background(), f, cfg)
	for _, l := range lines {
		if l.Level != StatusOK {
			t.Errorf("want all OK, got %+v", l)
		}
	}
}

func TestCollectOrphans(t *testing.T) {
	cfg, err := Load(writeConfig(t, validConfig))
	if err != nil {
		t.Fatal(err)
	}

	f := &fakeExec{t: t, calls: []fakeCall{
		{match: []string{"docker", "network", "inspect"}, exit: 1},
		{match: []string{"docker", "ps", "-a", "--filter", "name=forge-mirror-"}, out: "forge-mirror-dockerio\nforge-mirror-leftover\n"},
		{match: []string{"docker", "ps", "-a", "--filter", "name=forge-dns"}, out: ""},
		{match: []string{"kind", "get", "clusters"}, out: "forge-mgmt\nforge-1\nforge-ghost\n"},
		{match: []string{"docker", "volume"}, out: "forge-mirror-dockerio-data\nforge-mirror-leftover-data\n"},
	}}
	lines := Collect(context.Background(), f, cfg)

	orphans := 0
	for _, l := range lines {
		if l.Level == StatusOrphan {
			orphans++
		}
	}
	// 1 orphan cluster + 1 orphan mirror container + 1 orphan mirror volume
	if orphans != 3 {
		t.Fatalf("got %d orphans, want 3\n%v", orphans, linesToStrings(lines))
	}
}

func TestFormatLinePlain(t *testing.T) {
	t.Setenv("NO_COLOR", "1")
	l := StatusLine{Level: StatusOK, Category: "Network", Message: "forge exists"}
	got := l.Format()
	if !strings.Contains(got, "OK") || !strings.Contains(got, "Network") || !strings.Contains(got, "forge exists") {
		t.Errorf("unexpected format: %q", got)
	}
}

func linesToStrings(ls []StatusLine) []string {
	out := make([]string, len(ls))
	for i, l := range ls {
		out[i] = l.Format()
	}
	return out
}
