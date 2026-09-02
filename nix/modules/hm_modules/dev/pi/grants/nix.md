# nix daemon access

The nix daemon socket is granted, so `nix build`, `nix eval` and friends
work. Builds do not run inside this sandbox: the daemon builds them itself,
as root where it trusts this client and as `_nixbld` where it does not. The
wrapper said which at startup. Treat anything a derivation produces as
trusted code.

The flake reads the git tree, so a file that is not `git add`ed is invisible
to `nix eval` and `nix build`.
