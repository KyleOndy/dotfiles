package cluster

import (
	"context"
	"fmt"
	"os"
	"strings"
)

// kindConfigTemplate is the Kind cluster config written to a temp file for
// `kind create cluster --config`. The containerdConfigPatches entry points
// containerd at /etc/containerd/certs.d so later steps (mirrors) can drop
// hosts.toml files into each node. Present even in minimal mode because it
// costs nothing when no mirrors are configured.
const kindConfigTemplate = `kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry]
      config_path = "/etc/containerd/certs.d"
nodes:
%s
`

// RenderKindConfig returns a Kind cluster config YAML string for the given
// cluster entry. The cluster name is passed to Kind via `--name` instead of
// the config's `name:` field, so this function ignores c.Name.
func RenderKindConfig(c Cluster) string {
	var nodes strings.Builder
	for _, n := range c.Nodes {
		fmt.Fprintf(&nodes, "  - role: %s\n", n.Role)
	}
	return fmt.Sprintf(kindConfigTemplate, strings.TrimRight(nodes.String(), "\n"))
}

// KindClusterExists returns true when `kind get clusters` lists name.
func KindClusterExists(ctx context.Context, exe Executor, name string) (bool, error) {
	res, err := exe.Run(ctx, "kind", "get", "clusters")
	if err != nil {
		return false, fmt.Errorf("kind get clusters: %w", err)
	}
	for _, line := range splitLines(res.Stdout) {
		if line == name {
			return true, nil
		}
	}
	return false, nil
}

// KindCreateCluster creates a Kind cluster using the given rendered config.
// The kubeconfig is written to kubeconfigPath instead of merging into the
// user's default kubeconfig.
//
// Writes a temp file for the config and cleans it up on exit. Caller is
// responsible for idempotency (check KindClusterExists first).
func KindCreateCluster(ctx context.Context, exe Executor, name, kindConfig, kubeconfigPath string) error {
	tmp, err := os.CreateTemp("", "forge-kind-config-*.yaml")
	if err != nil {
		return fmt.Errorf("temp file: %w", err)
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.WriteString(kindConfig); err != nil {
		tmp.Close()
		return fmt.Errorf("write temp config: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("close temp config: %w", err)
	}
	res, err := exe.Run(ctx, "kind", "create", "cluster",
		"--name", name,
		"--config", tmp.Name(),
		"--kubeconfig", kubeconfigPath,
	)
	if err != nil {
		return fmt.Errorf("kind create cluster %s: %w\n%s", name, err, res.Stderr)
	}
	return nil
}

// KindDeleteCluster deletes a Kind cluster by name. Idempotent: deleting a
// non-existent cluster is not an error.
func KindDeleteCluster(ctx context.Context, exe Executor, name string) error {
	exists, err := KindClusterExists(ctx, exe, name)
	if err != nil {
		return err
	}
	if !exists {
		return nil
	}
	res, err := exe.Run(ctx, "kind", "delete", "cluster", "--name", name)
	if err != nil {
		return fmt.Errorf("kind delete cluster %s: %w\n%s", name, err, res.Stderr)
	}
	return nil
}
