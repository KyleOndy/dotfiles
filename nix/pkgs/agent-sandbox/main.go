package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

func main() {
	cfg, err := parseArgs(os.Args[1:])
	if err != nil {
		fmt.Fprintf(os.Stderr, "agent-sandbox: %v\n\n%s", err, usageText)
		os.Exit(2)
	}
	code, err := run(cfg)
	if err != nil {
		fmt.Fprintf(os.Stderr, "agent-sandbox: %v\n", err)
		if code == 0 {
			code = 1
		}
	}
	os.Exit(code)
}

const usageText = `usage: agent-sandbox [flags] -- <command> [args...]

Flags:
  --consumer=NAME        audit label (default: command basename)
  --net=off              full network unshare, no egress (default)
  --net=allow:HOST:PORT  proxy-based allowlist; repeatable; shares parent
                         network namespace — programs ignoring HTTP_PROXY
                         can bypass; hard isolation (slirp4netns) in phase 2
  --bind=PATH            bind PATH read-write into sandbox (repeatable)
  --bind-ro=PATH         bind PATH read-only into sandbox (repeatable)
  --env=NAME             pass env var through from parent (repeatable)
  --env=NAME=VALUE       set env var to VALUE (repeatable)
`

type bindMount struct {
	src string
	dst string
	ro  bool
}

type envEntry struct {
	name        string
	value       string
	passThrough bool
}

type config struct {
	consumer  string
	netOff    bool
	allowList []string // "host:port" when !netOff
	binds     []bindMount
	envSpecs  []envEntry
	cmd       []string
}

func parseArgs(args []string) (*config, error) {
	cfg := &config{netOff: true}

	i := 0
	for i < len(args) {
		arg := args[i]
		if arg == "--" {
			i++
			break
		}
		if !strings.HasPrefix(arg, "--") {
			break
		}
		key, val, hasVal := strings.Cut(arg[2:], "=")
		switch key {
		case "consumer":
			if !hasVal {
				return nil, fmt.Errorf("--consumer requires a value")
			}
			cfg.consumer = val

		case "net":
			if !hasVal {
				return nil, fmt.Errorf("--net requires a value (off or allow:host:port)")
			}
			if val == "off" {
				cfg.netOff = true
				cfg.allowList = nil
			} else if strings.HasPrefix(val, "allow:") {
				target := val[len("allow:"):]
				if !strings.Contains(target, ":") {
					return nil, fmt.Errorf("--net=allow: expected host:port, got %q", target)
				}
				cfg.netOff = false
				cfg.allowList = append(cfg.allowList, target)
			} else {
				return nil, fmt.Errorf("--net: expected 'off' or 'allow:host:port', got %q", val)
			}

		case "bind":
			if !hasVal {
				return nil, fmt.Errorf("--bind requires a path")
			}
			cfg.binds = append(cfg.binds, bindMount{src: val, dst: val})

		case "bind-ro":
			if !hasVal {
				return nil, fmt.Errorf("--bind-ro requires a path")
			}
			cfg.binds = append(cfg.binds, bindMount{src: val, dst: val, ro: true})

		case "env":
			if !hasVal {
				return nil, fmt.Errorf("--env requires a value")
			}
			if name, value, ok := strings.Cut(val, "="); ok {
				cfg.envSpecs = append(cfg.envSpecs, envEntry{name: name, value: value})
			} else {
				cfg.envSpecs = append(cfg.envSpecs, envEntry{name: val, passThrough: true})
			}

		default:
			return nil, fmt.Errorf("unknown flag --%s", key)
		}
		i++
	}

	cfg.cmd = args[i:]
	if len(cfg.cmd) == 0 {
		return nil, errors.New("no command specified after --")
	}
	if cfg.consumer == "" {
		cfg.consumer = filepath.Base(cfg.cmd[0])
	}
	return cfg, nil
}

func run(cfg *config) (int, error) {
	rec := newAuditRecord(cfg)

	var proxy *allowlistProxy
	if !cfg.netOff && len(cfg.allowList) > 0 {
		proxy = newProxy(cfg.allowList)
		if err := proxy.start(); err != nil {
			return 1, fmt.Errorf("starting proxy: %w", err)
		}
		defer proxy.stop()
	}

	code, err := runSandbox(cfg, proxy)

	if proxy != nil {
		up, down := proxy.byteCounts()
		rec.BytesUp = up
		rec.BytesDown = down
	}
	rec.ExitCode = code
	rec.finish()
	emitAudit(rec)

	return code, err
}
