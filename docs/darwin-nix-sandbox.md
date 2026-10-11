# The nix build sandbox on darwin

A nix build runs in the daemon as `_nixbld`, outside any sandbox its
client runs in. What the build can reach is a daemon-owned bit:
`sandbox`. Nix defaults it to `false` everywhere but Linux and FreeBSD
([local-settings.hh](https://github.com/NixOS/nix/blob/979a87c97bef7b96cd4ec4b142188089851e47ad/src/libstore/include/nix/store/local-settings.hh#L361-L393)),
and so does Determinate's nix-darwin module
([default.nix](https://github.com/DeterminateSystems/determinate/blob/68e51a34285ceb664e74d078bcd46a15f984dfe4/modules/nix-darwin/default.nix#L594-L605)). trex sets it to `true` in
`determinateNix.customSettings`; work-mac does not set it.

Measured on trex with `sandbox = false` (2026-10-10): a derivation built
from inside the srt sandbox ran as `uid=351(_nixbld1)`, wrote a marker to `/tmp` (a write srt
denies the session itself), and fetched `https://example.com` directly,
HTTP 200, with no srt proxy and no domain allowlist in between. It could
not read `$HOME`, because unix permissions on the human's home directory
stop `_nixbld`, not because any policy does, and it could not write
`/nix/var/nix`. So with `sandbox = false` a build is arbitrary code as
`_nixbld` with unrestricted network.

`sandbox = true` is the fix nix itself offers. It is a partial fix, and
what it leaves is the part that matters most here. Measured on trex
(2026-10-10) with a probe derivation that tries each path below, built
both directly and from inside the srt sandbox under `--allow-nix`, with
the same result either way:

| Build                                           | `/tmp` write | `/etc` read | example.com | 127.0.0.1 | unix socket in `/tmp` |
| ----------------------------------------------- | ------------ | ----------- | ----------- | --------- | --------------------- |
| any, `sandbox = false`                          | yes          | yes         | 200         | 200       | 200                   |
| input-addressed                                 | yes          | no          | none        | none      | 200                   |
| input-addressed, `__darwinAllowLocalNetworking` | yes          | no          | none        | 200       | 200                   |
| fixed-output, wrong hash                        | yes          | no          | 200         | 200       | 200                   |

`/tmp` here is `/private/tmp` and `/private/var/tmp` alike, and `/etc` is
`/private/etc/ssh/ssh_config`. Under `true` the daemon refused a
derivation with `__noChroot` and one with a `sandboxProfile`, and ignored
`--option sandbox false`, `--option sandbox relaxed`, `--no-sandbox` and
`--option extra-sandbox-paths` from this untrusted client:

```
warning: ignoring the client-specified setting 'sandbox', because it is a restricted setting and you are not a trusted user
```

- **What it closes.** A build sees its build dir and declared inputs,
  not the host's files, and an input-addressed build gets no network.
  A derivation cannot opt out: under `true` the daemon refuses one that
  sets `__noChroot` or brings its own sandbox profile
  ([unix-derivation-builder.cc](https://github.com/NixOS/nix/blob/979a87c97bef7b96cd4ec4b142188089851e47ad/src/libstore/unix/build/unix-derivation-builder.cc#L1067-L1080)).
- **What it leaves.** A fixed-output derivation keeps the network. The
  darwin builder adds the network profile to any derivation nix does not
  sandbox, and fixed-output ones are not
  ([darwin-derivation-builder.cc](https://github.com/NixOS/nix/blob/979a87c97bef7b96cd4ec4b142188089851e47ad/src/libstore/darwin/build/darwin-derivation-builder.cc#L90-L93),
  [sandbox-network.sb](https://github.com/NixOS/nix/blob/979a87c97bef7b96cd4ec4b142188089851e47ad/src/libstore/darwin/build/sandbox-network.sb#L4)).
  The output hash is checked after the builder has run, so a fixed-output
  build with a wrong hash gets its requests out before it fails. The hash
  protects what a fetch returns, not what it sends. With or without the
  flip, a build is a way past its client's domain allowlist for anything
  the client can read. Loopback is one attribute away for any derivation:
  `__darwinAllowLocalNetworking` opens every port on 127.0.0.1
  ([sandbox-defaults.sb](https://github.com/NixOS/nix/blob/979a87c97bef7b96cd4ec4b142188089851e47ad/src/libstore/darwin/build/sandbox-defaults.sb#L49-L54)).
- **What stays open.** `/private/tmp` and `/private/var/tmp` stay
  writable. They are in darwin's default `sandbox-paths`
  ([globals.cc](https://github.com/NixOS/nix/blob/979a87c97bef7b96cd4ec4b142188089851e47ad/src/libstore/globals.cc#L94-L107)), and every one of those is
  granted read and write
  ([darwin-derivation-builder.cc](https://github.com/NixOS/nix/blob/979a87c97bef7b96cd4ec4b142188089851e47ad/src/libstore/darwin/build/darwin-derivation-builder.cc#L104-L135)).
  A unix socket in `/private/tmp` is reachable too: the profile lets a
  build connect to sockets in the daemon's temp dir
  ([sandbox-defaults.sb](https://github.com/NixOS/nix/blob/979a87c97bef7b96cd4ec4b142188089851e47ad/src/libstore/darwin/build/sandbox-defaults.sb#L32-L39)),
  which is its `TMPDIR` with symlinks resolved, so `/private/tmp` on trex
  ([darwin-derivation-builder.cc](https://github.com/NixOS/nix/blob/979a87c97bef7b96cd4ec4b142188089851e47ad/src/libstore/darwin/build/darwin-derivation-builder.cc#L156)).
  Every socket under `/private/tmp` on trex today sits in a directory
  only its owner can enter, so unix permissions keep `_nixbld` out, and
  a session cannot add one there, since srt denies it `/tmp`.

`relaxed` would not do. It runs fixed-output derivations and any
`__noChroot` one outside the sandbox
([unix-derivation-builder.cc](https://github.com/NixOS/nix/blob/979a87c97bef7b96cd4ec4b142188089851e47ad/src/libstore/unix/build/unix-derivation-builder.cc#L1083-L1085)),
so a derivation could opt out with one attribute. The cost of `true` is the
same refusal seen from the other side: nixpkgs gives some darwin packages
a sandbox profile of their own (24 derivations in trex's closure, among
them nodejs, fish, mpv and dotnet), and a daemon running `true` cannot
build those. All 24 come from cache.nixos.org today, so it bites only on
a cache miss or an override of one of them.

The flip can also break derivations that read outside their build dir
or bind loopback, which the darwin sandbox allows only to a derivation
that sets `__darwinAllowLocalNetworking`
([darwin-derivation-builder.cc](https://github.com/NixOS/nix/blob/979a87c97bef7b96cd4ec4b142188089851e47ad/src/libstore/darwin/build/darwin-derivation-builder.cc#L169-L172)).
pi-e2e's dump server binds 127.0.0.1, so it sets the attribute; built
without it, the check fails at the bind:

```
PermissionError: [Errno 1] Operation not permitted
```

The setting does not change derivation hashes, so nothing already in the
store is rebuilt, and verify after the flip re-runs only a check whose
hash changed. Testing the flip takes `--rebuild`. Rebuilt that way once
the daemon had restarted (below), on 2026-10-10:

- The verify checks and pi-e2e all passed except leak-guard's: git could
  not exec a hook whose first line was `#!/usr/bin/env bash`, since
  `/usr/bin/env` is not in the sandbox, so its hooks use `#!/bin/sh`.
- Of the 269 derivations in trex's closure that trex built itself rather
  than substituted, 259 rebuilt identically and 9 rebuilt with output
  that differs from the stored copy, which `--rebuild` reports as
  nondeterministic whatever the sandbox. The last, google-fonts, had an
  output never built before; it built cleanly on its own.

The daemon reads the setting when it starts. A deploy rewrites
`/etc/nix/nix.custom.conf`, Determinate's module has no step that
restarts the daemon, and the probe kept fetching until
`sudo launchctl kickstart -k system/systems.determinate.nix-daemon`.
`make deploy-trex` runs that restart when the switch changed
`/etc/nix/nix.custom.conf` or `/etc/nix/machines`; a bare
`darwin-rebuild switch` leaves the old settings running.
