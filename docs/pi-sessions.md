# Pi sessions on Darwin

Start in a repository with `pi`, or use `pi --coordinator` to manage durable
children from the main conversation. A launch snapshots the repository into
private Git storage. Commits stay there until explicitly exported or
integrated. Outside Git, Pi starts with an empty private workspace.

## Grants

Choose grants when creating a session:

```sh
pi --coordinator --allow-kagi --allow-node --listen 3000
pi --coordinator --allow-nix
pi --coordinator --allow-forge
```

`--web` permits public web destinations. `--allow HOST` adds one destination.
`--allow-read PATH` grants host reads; `--allow-rw PATH` grants reads and writes.
Use private `$TMPDIR` for scratch files. Broad writes overlapping trusted
service sockets or session records are rejected.

`--listen PORT` admits one loopback listener and connections to that port.
It also authorizes any existing host service on that port; choose deliberately.
Provider and Kagi credentials stay in host relays. Workloads receive scoped
tokens. The host model catalog must explicitly list each permitted model.

`--allow-nix` requires `sandbox.builderConfig` in the Pi Home Manager module
and a provisioned [Darwin builder](../nix/pkgs/pi-builder/README.md).
`nix build` and `nix eval` snapshot dirty files, submit them to that service,
and preserve stdout, stderr and exit status. Outputs stay in the retained VM.
The host daemon socket is never granted.

## Resume and results

```sh
pi --list-sessions
pi --inspect-session SESSION_ID
pi --resume-session SESSION_ID
pi --coordinator=COORDINATOR_ID
pi --export-session SESSION_ID
```

Resume restores the recorded grants and workspace. Start a new session to
change authority. Runtime or provider-route changes require a new session;
the error identifies the mismatch. Provider credentials may rotate.

Export requires committed changes and a stopped session. It prints a
verified, standalone bundle and ref. Review that bundle before integrating
it into the human repository. Export never changes the human branch.

The coordinator's tools handle questions, steering, interruption, follow-up,
result inspection and child integration. Closing the UI leaves children
running. Reconnect with the printed coordinator ID. Closing a child preserves
its work. A lost worker requires explicit resume; interrupted work is not
replayed automatically.

Forge is optional. Ordinary children and the Nix builder work without it.
`pi-delegate` uses the same coordinator service; `pi-delegate --help` lists
its standalone commands.
