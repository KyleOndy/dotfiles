# flake input fetching

This grant carries `--allow-nix`, and opens github.com, codeload.github.com,
gitlab.com and flakehub: the hosts flake.lock fetches from. Inputs download
in the nix client, before anything reaches the daemon, which is why
`--allow-nix` alone stops at the proxy on the first input the store does not
hold. Substitution is daemon-side and needs no domain here. The bundle
inherits the nix grant whole, so a fixed-output derivation still fetches
daemon-side, past this list and the proxy, as nix.md says.

What comes back is code, and the daemon builds it outside this sandbox, so
the trust question in nix.md applies to every input, not just to
derivations written here. Two things this grant still cannot fetch:

- **A host outside the list**: an unknown-host download error means the
  list needs it, not that the grant failed. install.determinate.systems
  (the determinate-nixd inputs) is one, so a `determinate` bump fails here.
- **git+ssh inputs** like cogsworth: they fail even under
  `--allow-ssh-agent`, because srt's own `GIT_SSH_COMMAND` cannot
  authenticate to its proxy.
