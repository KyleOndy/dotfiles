# Work Config Split

A private work repo (`/Users/kondy/work`) layers sensitive config on top of this
public repo via a flake input. The split principle: keep everything public except
items that leak internal company details.

## What lives where

- **This repo (public)**: all packages, tools, env vars, aliases, shell config,
  non-sensitive skills and commands. Anything that isn't company-confidential
  belongs here, in `nix/hosts/work-mac/`.
- **Work repo (private)**: only sensitive items: git work email, internal
  CLAUDE.md (cluster names, AWS profiles), cluster-health skill (internal cluster
  names), and work-specific linear commands (internal workflow details).
- **`nix/work-config-stub/flake.nix`**: no-op default; documents the required
  flake interface (`darwinModule`, `homeManagerModule`).

## Building and deploying

All `make` targets accept `WORK_CONFIG=` to activate work config:

```bash
make build-mac-dry WORK_CONFIG=/Users/kondy/work   # dry run
make deploy HOSTNAME=work-mac WORK_CONFIG=/Users/kondy/work
make deploy-mac WORK_CONFIG=/Users/kondy/work       # same thing
```

Without `WORK_CONFIG`, builds use the stub and produce a personal/CI-safe
configuration with no work-specific modules included.
