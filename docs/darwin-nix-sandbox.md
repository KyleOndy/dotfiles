# The nix build sandbox on darwin

A nix build runs in the daemon as `_nixbld`, outside any sandbox its
client runs in. What the build can reach is a daemon-owned bit:
`sandbox`. Nix defaults it to `false` everywhere but Linux and FreeBSD
([local-settings.hh](https://github.com/NixOS/nix/blob/979a87c97bef7b96cd4ec4b142188089851e47ad/src/libstore/include/nix/store/local-settings.hh#L361-L393)),
and so does Determinate's nix-darwin module
([default.nix](https://github.com/DeterminateSystems/determinate/blob/68e51a34285ceb664e74d078bcd46a15f984dfe4/modules/nix-darwin/default.nix#L594-L605)). trex sets it to `true` in
`determinateNix.customSettings`, work-mac in
`nix/modules/darwin_modules/base.nix`.

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

- **What it closes.** A build sees its build dir and the store, not the
  host's files, and an input-addressed build gets no network. The whole
  store rather than only declared inputs, because of the size cap below.
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
  `__darwinAllowLocalNetworking` opens every port on 127.0.0.1, and
  mDNSResponder with it
  ([sandbox-defaults.sb](https://github.com/NixOS/nix/blob/8624d7c74eaee2638d2aff9b1e30455a74baba8c/src/libstore/darwin/build/sandbox-defaults.sb#L49-L71)).
  So such a build resolves any name, and a lookup of a name under a
  domain someone else runs carries data out. Measured on trex
  (2026-10-14): with the attribute, curl resolved example.com and failed
  only at the connect; without it, curl could not resolve the name.
- **What stays open.** `/private/tmp` and `/private/var/tmp` stay
  readable and writable. They are in darwin's default `sandbox-paths`
  ([globals.cc](https://github.com/NixOS/nix/blob/979a87c97bef7b96cd4ec4b142188089851e47ad/src/libstore/globals.cc#L94-L107)), and every one of those is
  granted read and write
  ([darwin-derivation-builder.cc](https://github.com/NixOS/nix/blob/979a87c97bef7b96cd4ec4b142188089851e47ad/src/libstore/darwin/build/darwin-derivation-builder.cc#L104-L135)).
  A build reads any file there that others may read, and a fixed-output
  one can send it on. A unix socket in `/private/tmp` is reachable too,
  through a separate rule for the daemon's temp dir
  ([sandbox-defaults.sb](https://github.com/NixOS/nix/blob/979a87c97bef7b96cd4ec4b142188089851e47ad/src/libstore/darwin/build/sandbox-defaults.sb#L32-L39)),
  which is its `TMPDIR` with symlinks resolved, so `/private/tmp` on trex
  ([darwin-derivation-builder.cc](https://github.com/NixOS/nix/blob/979a87c97bef7b96cd4ec4b142188089851e47ad/src/libstore/darwin/build/darwin-derivation-builder.cc#L156)).
  Measured, with a world-writable socket in each: a build connected to
  the one in `/private/tmp` and not to the one in `/private/var/tmp`.
  Every socket under `/private/tmp` on trex today sits in a directory
  only its owner can enter, so unix permissions keep `_nixbld` out, and
  a session cannot add one there, since srt denies it `/tmp`. Closing the
  socket rule takes a different `TMPDIR` for the daemon, which no setting
  reaches: it comes from the launchd plist Determinate's installer
  writes, and the module's `envVars` go to the shell's environment, not
  the daemon's
  ([default.nix](https://github.com/DeterminateSystems/determinate/blob/68e51a34285ceb664e74d078bcd46a15f984dfe4/modules/nix-darwin/default.nix#L309-L316),
  [L846-L847](https://github.com/DeterminateSystems/determinate/blob/68e51a34285ceb664e74d078bcd46a15f984dfe4/modules/nix-darwin/default.nix#L846-L847)).
  Closing the files also takes `sandbox-paths` restated without the two
  dirs.

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
alamode-e2e's dump server binds 127.0.0.1, so it sets the attribute; built
without it, the check fails at the bind:

```
PermissionError: [Errno 1] Operation not permitted
```

The setting does not change derivation hashes, so nothing already in the
store is rebuilt, and verify after the flip re-runs only a check whose
hash changed. Testing the flip takes `--rebuild`. Rebuilt that way once
the daemon had restarted (below), on 2026-10-10:

- The verify checks and alamode-e2e all passed except leak-guard's: git could
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
`make deploy` runs that restart when the switch changed `/etc/nix/nix.conf`,
`/etc/nix/nix.custom.conf` or `/etc/nix/machines` (`deploy-trex` and
`deploy-mac` are aliases for it), and picks the daemon's launchd label per
machine: Determinate's on trex, nix-darwin's on work-mac. A bare
`darwin-rebuild switch` leaves the old settings running.

## Large builds

macOS merges each sandbox operation's path filters into one object and
refuses a profile whose object passes 65535 bytes. Nix lists every
input store path in the profile, so a build with more than about 1,069
inputs fails before it starts. home-manager-applications has 1,291:

```
sandbox initialization failed: data object length 79249 exceeds maximum (65535)
```

Nix splits the paths across allow forms at 16 KiB, its answer to
[nix#4119](https://github.com/NixOS/nix/issues/4119)
([darwin-derivation-builder.cc](https://github.com/NixOS/nix/blob/8624d7c74eaee2638d2aff9b1e30455a74baba8c/src/libstore/darwin/build/darwin-derivation-builder.cc#L104-L140)),
but the cap is per operation, not per form. Measured with `sandbox-exec`
on profiles in Nix's shape (2026-10-14): one form and 1,113 forms fail
at the same size, and the same paths split between `file-read*` and
`process-exec` compile.

Before Nix 2.35.3 and Determinate 3.23.2 the cap never showed, because
large builds had no file confinement at all (GHSA-m4vq-qf6v-82pj).
Every darwin stdenv derivation lists `/usr/lib/libSystem.B.dylib` and
`/usr/lib/system/libunc.dylib` as optional impure inputs, and neither is
on disk on current macOS. The splitting opened a new form before it
skipped a missing optional path, leaving an unqualified
`(allow file-read* file-write* process-exec)` behind. Both paths sort
after `/nix/store`, so every build with more than about 250 inputs
crossed a split and hit it. A profile of that shape compiled, read
`~/.zshrc` and ran `/usr/bin/curl`; the network stayed denied.

`extra-sandbox-paths = /nix/store`, on trex and work-mac alike, keeps
those builds running. With it added to home-manager-applications'
profile, the profile compiled, `~/.zshrc` was denied, `/nix/store` was
readable and `example.com` was unreachable. The cost:

- **A build reads any store path**, not only its inputs. The store is
  world-readable, so this loses hermeticity, not secrecy: a build can
  depend on a path it never declared.
- **A build can add entries to `/nix/store`**, which is
  `drwxrwxr-t root:nixbld`. Registered paths are read-only and owned by
  root, and the sticky bit keeps a build from removing or renaming
  them.
