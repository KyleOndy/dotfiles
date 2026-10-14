# flake input fetching

This grant carries `--allow-nix`, and opens github.com, codeload.github.com,
gitlab.com and flakehub: the hosts flake.lock fetches from. Inputs download
in the nix client, inside this sandbox and before anything reaches a build,
which is why `--allow-nix` alone stops at the proxy on the first input the
store does not hold. Substitution needs no domain here. What a build itself
may fetch is the nix grant's business, as nix.md says.

What comes back is code that builds outside this sandbox, so treat every
input as you would a derivation written here. Two things this grant still
cannot fetch:

- **A host outside the list**: an unknown-host download error means the
  list needs it, not that the grant failed. install.determinate.systems
  (the determinate-nixd inputs) is one, so a `determinate` bump fails here.
- **git+ssh inputs** like cogsworth: they fail even under
  `--allow-ssh-agent`, because srt's own `GIT_SSH_COMMAND` cannot
  authenticate to its proxy.
