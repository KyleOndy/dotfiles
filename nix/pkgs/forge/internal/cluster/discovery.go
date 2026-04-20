package cluster

import (
	"context"
	"strings"
)

// DiscoverNetwork reports whether the named Docker network exists.
func DiscoverNetwork(ctx context.Context, exe Executor, name string) (bool, error) {
	_, err := exe.Run(ctx, "docker", "network", "inspect", name)
	if err != nil {
		return false, nil // non-zero exit = absent; don't propagate as error
	}
	return true, nil
}

// DiscoverForgeClusters returns the names of Kind clusters whose names start
// with the forge- prefix. A `kind get clusters` failure is treated as "no
// clusters" rather than an error — the caller only cares about what's
// present.
func DiscoverForgeClusters(ctx context.Context, exe Executor) ([]string, error) {
	res, err := exe.Run(ctx, "kind", "get", "clusters")
	if err != nil {
		return nil, nil
	}
	var out []string
	for _, line := range splitLines(res.Stdout) {
		if strings.HasPrefix(line, ClusterPrefix) {
			out = append(out, line)
		}
	}
	return out, nil
}

// DiscoverMirrorContainers returns the names of forge-mirror-* Docker
// containers (running or stopped).
func DiscoverMirrorContainers(ctx context.Context, exe Executor) ([]string, error) {
	return dockerListNames(ctx, exe, "container", MirrorContainerPrefix)
}

// DiscoverMirrorVolumes returns the names of forge-mirror-* Docker volumes.
func DiscoverMirrorVolumes(ctx context.Context, exe Executor) ([]string, error) {
	return dockerListNames(ctx, exe, "volume", MirrorContainerPrefix)
}

// DiscoverDNSContainer reports whether the forge-dns container exists.
func DiscoverDNSContainer(ctx context.Context, exe Executor) (bool, error) {
	names, err := dockerListNames(ctx, exe, "container", DNSContainerName)
	if err != nil {
		return false, err
	}
	for _, n := range names {
		if n == DNSContainerName {
			return true, nil
		}
	}
	return false, nil
}

// dockerListNames returns Docker resource names matching the given prefix
// filter. resource is "container" or "volume".
func dockerListNames(ctx context.Context, exe Executor, resource, prefix string) ([]string, error) {
	var args []string
	switch resource {
	case "container":
		args = []string{"ps", "-a", "--filter", "name=" + prefix, "--format", "{{.Names}}"}
	case "volume":
		args = []string{"volume", "ls", "--filter", "name=" + prefix, "--format", "{{.Name}}"}
	default:
		return nil, nil
	}
	res, err := exe.Run(ctx, "docker", args...)
	if err != nil {
		return nil, nil
	}
	var out []string
	for _, line := range splitLines(res.Stdout) {
		// Docker's name filter is a substring match, not strict prefix — so
		// we double-check here to avoid picking up non-forge names that
		// happen to contain our prefix.
		if strings.HasPrefix(line, prefix) {
			out = append(out, line)
		}
	}
	return out, nil
}

// Discovered is a snapshot of every forge-owned resource currently present
// in the Docker / Kind state.
type Discovered struct {
	Network          bool
	DNSContainer     bool
	Clusters         []string
	MirrorContainers []string
	MirrorVolumes    []string
}

// Discover aggregates all discovery calls into a single snapshot.
func Discover(ctx context.Context, exe Executor, networkName string) (Discovered, error) {
	var d Discovered
	var err error
	if d.Network, err = DiscoverNetwork(ctx, exe, networkName); err != nil {
		return d, err
	}
	if d.DNSContainer, err = DiscoverDNSContainer(ctx, exe); err != nil {
		return d, err
	}
	if d.Clusters, err = DiscoverForgeClusters(ctx, exe); err != nil {
		return d, err
	}
	if d.MirrorContainers, err = DiscoverMirrorContainers(ctx, exe); err != nil {
		return d, err
	}
	if d.MirrorVolumes, err = DiscoverMirrorVolumes(ctx, exe); err != nil {
		return d, err
	}
	return d, nil
}
