# flake input fetching

github.com, codeload.github.com, gitlab.com and flakehub are open: the hosts
flake.lock fetches from. Inputs download in the nix client, before anything
reaches the daemon, so `--allow-nix` alone stops at the proxy on the first
input the store does not hold. Pair the two flags. Substitution is
daemon-side and needs no domain here.

What comes back is code, and the daemon builds it outside this sandbox, so
the trust question in nix.md applies to every input, not just to
derivations written here. Two things this grant still cannot fetch: a host
outside the list (an unknown-host download error means the list needs it,
not that the grant failed), and git+ssh inputs like cogsworth, which need
ssh egress the sandbox withholds.
