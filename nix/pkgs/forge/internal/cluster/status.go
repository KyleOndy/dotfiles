package cluster

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"

	"github.com/kyleondy/dotfiles/forge/internal/ui"
)

// StatusLevel classifies a status line for colored display.
type StatusLevel int

const (
	// StatusOK — resource exists and is reachable.
	StatusOK StatusLevel = iota
	// StatusAbsent — resource is expected by config but not found.
	StatusAbsent
	// StatusError — resource probe failed with an actual error (not just absent).
	StatusError
	// StatusInfo — informational line, no judgement.
	StatusInfo
	// StatusOrphan — resource found that isn't declared in config.
	StatusOrphan
)

// StatusLine is one row of the status report.
type StatusLine struct {
	Level    StatusLevel
	Category string
	Message  string
}

// Format renders one line with a color-coded level tag when the output
// stream supports color.
func (s StatusLine) Format() string {
	text := levelText(s.Level)
	color := levelColor(s.Level)
	padded := fmt.Sprintf("%-8s", text)
	if c := ui.Color(color); c != "" {
		padded = c + padded + ui.Color("reset")
	}
	return padded + " " + s.Category + ": " + s.Message
}

func levelText(l StatusLevel) string {
	switch l {
	case StatusOK:
		return "OK"
	case StatusAbsent:
		return "ABSENT"
	case StatusError:
		return "ERROR"
	case StatusInfo:
		return "INFO"
	case StatusOrphan:
		return "ORPHAN"
	}
	return "?"
}

func levelColor(l StatusLevel) string {
	switch l {
	case StatusOK:
		return "green"
	case StatusAbsent:
		return "yellow"
	case StatusError:
		return "red"
	case StatusInfo:
		return "blue"
	case StatusOrphan:
		return "yellow"
	}
	return ""
}

// Collect walks the config, probes each declared resource, and returns a
// report of what's present, absent, or orphaned.
//
// Checks performed:
//   - Docker network
//   - Each configured mirror container
//   - Each configured Kind cluster
//   - Each kubeconfig file on disk
//   - forge-dns container
//   - Orphans: forge-named resources present but not declared in config
func Collect(ctx context.Context, exe Executor, cfg *Config) []StatusLine {
	var lines []StatusLine

	disc, _ := Discover(ctx, exe, cfg.Network.Name)

	lines = append(lines, networkLine(cfg, disc))
	lines = append(lines, mirrorLines(cfg, disc)...)
	lines = append(lines, clusterLines(cfg, disc)...)
	lines = append(lines, kubeconfigLines(cfg)...)
	lines = append(lines, dnsLine(disc))
	lines = append(lines, orphanLines(cfg, disc)...)

	return lines
}

func networkLine(cfg *Config, d Discovered) StatusLine {
	if d.Network {
		return StatusLine{StatusOK, "Network", fmt.Sprintf("%s exists", cfg.Network.Name)}
	}
	return StatusLine{StatusAbsent, "Network", fmt.Sprintf("%s not found", cfg.Network.Name)}
}

func mirrorLines(cfg *Config, d Discovered) []StatusLine {
	present := toSet(d.MirrorContainers)
	out := make([]StatusLine, 0, len(cfg.Mirrors))
	for _, m := range cfg.Mirrors {
		name := m.ContainerName()
		if present[name] {
			out = append(out, StatusLine{StatusOK, "Mirror", fmt.Sprintf("%s running", name)})
		} else {
			out = append(out, StatusLine{StatusAbsent, "Mirror", fmt.Sprintf("%s not found", name)})
		}
	}
	return out
}

func clusterLines(cfg *Config, d Discovered) []StatusLine {
	present := toSet(d.Clusters)
	all := cfg.AllClusters()
	out := make([]StatusLine, 0, len(all))
	for _, c := range all {
		if present[c.Name] {
			out = append(out, StatusLine{StatusOK, "Cluster", fmt.Sprintf("%s exists", c.Name)})
		} else {
			out = append(out, StatusLine{StatusAbsent, "Cluster", fmt.Sprintf("%s not found", c.Name)})
		}
	}
	return out
}

func kubeconfigLines(cfg *Config) []StatusLine {
	dir := cfg.ExpandedKubeconfigDir()
	all := cfg.AllClusters()
	out := make([]StatusLine, 0, len(all))
	for _, c := range all {
		path := filepath.Join(dir, c.Name)
		if _, err := os.Stat(path); err == nil {
			out = append(out, StatusLine{StatusOK, "Kubeconfig", fmt.Sprintf("%s → %s", c.Name, path)})
		} else {
			out = append(out, StatusLine{StatusAbsent, "Kubeconfig", fmt.Sprintf("%s not found at %s", c.Name, path)})
		}
	}
	return out
}

func dnsLine(d Discovered) StatusLine {
	if d.DNSContainer {
		return StatusLine{StatusOK, "DNS", fmt.Sprintf("%s exists", DNSContainerName)}
	}
	return StatusLine{StatusAbsent, "DNS", fmt.Sprintf("%s not found", DNSContainerName)}
}

// orphanLines flags forge-named resources present on the host that are NOT
// declared in the current config. These indicate stale state from a previous
// config that should probably be cleaned up with `lab nuke` or reconciled.
func orphanLines(cfg *Config, d Discovered) []StatusLine {
	declaredClusters := map[string]bool{}
	for _, c := range cfg.AllClusters() {
		declaredClusters[c.Name] = true
	}
	declaredMirrors := map[string]bool{}
	for _, m := range cfg.Mirrors {
		declaredMirrors[m.ContainerName()] = true
		declaredMirrors[m.VolumeName()] = true
	}

	var out []StatusLine
	var orphanClusters, orphanContainers, orphanVolumes []string
	for _, c := range d.Clusters {
		if !declaredClusters[c] {
			orphanClusters = append(orphanClusters, c)
		}
	}
	for _, c := range d.MirrorContainers {
		if !declaredMirrors[c] {
			orphanContainers = append(orphanContainers, c)
		}
	}
	for _, v := range d.MirrorVolumes {
		if !declaredMirrors[v] {
			orphanVolumes = append(orphanVolumes, v)
		}
	}
	sort.Strings(orphanClusters)
	sort.Strings(orphanContainers)
	sort.Strings(orphanVolumes)
	for _, c := range orphanClusters {
		out = append(out, StatusLine{StatusOrphan, "Cluster", fmt.Sprintf("%s not declared in config", c)})
	}
	for _, c := range orphanContainers {
		out = append(out, StatusLine{StatusOrphan, "Mirror", fmt.Sprintf("%s not declared in config", c)})
	}
	for _, v := range orphanVolumes {
		out = append(out, StatusLine{StatusOrphan, "Volume", fmt.Sprintf("%s not declared in config", v)})
	}
	return out
}

func toSet(xs []string) map[string]bool {
	m := make(map[string]bool, len(xs))
	for _, x := range xs {
		m[x] = true
	}
	return m
}
