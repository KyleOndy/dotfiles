package cluster

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/kyleondy/dotfiles/forge/internal/ui"
)

// zotPort is the HTTP port Zot listens on inside the mirror container.
// Mapped to a configurable host port per mirror.
const zotPort = 5000

// zotImageAMD64 / zotImageARM64 are the multi-arch Zot images used for all
// pull-through registry mirrors. Pinning a digest would be safer, but
// `:latest` matches Crucible's current behavior; revisit when we do a
// hardening pass.
const (
	zotImageAMD64 = "ghcr.io/project-zot/zot-linux-amd64:latest"
	zotImageARM64 = "ghcr.io/project-zot/zot-linux-arm64:latest"
)

// zotImage returns the Zot image matching the current host's architecture.
func zotImage() string {
	if runtime.GOARCH == "arm64" {
		return zotImageARM64
	}
	return zotImageAMD64
}

// zotConfigJSON returns the Zot config body for a mirror. On-demand sync
// from upstream turns Zot into a pull-through cache.
func zotConfigJSON(upstream string) (string, error) {
	cfg := map[string]any{
		"distSpecVersion": "1.1.0",
		"storage": map[string]any{
			"rootDirectory": "/var/lib/zot",
		},
		"http": map[string]any{
			"address": "0.0.0.0",
			"port":    fmt.Sprintf("%d", zotPort),
			"compat":  []string{"docker2s2"},
		},
		"extensions": map[string]any{
			"sync": map[string]any{
				"enable": true,
				"registries": []map[string]any{
					{
						"urls":      []string{upstream},
						"onDemand":  true,
						"tlsVerify": true,
						"content": []map[string]any{
							{"prefix": "**"},
						},
					},
				},
			},
		},
	}
	b, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// mirrorConfigDir returns the on-disk directory holding <name>/config.json
// for Zot mirrors. Kept in $XDG_CACHE_HOME/forge/mirrors (defaulting to
// ~/.cache/forge/mirrors) so the config files don't depend on cwd and
// don't clutter user repos.
func mirrorConfigDir() (string, error) {
	cache, err := os.UserCacheDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(cache, "forge", "mirrors"), nil
}

// writeMirrorConfig materializes the Zot config JSON to disk and returns its
// absolute path. The file is bind-mounted read-only into the container.
func writeMirrorConfig(m Mirror) (string, error) {
	root, err := mirrorConfigDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(root, m.Name)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("mkdir %s: %w", dir, err)
	}
	body, err := zotConfigJSON(m.Upstream)
	if err != nil {
		return "", err
	}
	path := filepath.Join(dir, "config.json")
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		return "", fmt.Errorf("write %s: %w", path, err)
	}
	return path, nil
}

// removeMirrorConfigDir deletes the on-disk config dir for a mirror. Used
// by `lab nuke`. No-op when the dir is absent.
func removeMirrorConfigDir(m Mirror) error {
	root, err := mirrorConfigDir()
	if err != nil {
		return err
	}
	dir := filepath.Join(root, m.Name)
	if err := os.RemoveAll(dir); err != nil {
		return fmt.Errorf("rm -rf %s: %w", dir, err)
	}
	return nil
}

// containerExists reports whether a Docker container with this name is
// present (running or stopped).
func containerExists(ctx context.Context, exe Executor, name string) (bool, error) {
	_, err := exe.Run(ctx, "docker", "inspect", name)
	if err != nil {
		return false, nil
	}
	return true, nil
}

// containerState returns the Docker `State.Status` string for a container,
// or "" when the container is absent or inspect fails.
func containerState(ctx context.Context, exe Executor, name string) (string, error) {
	res, err := exe.Run(ctx, "docker", "inspect", "--format", "{{.State.Status}}", name)
	if err != nil {
		return "", nil
	}
	return strings.TrimSpace(res.Stdout), nil
}

// EnsureMirror brings one mirror to the running state. Idempotent:
//   - running: skip
//   - stopped: start
//   - absent: materialize config + volume + container, then wait ready
func EnsureMirror(ctx context.Context, exe Executor, m Mirror, networkName string) error {
	cname := m.ContainerName()
	vname := m.VolumeName()

	exists, err := containerExists(ctx, exe, cname)
	if err != nil {
		return err
	}
	if exists {
		state, err := containerState(ctx, exe, cname)
		if err != nil {
			return err
		}
		if state == "running" {
			ui.L().Info("mirror %s already running, skipping", cname)
			return nil
		}
		if _, err := exe.Run(ctx, "docker", "start", cname); err != nil {
			return fmt.Errorf("docker start %s: %w", cname, err)
		}
		ui.L().Info("started mirror %s", cname)
		return waitMirrorReady(ctx, m.HostPort, cname)
	}

	// Absent — materialize from scratch.
	configPath, err := writeMirrorConfig(m)
	if err != nil {
		return err
	}
	if _, err := exe.Run(ctx, "docker", "volume", "create", vname); err != nil {
		return fmt.Errorf("docker volume create %s: %w", vname, err)
	}
	args := []string{
		"run", "-d",
		"--name", cname,
		"--network", networkName,
		"--restart", "unless-stopped",
		"-v", vname + ":/var/lib/zot",
		"-v", configPath + ":/etc/zot/config.json:ro",
		"-p", fmt.Sprintf("%d:%d", m.HostPort, zotPort),
		zotImage(),
	}
	res, err := exe.Run(ctx, "docker", args...)
	if err != nil {
		return fmt.Errorf("docker run %s: %w\n%s", cname, err, res.Stderr)
	}
	ui.L().Info("created mirror %s → %s", cname, m.Upstream)
	return waitMirrorReady(ctx, m.HostPort, cname)
}

// waitMirrorReady polls the mirror's /v2/ endpoint until it returns 200 or
// the retry budget is exhausted. Uses net/http directly so we don't depend
// on curl being on PATH.
func waitMirrorReady(ctx context.Context, hostPort int, cname string) error {
	url := fmt.Sprintf("http://localhost:%d/v2/", hostPort)
	client := &http.Client{Timeout: 2 * time.Second}
	deadline := time.Now().Add(30 * time.Second)
	for {
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		resp, err := client.Do(req)
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode < 500 {
				return nil
			}
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("mirror %s not ready at %s after 30s", cname, url)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(1 * time.Second):
		}
	}
}

// StopMirror removes a mirror container but keeps its data volume. Used by
// `lab down`. Idempotent.
func StopMirror(ctx context.Context, exe Executor, containerName string) error {
	exists, err := containerExists(ctx, exe, containerName)
	if err != nil {
		return err
	}
	if !exists {
		return nil
	}
	if _, err := exe.Run(ctx, "docker", "rm", "-f", containerName); err != nil {
		return fmt.Errorf("docker rm -f %s: %w", containerName, err)
	}
	return nil
}

// DeleteMirror removes a mirror container, its data volume, and its on-disk
// config. Used by `lab nuke`. Idempotent in all three legs.
func DeleteMirror(ctx context.Context, exe Executor, m Mirror) error {
	cname := m.ContainerName()
	vname := m.VolumeName()
	if err := StopMirror(ctx, exe, cname); err != nil {
		return err
	}
	if res, err := exe.Run(ctx, "docker", "volume", "rm", vname); err != nil {
		// No such volume is fine — lets nuke be a no-op on already-clean state.
		if !strings.Contains(res.Stderr, "No such volume") {
			return fmt.Errorf("docker volume rm %s: %w\n%s", vname, err, res.Stderr)
		}
	}
	return removeMirrorConfigDir(m)
}
