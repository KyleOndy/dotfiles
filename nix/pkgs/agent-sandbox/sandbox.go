package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

// bwrapBin returns the path to bwrap, preferring the Nix-wrapped path set
// at package build time so the store path is used rather than whatever is on PATH.
func bwrapBin() string {
	if p := os.Getenv("AGENT_SANDBOX_BWRAP"); p != "" {
		return p
	}
	return "bwrap"
}

func buildEnv(cfg *config, proxyAddr string) []string {
	keep := map[string]string{}

	// Always pass these through from parent if present.
	for _, name := range []string{"PATH", "HOME", "TERM", "LANG", "USER", "LOGNAME"} {
		if v, ok := os.LookupEnv(name); ok {
			keep[name] = v
		}
	}
	for _, e := range os.Environ() {
		k, _, _ := strings.Cut(e, "=")
		if strings.HasPrefix(k, "LC_") {
			if v, ok := os.LookupEnv(k); ok {
				keep[k] = v
			}
		}
	}

	// User-specified vars.
	for _, spec := range cfg.envSpecs {
		if spec.passThrough {
			if v, ok := os.LookupEnv(spec.name); ok {
				keep[spec.name] = v
			}
		} else {
			keep[spec.name] = spec.value
		}
	}

	// Proxy vars when running in --net=allow mode.
	// NO_PROXY excludes loopback so local services (e.g. Ollama) aren't
	// routed through the filtering proxy — the proxy blocks external HTTPS.
	if proxyAddr != "" {
		proxyURL := "http://" + proxyAddr
		keep["HTTP_PROXY"] = proxyURL
		keep["HTTPS_PROXY"] = proxyURL
		keep["http_proxy"] = proxyURL
		keep["https_proxy"] = proxyURL
		keep["NO_PROXY"] = "127.0.0.1,localhost,::1"
		keep["no_proxy"] = "127.0.0.1,localhost,::1"
	}

	env := make([]string, 0, len(keep))
	for k, v := range keep {
		env = append(env, k+"="+v)
	}
	// Sort for determinism (makes audit records stable).
	sort.Strings(env)
	return env
}

func runSandbox(cfg *config, proxy *allowlistProxy) (int, error) {
	var argv []string

	// ── Filesystem layout ──────────────────────────────────────────────
	// With user+mount namespace unsharing, mounts do not propagate from the
	// parent namespace — everything must be explicitly bound. We expose the
	// minimum needed to run Nix-managed programs on NixOS. /run/user is
	// replaced with an empty tmpfs to block the SSH agent socket and other
	// user runtime credentials.
	argv = append(argv,
		"--ro-bind", "/nix", "/nix", // Nix store + nix db (RO, immutable)
		"--ro-bind", "/etc", "/etc", // system config: hosts, nsswitch, resolv.conf
		"--proc", "/proc",
		"--dev", "/dev",
		"--tmpfs", "/tmp",
		"--tmpfs", "/run/user",
	)
	// NixOS-specific: system software path and setuid wrappers.
	for _, p := range []string{"/run/current-system", "/run/wrappers"} {
		if _, err := os.Stat(p); err == nil {
			argv = append(argv, "--ro-bind", p, p)
		}
	}
	// DNS resolution: only needed when the sandbox has network access.
	if !cfg.netOff {
		if _, err := os.Stat("/run/systemd/resolve"); err == nil {
			argv = append(argv, "--ro-bind", "/run/systemd/resolve", "/run/systemd/resolve")
		}
	}

	// Mask well-known credential directories under $HOME.
	home, _ := os.UserHomeDir()
	for _, sub := range []string{
		".ssh", ".gnupg", ".config/sops", ".aws", ".azure",
		".gcloud", ".kube", ".docker", ".netrc", ".git-credentials",
	} {
		p := filepath.Join(home, sub)
		if _, err := os.Stat(p); err == nil {
			argv = append(argv, "--tmpfs", p)
		}
	}

	// Bind current working directory read-write and chdir into it.
	cwd, err := os.Getwd()
	if err != nil {
		return 1, fmt.Errorf("getwd: %w", err)
	}
	argv = append(argv, "--bind", cwd, cwd, "--chdir", cwd)

	// User-specified bind mounts.
	for _, b := range cfg.binds {
		if b.ro {
			argv = append(argv, "--ro-bind", b.src, b.dst)
		} else {
			argv = append(argv, "--bind", b.src, b.dst)
		}
	}

	// ── Namespaces ─────────────────────────────────────────────────────
	// --unshare-user: creates a user namespace so all other unshares work
	// without requiring a setuid bwrap binary (kernel user-namespace
	// support must be enabled, which NixOS enables by default).
	uid := os.Getuid()
	gid := os.Getgid()
	argv = append(argv,
		"--unshare-user",
		"--uid", fmt.Sprintf("%d", uid),
		"--gid", fmt.Sprintf("%d", gid),
		"--unshare-pid",
		"--unshare-ipc",
		"--unshare-uts",
	)
	if cfg.netOff {
		// Hard isolation: child gets an empty network namespace.
		argv = append(argv, "--unshare-net")
	}
	// For --net=allow: no --unshare-net; the child shares the parent's
	// network namespace and is directed through the allowlist proxy via
	// HTTP_PROXY/HTTPS_PROXY. Phase 2 will upgrade this to slirp4netns.

	argv = append(argv, "--die-with-parent")

	// ── Command ────────────────────────────────────────────────────────
	argv = append(argv, "--")
	argv = append(argv, cfg.cmd...)

	var proxyAddr string
	if proxy != nil {
		proxyAddr = proxy.addr
	}
	env := buildEnv(cfg, proxyAddr)

	cmd := exec.Command(bwrapBin(), argv...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Env = env

	if err := cmd.Run(); err != nil {
		if exit, ok := err.(*exec.ExitError); ok {
			return exit.ExitCode(), nil
		}
		return 1, fmt.Errorf("bwrap: %w", err)
	}
	return 0, nil
}
