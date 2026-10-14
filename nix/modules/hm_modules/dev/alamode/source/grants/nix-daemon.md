# Nix through the session daemon

`nix` here is a client for a nix daemon that serves only alamode sessions.
`nix build`, `nix eval`, `nix store add` and `nix print-dev-env` work, and
outputs land in the host's store, so you can run what you build. What you
run stays inside this sandbox.

Every build that daemon runs is offline. Its pre-build hook refuses any
fixed-output derivation (fetchurl, fetchFromGitHub, fetchgit, the vendor
hashes behind cargoDeps, goModules and npmDeps), `builtin:fetchurl`, and any
derivation that sets `__darwinAllowLocalNetworking`, because the macOS build
sandbox would give each of those the network outside this session's policy.
A refusal names no derivation:

```
error: pre-build hook '/nix/store/...-alamode-nix-pre-build-hook' failed with exit code 1
```

Substitution is untouched: the daemon fetches whatever cache.nixos.org
holds, so most fixed-output inputs never build. For one it refuses:

1. List what would build: `nix build --dry-run <installable>`. Of the
   derivations it lists, the fixed-output ones are the ones to fetch:
   `nix derivation show <drv>` shows a `hash` in their `outputs`.
2. Fetch it here, under this session's network grants, and add it by
   content hash. It lands at the path the derivation names, and the daemon
   then has nothing to build:
   - **fetchurl**: `nix store prefetch-file --name <name> <url>`
   - **fetchzip, fetchFromGitHub**: `nix-prefetch-url --unpack --name source <url>`
   - **Vendor hashes** (Go, npm, and cargo's `cargoDeps.vendorStaging`):
     `nix print-dev-env <drv> > env.sh; mkdir outputs; bash -c 'source ./env.sh && unset phases && set -e && genericBuild'; nix store add --mode nar --name <name> outputs/out`
   - **Anything else**: build the output tree here, then
     `nix store add --mode nar --name <name> <tree>`.
3. Run the build again.

A fetch the proxy refuses needs its host granted: ask for it with /regrant
rather than working around the refusal. Flake inputs download in this
client too, which is what `--allow-flake` is for.

Two kinds of build cannot run here at all: one that binds loopback, such as
a test suite with a local server, which needs `__darwinAllowLocalNetworking`,
and a Linux derivation, since the daemon has no remote builders. The repo's
verifier needs both, so it stays the human's to run.
