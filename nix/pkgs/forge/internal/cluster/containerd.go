package cluster

import (
	"context"
	"fmt"
	"os/exec"
	"strings"

	"github.com/kyleondy/dotfiles/forge/internal/ui"
)

// hostsToml renders the containerd hosts.toml body that points containerd
// at a forge mirror container for a given upstream registry. Each Kind
// node gets one hosts.toml per mirror at:
//
//	/etc/containerd/certs.d/<registry>/hosts.toml
//
// See https://github.com/containerd/containerd/blob/main/docs/hosts.md
func hostsToml(upstream, mirrorContainer string) string {
	return fmt.Sprintf(`server = "%s"

[host."http://%s:%d"]
  capabilities = ["pull", "resolve", "push"]
`, upstream, mirrorContainer, zotPort)
}

// ConfigureNodeMirrors writes a hosts.toml for every mirror into every
// node of a Kind cluster. Idempotent — `tee` overwrites identical content
// harmlessly, and containerd re-reads these files on each pull.
func ConfigureNodeMirrors(ctx context.Context, exe Executor, clusterName string, mirrors []Mirror) error {
	if len(mirrors) == 0 {
		return nil
	}
	nodes, err := KindClusterNodes(ctx, exe, clusterName)
	if err != nil {
		return err
	}
	for _, node := range nodes {
		for _, m := range mirrors {
			registryDir := fmt.Sprintf("/etc/containerd/certs.d/%s", m.Registry)
			if _, err := exe.Run(ctx, "docker", "exec", node, "mkdir", "-p", registryDir); err != nil {
				return fmt.Errorf("mkdir %s on %s: %w", registryDir, node, err)
			}
			body := hostsToml(m.Upstream, m.ContainerName())
			dest := registryDir + "/hosts.toml"
			if err := stdinRunner(ctx, body, "docker", "exec", "-i", node, "tee", dest); err != nil {
				return fmt.Errorf("write %s on %s: %w", dest, node, err)
			}
		}
	}
	ui.L().Info("configured %d mirror(s) on %s", len(mirrors), clusterName)
	return nil
}

// stdinRunner shells out with a stdin string. A package var so tests can
// stub it without widening the Executor interface (which is Run-only so
// fakes stay simple). Used only by the containerd hosts.toml writer.
var stdinRunner = defaultStdinRunner

func defaultStdinRunner(ctx context.Context, stdin string, name string, args ...string) error {
	c := exec.CommandContext(ctx, name, args...)
	c.Stdin = strings.NewReader(stdin)
	out, err := c.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s %s: %w\n%s", name, strings.Join(args, " "), err, out)
	}
	return nil
}
