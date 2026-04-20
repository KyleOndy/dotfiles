package cluster

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/kyleondy/dotfiles/forge/internal/manifest"
	"github.com/kyleondy/dotfiles/forge/internal/ui"
)

// forgeTestDomain is the fake TLD forge synthesizes for ingress hostnames
// so local services are addressable as <cluster>.forge.test.
const forgeTestDomain = "forge.test"

// GenerateDnsmasqConfig builds the dnsmasq.conf that backs the forge-dns
// container. Every cluster with an ingress IP gets an A record at
// <cluster>.forge.test, and a catch-all forge.test → management IP lets
// reverse proxies and ingress rules work against the top-level domain.
func GenerateDnsmasqConfig(cfg *Config) (string, error) {
	mgmtIP, err := cfg.Management.IngressIP()
	if err != nil {
		return "", fmt.Errorf("management ingress IP: %w", err)
	}
	var b strings.Builder
	b.WriteString("# forge-dns: in-cluster DNS for *.forge.test\n")
	b.WriteString("no-resolv\n")
	b.WriteString("domain-needed\n\n")
	for _, c := range cfg.AllClusters() {
		ip, err := c.Cluster.IngressIP()
		if err != nil {
			// Clusters without a pool are skipped silently — they have no
			// ingress to point at.
			continue
		}
		fmt.Fprintf(&b, "address=/%s.%s/%s\n", c.Cluster.Name, forgeTestDomain, ip)
	}
	fmt.Fprintf(&b, "address=/%s/%s\n\n", forgeTestDomain, mgmtIP)
	return b.String(), nil
}

// dnsConfigDir returns the on-disk directory where dnsmasq.conf is
// materialized. User-scoped, same rationale as mirror configs — avoid
// cwd-relative state.
func dnsConfigDir() (string, error) {
	cache, err := os.UserCacheDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(cache, "forge", "dns"), nil
}

// writeDnsmasqConfig materializes dnsmasq.conf to disk and returns its
// absolute path.
func writeDnsmasqConfig(cfg *Config) (string, error) {
	dir, err := dnsConfigDir()
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("mkdir %s: %w", dir, err)
	}
	body, err := GenerateDnsmasqConfig(cfg)
	if err != nil {
		return "", err
	}
	path := filepath.Join(dir, "dnsmasq.conf")
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		return "", err
	}
	return path, nil
}

// removeDNSConfigDir deletes the on-disk dnsmasq config dir. Used by
// `lab nuke`. No-op when absent.
func removeDNSConfigDir() error {
	dir, err := dnsConfigDir()
	if err != nil {
		return err
	}
	return os.RemoveAll(dir)
}

// EnsureDNSImage builds the forge-dns image if it's not already on the host.
// Dockerfile is embedded; we write it to a fresh temp dir and run
// `docker build` against that dir as context.
func EnsureDNSImage(ctx context.Context, exe Executor) error {
	if _, err := exe.Run(ctx, "docker", "image", "inspect", DNSImageName); err == nil {
		return nil
	}
	tmp, err := os.MkdirTemp("", "forge-dns-build-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)
	dfPath := filepath.Join(tmp, "Dockerfile")
	if err := os.WriteFile(dfPath, manifest.DnsmasqDockerfile, 0o644); err != nil {
		return err
	}
	res, err := exe.Run(ctx, "docker", "build", "-t", DNSImageName, tmp)
	if err != nil {
		return fmt.Errorf("docker build %s: %w\n%s", DNSImageName, err, res.Stderr)
	}
	ui.L().Info("built %s", DNSImageName)
	return nil
}

// EnsureDNS brings the forge-dns dnsmasq container to a running state,
// bound to the DNS static IP on the forge network. Idempotent:
//   - running: skip
//   - stopped or unhealthy: remove and recreate (picks up config changes)
//   - absent: build image, write config, create
func EnsureDNS(ctx context.Context, exe Executor, cfg *Config) error {
	if err := EnsureDNSImage(ctx, exe); err != nil {
		return err
	}
	state, err := containerState(ctx, exe, DNSContainerName)
	if err != nil {
		return err
	}
	if state == "running" {
		ui.L().Info("%s already running, skipping", DNSContainerName)
		return nil
	}
	if state != "" {
		// Stopped / exited / something else — wipe so we can recreate with
		// the current config (config might have changed since last run).
		if _, err := exe.Run(ctx, "docker", "rm", "-f", DNSContainerName); err != nil {
			return fmt.Errorf("remove stale %s: %w", DNSContainerName, err)
		}
	}
	configPath, err := writeDnsmasqConfig(cfg)
	if err != nil {
		return err
	}
	args := []string{
		"run", "-d",
		"--name", DNSContainerName,
		"--network", cfg.Network.Name,
		"--ip", cfg.DNS.IP,
		"-v", configPath + ":/etc/dnsmasq.conf:ro",
		"--restart", "unless-stopped",
		DNSImageName,
	}
	if res, err := exe.Run(ctx, "docker", args...); err != nil {
		return fmt.Errorf("docker run %s: %w\n%s", DNSContainerName, err, res.Stderr)
	}
	ui.L().Info("created %s at %s", DNSContainerName, cfg.DNS.IP)
	return waitDNSReady(ctx, exe)
}

// waitDNSReady polls the dnsmasq container until it answers an nslookup for
// forge.test. 30s budget with 1s sleeps.
func waitDNSReady(ctx context.Context, exe Executor) error {
	deadline := time.Now().Add(30 * time.Second)
	for {
		_, err := exe.Run(ctx, "docker", "exec", DNSContainerName,
			"nslookup", "-type=a", forgeTestDomain, "127.0.0.1")
		if err == nil {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("%s not ready after 30s", DNSContainerName)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(1 * time.Second):
		}
	}
}

// StopDNS removes the forge-dns container but keeps the config on disk.
// Used by `lab down`. Idempotent.
func StopDNS(ctx context.Context, exe Executor) error {
	state, err := containerState(ctx, exe, DNSContainerName)
	if err != nil {
		return err
	}
	if state == "" {
		return nil
	}
	if _, err := exe.Run(ctx, "docker", "rm", "-f", DNSContainerName); err != nil {
		return fmt.Errorf("rm %s: %w", DNSContainerName, err)
	}
	return nil
}

// DeleteDNS removes the forge-dns container and its config dir. Used by
// `lab nuke`.
func DeleteDNS(ctx context.Context, exe Executor) error {
	if err := StopDNS(ctx, exe); err != nil {
		return err
	}
	return removeDNSConfigDir()
}
