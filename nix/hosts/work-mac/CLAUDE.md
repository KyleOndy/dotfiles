# Work Config Split

A private work repo (`/Users/kondy/work`) layers sensitive config on top of this
public repo via a flake input. The split principle: keep everything public except
items that leak internal company details.

## What lives where

- **This repo (public)**: all packages, tools, env vars, aliases, shell config,
  non-sensitive skills and commands. Anything that isn't company-confidential
  belongs in this repo; settings only work-mac wants go in `nix/hosts/work-mac/`.
  work-mac is the only host that installs `forge` (`nix/pkgs/forge/README.md`).
- **Work repo (private)**: only sensitive items: git work email, internal
  CLAUDE.md (cluster names, AWS profiles) and pi `AGENTS.md`, pi's
  `models.json` with its Keychain key resolvers and advisor env, and the
  linear, helm, gh and forge-phase commands (internal workflow details).
- **`nix/work-config-stub/flake.nix`**: no-op default; documents the required
  flake interface (`darwinModule`, `homeManagerModule`).

## Building and deploying

`deploy`, `boot`, `apply` and the `*-mac` targets accept `WORK_CONFIG=` to
activate work config; `build`, `check` and the trex targets ignore it. The
value is the work config flake directory, which is the work repo's `nix/`
subdirectory:

```bash
make build-mac-dry WORK_CONFIG=/Users/kondy/work/nix   # dry run
make deploy HOSTNAME=work-mac WORK_CONFIG=/Users/kondy/work/nix
make deploy-mac WORK_CONFIG=/Users/kondy/work/nix       # same thing
```

Without `WORK_CONFIG`, builds use the stub and produce a personal/CI-safe
configuration with no work-specific modules included.

## Manual setup

Shottr is installed here too. Its one-time manual setup is in
`nix/hosts/trex/README.md`, which covers the same install.
