# nix daemon access

The nix daemon socket is granted, so `nix build`, `nix eval` and friends
work against what the store holds; fetching an input the store lacks also
needs `--allow-flake`. Builds do not run inside this sandbox, and what
that costs is two daemon-owned bits, both named at startup:

- Whether this client is trusted. A trusted client can override
  `build-users-group` and build as root; the daemon answers untrusted on
  hosts whose `trusted-users` does not cover the invoking user.
- Whether the daemon sandboxes its builds. With `sandbox = true` a
  builder stays inside nix's own sandbox as `_nixbld`, with no network
  unless it is a fixed-output derivation: those keep the network so they
  can fetch, and the hash is checked only after the builder ran. It can
  still write `/tmp`, and reaches 127.0.0.1 when the derivation sets
  `__darwinAllowLocalNetworking`. With
  `sandbox = false` a builder is unconfined code with the whole network:
  measured on such a daemon, a build launched from inside this sandbox
  wrote a file to `/tmp`, fetched `https://example.com` directly with no
  srt proxy or domain allowlist in between, and was kept out of `$HOME`
  by unix permissions alone, not by any policy.

Treat every derivation you build as code running outside this sandbox,
confined by whatever those two bits said and by nothing here.

The flake reads the git tree, so a file that is not `git add`ed is
invisible to `nix eval` and `nix build`. On main, master or a detached
HEAD the git dirs are read-only and `git add` fails.
