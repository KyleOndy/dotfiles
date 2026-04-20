package cluster

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestZotConfigJSONEnablesOnDemandSync(t *testing.T) {
	body, err := zotConfigJSON("https://registry-1.docker.io")
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	if err := json.Unmarshal([]byte(body), &got); err != nil {
		t.Fatal(err)
	}
	if got["distSpecVersion"] != "1.1.0" {
		t.Errorf("distSpecVersion = %v", got["distSpecVersion"])
	}
	ext, ok := got["extensions"].(map[string]any)
	if !ok {
		t.Fatalf("missing extensions: %v", got)
	}
	sync, ok := ext["sync"].(map[string]any)
	if !ok {
		t.Fatalf("missing extensions.sync: %v", ext)
	}
	if sync["enable"] != true {
		t.Errorf("sync.enable = %v", sync["enable"])
	}
	regs, ok := sync["registries"].([]any)
	if !ok || len(regs) == 0 {
		t.Fatalf("missing sync.registries: %v", sync)
	}
	first := regs[0].(map[string]any)
	urls := first["urls"].([]any)
	if urls[0] != "https://registry-1.docker.io" {
		t.Errorf("upstream URL not preserved: %v", urls)
	}
	if first["onDemand"] != true {
		t.Errorf("onDemand = %v", first["onDemand"])
	}
}

func TestWriteMirrorConfigMaterializesJSONAtExpectedPath(t *testing.T) {
	// Point UserCacheDir at a temp dir.
	dir := t.TempDir()
	t.Setenv("XDG_CACHE_HOME", dir)

	m := Mirror{Name: "dockerio", Upstream: "https://registry-1.docker.io"}
	path, err := writeMirrorConfig(m)
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(dir, "forge", "mirrors", "dockerio", "config.json")
	if path != want {
		t.Errorf("path = %q, want %q", path, want)
	}
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(body), "registry-1.docker.io") {
		t.Errorf("config missing upstream: %s", body)
	}
}

func TestRemoveMirrorConfigDir(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CACHE_HOME", dir)

	m := Mirror{Name: "dockerio", Upstream: "https://x"}
	if _, err := writeMirrorConfig(m); err != nil {
		t.Fatal(err)
	}
	if err := removeMirrorConfigDir(m); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, "forge", "mirrors", "dockerio")); !os.IsNotExist(err) {
		t.Errorf("expected dir removed, stat err = %v", err)
	}
}

func TestZotImageMatchesArch(t *testing.T) {
	img := zotImage()
	if !strings.HasPrefix(img, "ghcr.io/project-zot/zot-linux-") {
		t.Errorf("unexpected image: %s", img)
	}
}
