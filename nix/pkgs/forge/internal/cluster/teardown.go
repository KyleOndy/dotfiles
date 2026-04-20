package cluster

import (
	"context"
	"fmt"

	"github.com/kyleondy/dotfiles/forge/internal/ui"
)

// TearDown removes clusters and optionally the surrounding infrastructure.
// Two modes:
//
//   - Down (nukeInfra=false): delete every declared + discovered Kind
//     cluster. Keeps the forge network, mirror containers + volumes, and
//     forge-dns — a subsequent `lab up` is fast because image caches and
//     mirror state are intact.
//
//   - Nuke (nukeInfra=true): additionally stop/remove mirror containers,
//     delete mirror volumes + on-disk configs, stop forge-dns, remove its
//     config, and delete the forge Docker network. Returns the host to a
//     clean slate.
//
// Both modes are idempotent: absent resources are skipped, not errors.
// Orphan clusters (forge-* prefix on the host but not in config) are also
// removed — the alternative is leaving them behind after a config edit.
func TearDown(ctx context.Context, exe Executor, cfg *Config, nukeInfra bool) error {
	declaredClusters := map[string]bool{}
	for _, c := range cfg.AllClusters() {
		declaredClusters[c.Name] = true
	}
	discoveredClusters, err := DiscoverForgeClusters(ctx, exe)
	if err != nil {
		return err
	}
	// Union: delete everything we know about, declared or orphaned.
	all := make(map[string]bool, len(declaredClusters)+len(discoveredClusters))
	for n := range declaredClusters {
		all[n] = true
	}
	for _, n := range discoveredClusters {
		all[n] = true
	}
	for name := range all {
		ui.L().Info("deleting cluster %s", name)
		if err := KindDeleteCluster(ctx, exe, name); err != nil {
			return fmt.Errorf("delete cluster %s: %w", name, err)
		}
	}

	if !nukeInfra {
		return nil
	}

	// Nuke path: teardown every piece of forge infrastructure.
	for _, m := range cfg.Mirrors {
		ui.L().Info("deleting mirror %s", m.ContainerName())
		if err := DeleteMirror(ctx, exe, m); err != nil {
			return err
		}
	}
	// Orphan mirror containers + volumes — forge-* on the host but not in
	// config. Handled by name without a full Mirror struct.
	orphanContainers, _ := DiscoverMirrorContainers(ctx, exe)
	declaredContainers := map[string]bool{}
	for _, m := range cfg.Mirrors {
		declaredContainers[m.ContainerName()] = true
	}
	for _, name := range orphanContainers {
		if declaredContainers[name] {
			continue
		}
		ui.L().Info("removing orphan mirror container %s", name)
		if err := StopMirror(ctx, exe, name); err != nil {
			return err
		}
	}
	orphanVolumes, _ := DiscoverMirrorVolumes(ctx, exe)
	declaredVolumes := map[string]bool{}
	for _, m := range cfg.Mirrors {
		declaredVolumes[m.VolumeName()] = true
	}
	for _, name := range orphanVolumes {
		if declaredVolumes[name] {
			continue
		}
		ui.L().Info("removing orphan mirror volume %s", name)
		if _, err := exe.Run(ctx, "docker", "volume", "rm", name); err != nil {
			// Volume might be in use by a container we already removed but
			// docker is slow to cleanup; ignore transient failures.
			ui.L().Warn("failed to remove orphan volume %s: %v", name, err)
		}
	}
	if err := DeleteDNS(ctx, exe); err != nil {
		return err
	}
	if err := DeleteNetwork(ctx, exe, cfg.Network.Name); err != nil {
		return err
	}
	ui.L().Info("nuke complete")
	return nil
}
