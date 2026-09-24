# nix daemon access

The nix daemon socket is granted, so `nix build`, `nix eval` and friends
work against what the store holds; fetching an input the store lacks also
needs `--allow-flake`. Builds do not run inside this sandbox: the daemon runs
them as `_nixbld`, and where it trusts this client, the client can override
`build-users-group` and build as root. In strict mode the wrapper said which
at startup. Treat every derivation you build as code running outside this
sandbox.

The flake reads the git tree, so a file that is not `git add`ed is invisible
to `nix eval` and `nix build`. On main, master or a detached HEAD the git
dirs are read-only and `git add` fails.
