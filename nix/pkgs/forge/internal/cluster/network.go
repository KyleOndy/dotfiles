package cluster

import (
	"context"
	"fmt"
	"strings"

	"github.com/kyleondy/dotfiles/forge/internal/ui"
)

// EnsureNetwork creates the forge Docker bridge network if it does not
// already exist. Idempotent. The subnet argument may be empty when letting
// Docker pick a range automatically.
func EnsureNetwork(ctx context.Context, exe Executor, name, subnet string) error {
	exists, err := DiscoverNetwork(ctx, exe, name)
	if err != nil {
		return err
	}
	if exists {
		ui.L().Info("network %s already exists, skipping", name)
		return nil
	}
	args := []string{"network", "create", "--driver", "bridge"}
	if subnet != "" {
		args = append(args, "--subnet", subnet)
	}
	args = append(args, name)
	res, err := exe.Run(ctx, "docker", args...)
	if err != nil {
		return fmt.Errorf("docker network create %s: %w\n%s", name, err, res.Stderr)
	}
	ui.L().Info("created network %s", name)
	return nil
}

// DeleteNetwork removes the forge Docker bridge network if it exists.
// Idempotent.
func DeleteNetwork(ctx context.Context, exe Executor, name string) error {
	exists, err := DiscoverNetwork(ctx, exe, name)
	if err != nil {
		return err
	}
	if !exists {
		return nil
	}
	res, err := exe.Run(ctx, "docker", "network", "rm", name)
	if err != nil {
		return fmt.Errorf("docker network rm %s: %w\n%s", name, err, res.Stderr)
	}
	return nil
}

// ConnectNodeToNetwork connects a Kind node container to the forge network.
// Already-connected nodes are treated as success — Docker's error message
// contains "already exists" which we swallow.
func ConnectNodeToNetwork(ctx context.Context, exe Executor, networkName, nodeName string) error {
	res, err := exe.Run(ctx, "docker", "network", "connect", networkName, nodeName)
	if err != nil {
		if strings.Contains(strings.ToLower(res.Stderr), "already exists") {
			return nil
		}
		return fmt.Errorf("docker network connect %s %s: %w\n%s", networkName, nodeName, err, res.Stderr)
	}
	return nil
}

// KindClusterNodes returns the container names of a Kind cluster's nodes.
// Used by cluster-network attach.
func KindClusterNodes(ctx context.Context, exe Executor, clusterName string) ([]string, error) {
	res, err := exe.Run(ctx, "kind", "get", "nodes", "--name", clusterName)
	if err != nil {
		return nil, fmt.Errorf("kind get nodes %s: %w", clusterName, err)
	}
	return splitLines(res.Stdout), nil
}

// ConnectClusterToNetwork attaches every node of a cluster to the forge
// network. Idempotent.
func ConnectClusterToNetwork(ctx context.Context, exe Executor, networkName, clusterName string) error {
	nodes, err := KindClusterNodes(ctx, exe, clusterName)
	if err != nil {
		return err
	}
	for _, n := range nodes {
		if err := ConnectNodeToNetwork(ctx, exe, networkName, n); err != nil {
			return err
		}
	}
	ui.L().Info("connected %s nodes to %s", clusterName, networkName)
	return nil
}
