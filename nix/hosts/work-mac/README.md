# Work Mac Configuration

nix-darwin configuration for the work macOS machine (user `kondy`).

## Deployment

```bash
# With work-specific config (git email, internal CLAUDE.md, cluster-health skill)
make deploy HOSTNAME=work-mac WORK_CONFIG=/Users/kondy/work

# Without work config (uses the no-op stub, personal email)
make deploy HOSTNAME=work-mac
```

See `CLAUDE.md` in this directory for what lives in the public repo versus the
private work repo, and `nix/work-config-stub/flake.nix` for the interface a
work config has to implement.

## Manual Setup

Shottr needs one-time manual configuration after install: it keeps its
preferences in a sandboxed container that does not exist until first launch,
so `defaults write` silently does nothing before then. The settings to apply
are in `nix/hosts/trex/README.md`, which covers the same install.
