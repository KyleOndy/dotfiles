# agent-sandbox

Framework-agnostic runtime isolation for agent processes. Wraps any command in a bwrap namespace with scrubbed environment, masked credentials, and configurable network control.

## Usage

```
agent-sandbox [flags] -- <command> [args...]
```

## Flags

- `--consumer=NAME` — audit label (default: command basename)
- `--net=off` — full network unshare, no egress (default)
- `--net=allow:HOST:PORT` — soft allowlist via HTTP CONNECT proxy (repeatable)
- `--bind=PATH` — bind PATH read-write into sandbox (repeatable)
- `--bind-ro=PATH` — bind PATH read-only (repeatable)
- `--env=NAME` — pass env var through from parent (repeatable)
- `--env=NAME=VALUE` — set env var to VALUE (repeatable)

## What it does

- Mounts: `/nix`, `/etc`, `/proc`, `/dev`, `/tmp`, `/run/current-system`, `/run/wrappers` are made available read-only. `/run/user` is masked with an empty tmpfs (blocks SSH agent socket). `~/.ssh`, `~/.gnupg`, `~/.config/sops`, `~/.aws`, `~/.azure`, `~/.gcloud`, `~/.kube`, `~/.docker`, `~/.netrc`, `~/.git-credentials` are masked.
- Env: scrubbed to `PATH`, `HOME`, `TERM`, `LANG`, `USER`, `LOGNAME`, `LC_*`. Everything else dropped unless you pass `--env`.
- Network: `--net=off` creates a separate net namespace (hard). `--net=allow` shares the parent namespace and sets `HTTP_PROXY`/`HTTPS_PROXY` to a filtering proxy (soft — bypassed by programs that ignore proxy env vars or use UDP).
- Audit: one JSON line to stderr on exit tagged `[agent-sandbox]`. If running as a systemd unit, stderr lands in journald automatically.
- Exits with the child's exit code.

## Local Ollama example

```bash
agent-sandbox --net=allow:127.0.0.1:11434 --bind=$PWD -- \
  python3 my_agent.py
```

Ollama calls go direct (NO_PROXY=127.0.0.1). External HTTPS calls are blocked by the proxy.

## Network isolation note

`--net=allow` is a soft control. Programs that connect without using `HTTP_PROXY` (raw sockets, UDP, curl `--noproxy '*'`) can bypass it. Hard isolation (slirp4netns) is planned for a future phase.

## Nix build

```bash
nix build .#agent-sandbox
```

## Consumption from another flake

```nix
{
  inputs.dotfiles.url = "github:kyleondy/dotfiles";
  outputs = { dotfiles, ... }: {
    environment.systemPackages = [
      dotfiles.packages.${system}.agent-sandbox
    ];
  };
}
```
