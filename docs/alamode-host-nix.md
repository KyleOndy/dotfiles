# Host nix builds for alamode sessions

Status: design, 2026-10-14. Nothing here is built, and nothing has been
tried with root on trex. A first draft proposed a patched daemon plus a
TLS-intercepting proxy. Four adversarial reviews replaced it with what
follows; the rejected design is summarized at the end. Claims marked
_untested_ come from reading source.

A session should be able to `nix build` what it is working on and run the
result. On trex it cannot. `--allow-nix` means the Tart builder
([alamode-builder](../nix/pkgs/alamode-builder/README.md)), trex has no guest
for it, and that builder never imports outputs into the host store anyway.
The direct route is the host nix-daemon, which sessions lost because of what
builds can reach.

The goal is that route back, without the daemon giving a session any network
srt does not already give it.

## First: upgrade Nix

Five advisories landed on 2026-10-13. Determinate
[3.23.2](https://github.com/DeterminateSystems/nix-src/releases/tag/v3.23.2)
and upstream 2.35.3 and 2.34.9 fix them.

- **[GHSA-jwvx-xq5j-gc56](https://github.com/NixOS/nix/security/advisories/GHSA-jwvx-xq5j-gc56)**
  (high): an untrusted client corrupts any store path through the repair
  flag. That is root for anyone who can reach a daemon socket.
- **[GHSA-m4vq-qf6v-82pj](https://github.com/NixOS/nix/security/advisories/GHSA-m4vq-qf6v-82pj)**
  (medium): the darwin profile chunking. Once the profile passes 16 KiB,
  every remaining input path opens its own allow group, and a missing
  optional path leaves that group empty, which allows every file
  ([darwin-derivation-builder.cc](https://github.com/DeterminateSystems/nix-src/blob/v3.21.8/src/libstore/unix/build/darwin-derivation-builder.cc#L130-L147)).
  nixpkgs' darwin stdenv lists two optional paths trex does not have,
  `/usr/lib/libSystem.B.dylib` and `/usr/lib/system/libunc.dylib`, and both
  sort after `/nix/store`. So since `sandbox = true` on 2026-10-10, trex
  builds with more than about 16 KiB of inputs had no file confinement. The
  network rules were not affected.
- **[GHSA-92x5-h528-wrmw](https://github.com/NixOS/nix/security/advisories/GHSA-92x5-h528-wrmw)**
  (low): the macOS daemon accepted connections from build users.
- **[GHSA-25vp-6h23-hj3g](https://github.com/NixOS/nix/security/advisories/GHSA-25vp-6h23-hj3g)**
  (medium): a `genList` overflow in the evaluator. It runs as whoever
  evaluates, and the daemon socket cannot reach it.
- **[GHSA-hf6w-2rg9-v84g](https://github.com/NixOS/nix/security/advisories/GHSA-hf6w-2rg9-v84g)**
  (medium): the scripted installer only. trex used Determinate's.

trex runs 3.23.2 since 2026-10-14, and tiger, pika and cogsworth run 2.35.3
through the `nix-upstream` overlay in `flake.nix`; work-mac moves on its
next deploy. The fix exposed a macOS limit: a sandbox profile holds about
1,069 store paths, so larger builds failed to start until
`extra-sandbox-paths = /nix/store`
([darwin-nix-sandbox.md](darwin-nix-sandbox.md#large-builds)). The
verifier passed on trex after both.

The design below uses Determinate's own daemon binary, so the same upgrade
covers it. Nothing below is safe before it.

## What the daemon socket gives a session

trex has `trusted-users = root`, so a session's client is untrusted. It can
set only a handful of settings (build-timeout, max-silent-time,
poll-interval, connect-timeout, `builders = ""`, and substituters the daemon
already trusts), and it cannot import unsigned paths or, from 3.23.2,
repair
([daemon.cc](https://github.com/DeterminateSystems/nix-src/blob/v3.21.8/src/libstore/daemon.cc#L302-L315)).
Running an output is no different from running anything else in the
session: it stays inside srt.

It can still do a fair amount. It can build any derivation, add
content-addressed paths, add temporary and indirect GC roots, and run
garbage collection and store optimisation.

The network exposure is what a build can reach. Builds run in the daemon as
`_nixbldN`, outside srt ([darwin-nix-sandbox.md](darwin-nix-sandbox.md)).

- **Fixed-output derivations** get
  [sandbox-network.sb](https://github.com/DeterminateSystems/nix-src/blob/v3.21.8/src/libstore/unix/build/sandbox-network.sb#L4-L23):
  any IP, mDNSResponder and trustd. The session writes both the URL and the
  build script, so a build can send out anything the session can read, over
  HTTP or DNS, and reach the LAN and every service on trex's loopback.
  `builtin:fetchurl` is the same: it runs as `_nixbldN` under that profile
  ([derivation-builder.cc](https://github.com/DeterminateSystems/nix-src/blob/v3.21.8/src/libstore/unix/build/derivation-builder.cc#L1412-L1438)).
- **`__darwinAllowLocalNetworking`** works on any derivation. `sandbox =
true` refuses only `__sandboxProfile` and `__noChroot`
  ([derivation-builder.cc](https://github.com/DeterminateSystems/nix-src/blob/v3.21.8/src/libstore/unix/build/derivation-builder.cc#L2179-L2192)).
  The attribute opens `localhost:*` and mDNSResponder
  ([sandbox-defaults.sb](https://github.com/DeterminateSystems/nix-src/blob/v3.21.8/src/libstore/unix/build/sandbox-defaults.sb#L51-L71)).
  A probe with it resolved external names, reached every loopback port and
  `::1`, and reached `0.0.0.0` listeners through the LAN address. That is
  DNS exfiltration from an ordinary build.
- **Unix sockets under `/tmp`** are reachable from every build
  ([sandbox-defaults.sb](https://github.com/DeterminateSystems/nix-src/blob/v3.21.8/src/libstore/unix/build/sandbox-defaults.sb#L36-L39)).
- **Remote builders.** `/etc/nix/machines` sends aarch64-linux builds to the
  Rosetta VM and x86_64-linux builds to tiger as `svc.nixbuild`, which tiger
  trusts (`nix/hosts/tiger/configuration.nix`). Linux FODs get a network
  namespace only when sandboxed, which FODs are not
  ([linux-derivation-builder.cc](https://github.com/DeterminateSystems/nix-src/blob/v3.21.8/src/libstore/unix/build/linux-derivation-builder.cc#L459-L460)),
  so a session's x86_64-linux FOD reaches tiger's loopback and the homelab
  LAN.

On trex every bit of that is new. The session allowlist is empty by default
(`nix/modules/hm_modules/dev/alamode/default.nix`) and trex sets none, so a
web-off session has no egress through srt at all.

## Nothing upstream closes it

- `allowed-uris` is checked by the evaluator, which the session runs itself
  ([pi-sandbox-audit.md](pi-sandbox-audit.md), item 8).
- No setting customizes the darwin profile, in 3.21.8 or 2.35.3. FOD egress
  has open issues back to 2018:
  [nix#2270](https://github.com/NixOS/nix/issues/2270),
  [nix#4584](https://github.com/NixOS/nix/issues/4584),
  [nix#6049](https://github.com/NixOS/nix/issues/6049), plus
  [nix#2414](https://github.com/NixOS/nix/issues/2414), closed as stale on
  2026-08-13.
- `external-builders` skips the darwin sandbox entirely
  ([external-derivation-builder.cc](https://github.com/DeterminateSystems/nix-src/blob/v3.21.8/src/libstore/unix/build/external-derivation-builder.cc#L18-L98)).
- Guix gives Linux FODs their own network namespace, Lix does as an opt-in,
  and so would an open upstream PR
  ([nix#15959](https://github.com/NixOS/nix/pull/15959)). None of them
  filters destinations, and none applies to darwin.
- Nobody promises this boundary. From a NixOS member on the Nix tracker:
  "Stopping information leaks with the Darwin sandbox is not really a
  realistic goal"
  ([nix#11269](https://github.com/NixOS/nix/issues/11269#issuecomment-2287357362)).

## The design: a session daemon that builds offline

A second nix-daemon serves sessions only. It is Determinate's own binary
with its own socket and config, and a `pre-build-hook` that refuses every
build that would get network. Sessions bring their own sources, fetched
under their own srt policy.

### The hook

Nix runs `pre-build-hook` for every local build, `builtin:fetchurl`
included, with the derivation as JSON in `NIX_DERIVATION_V4`. Any non-zero
exit fails the build
([derivation-builder.cc](https://github.com/DeterminateSystems/nix-src/blob/v3.21.8/src/libstore/unix/build/derivation-builder.cc#L985-L1010),
called from `getPathsInSandbox`, which darwin's
[prepareSandbox](https://github.com/DeterminateSystems/nix-src/blob/v3.21.8/src/libstore/unix/build/darwin-derivation-builder.cc#L55-L58)
runs for every build). It is not on the list an untrusted client may set.

The policy is an allowlist: every output input-addressed, and no local
networking. On trex an input-addressed output is `{"path": ...}` and a
fixed-output one `{"hash": ..., "method": "flat"}`. Impure and floating
content-addressed outputs have other shapes, so they fail too.

```sh
#!/bin/sh
# Refuses any build that would get network: fixed-output, impure and
# floating content-addressed derivations, and __darwinAllowLocalNetworking.
jq -e '
  (.outputs | all(keys == ["path"]))
  and ([.env.__darwinAllowLocalNetworking?, .structuredAttrs.__darwinAllowLocalNetworking?]
       | all(. == null or . == "" or . == false))
' "$NIX_DERIVATION_V4" >/dev/null && exit 0
echo "alamode: this build needs network; prefetch its sources in the session" >&2
exit 1
```

Run against `nix derivation show` output, which is the same JSON, it allows
`hello`, refuses `hello.src` (fixed-output) and refuses
`python3Packages.aiohttp` (local networking).

What gets through is an input-addressed build under `sandbox = true` with
no local networking. Probes showed that profile gets EPERM for every
address, UDP included, and resolves no names. So session builds have no
network at all.

### Where sources come from

1. **The shared store.** Anything the host already built or fetched is
   valid for sessions.
2. **The daemon's substituters.** The daemon fetches from cache.nixos.org
   itself, as root. With `trusted-substituters` empty, a session cannot
   point lookups anywhere else. Four of four nixpkgs FOD outputs probed
   were on cache.nixos.org (`hello.src`, `ripgrep.cargoDeps`, `kubectl.src`,
   `gh.goModules`).
3. **The session.** It fetches inside srt, under that session's own policy,
   and adds the result by content hash. An untrusted client can do that,
   since `AddToStore` has no trust check and content-addressed paths need no
   signature
   ([daemon.cc](https://github.com/DeterminateSystems/nix-src/blob/v3.21.8/src/libstore/daemon.cc#L424-L461),
   [path-info.cc](https://github.com/DeterminateSystems/nix-src/blob/v3.21.8/src/libstore/path-info.cc#L120-L123)).
   The path is fixed by the content, so this cannot poison anything.

The third route, measured on trex as an untrusted user:

```
$ nix store add --mode flat --name ca-probe payload
/nix/store/h3r6pinp3nx0rkyxdl91szgjcbwxbf4b-ca-probe
$ nix build --impure --expr 'derivation { name = "ca-probe"; ...;
    builder = "/bin/sh"; args = [ "-c" "exit 1" ];
    outputHashMode = "flat"; outputHash = "<hash of payload>"; }'
/nix/store/h3r6pinp3nx0rkyxdl91szgjcbwxbf4b-ca-probe
```

The FOD's builder would fail, and it never ran. The commands per fetcher:

- **fetchurl**: `nix store prefetch-file`.
- **fetchzip, fetchFromGitHub**: `nix-prefetch-url --unpack --name source`.
- **fetchgit**: `nix-prefetch-git`, then `nix store add --mode nar`.
- **Vendor FODs** (npm, cargo, Go, yarn): `nix develop` turns a fixed
  output into a deferred one and writes outputs under `$PWD/outputs`
  ([develop.cc](https://github.com/DeterminateSystems/nix-src/blob/v3.21.8/src/nix/develop.cc#L269-L290)),
  so the fetch runs in the session, followed by `nix store add`.
  _Untested_ end to end.

New FOD hashes are rare here: a reviewer counted 15 of 1,092 commits since
April that changed one.

### Daemon setup

- **Binary**: `/nix/var/nix/profiles/default/bin/nix-daemon`, so one
  `determinate-nixd upgrade` moves both daemons. The schema, temproots and
  GC formats always match.
- **Socket**: an explicit path in a root-owned 0755 directory, never
  session-writable. 2.35 made the default follow the shared state dir,
  which would collide with Determinate's, and added `--socket-path`
  ([daemon.cc](https://github.com/DeterminateSystems/nix-src/blob/v3.23.2/src/nix/unix/daemon.cc#L676-L685)).
- **Config**: its own `NIX_CONF_DIR` and `NIX_USER_CONF_FILES=` so neither
  `nix.custom.conf` nor root's own config leaks in. That means stating
  everything:
  - `sandbox = true`. darwin defaults to false, and without it the hook
    still refuses FODs but input-addressed builds run unconfined.
  - `pre-build-hook` as above.
  - `builders =` empty. Remote builds skip the local hook.
  - `trusted-substituters =` empty, `substituters` as the main daemon's.
  - `sandbox-paths` without `/private/tmp` and `/private/var/tmp`, and with
    `/nix/store`, or a build with more than about 1,069 inputs cannot
    start. On the main daemon (2026-10-14), a build with 1,994 inputs
    started, read its inputs, and was denied both
    `/private/etc/ssh/ssh_config` and example.com.
- **Environment**: a private `TMPDIR`, which closes the `/tmp` sockets.
- **launchd**: a `KeepAlive` job, since Nix has no launchd socket activation
  ([nix#5739](https://github.com/NixOS/nix/issues/5739)). Use nix-darwin's
  `command` so it waits for `/nix` (the exit 78 after a reboot), raise
  `NumberOfFiles`, and avoid the label `org.nixos.nix-daemon`.
- **Canary**: before granting the socket, alamode builds three derivations
  that must fail: an FOD, a `__darwinAllowLocalNetworking` one, and an
  input-addressed one that connects to 1.1.1.1. Any success refuses the
  grant. This catches a missing `sandbox = true` or a broken hook. A
  fourth must succeed: one with more than 1,069 inputs whose builder
  exits 0 only when it cannot read a host file. The first three are all
  small builds, and GHSA-m4vq left those confined, so they would have
  passed while every large build ran unconfined. The fourth carries a
  nonce, since a built output would never run again.

Both daemons share the store, state dir and the 32 `nixbld` users. Every
lock is a file in the shared state dir, the user pool locks keep them from
handing out the same user
([user-lock.cc](https://github.com/DeterminateSystems/nix-src/blob/v3.21.8/src/libstore/unix/user-lock.cc#L66-L100)),
and the daemon already forks a worker per connection that opens the store
itself
([daemon.cc](https://github.com/DeterminateSystems/nix-src/blob/v3.21.8/src/nix/unix/daemon.cc#L341-L363)).
determinate-nixd collects garbage by running `nix store gc`, which honors
the other daemon's temproots. Nobody has written up running two, though.

### alamode wiring

- A `nixDaemon` config holding the socket and a pinned client path,
  exclusive with `builder`. `policy()` refuses nix without one
  (`nix/pkgs/alamode-runtime/session.py`).
- The session's PATH gets that client with its own config dir, and
  `NIX_REMOTE=unix:///...`.
- srt allows the one socket, spelled with its `/private/var/run` real path.
- The grant docs follow: `grants/nix.md`, `grants/flake.md`,
  `.claude/rules/alamode.md`.
- A refused build reports only that the pre-build hook failed; the hook's
  stderr goes to the daemon's log. alamode reads the refused `.drv` from the
  build error and prints the prefetch command for it.

## What still gets through

- **Planted builds.** A session can build any derivation into the shared
  store. The host reuses a path only when it evaluates that same
  derivation, which means building the session's edits, the trust model we
  already have. The residue is nondeterministic builds and impurities.
  Dropping `/private/tmp` from the session daemon's sandbox closes the
  shared scratch space between the two daemons' builds.
- **Garbage collection.** An untrusted client can collect garbage and
  optimise the store
  ([daemon.cc](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/daemon.cc#L743-L765)).
  A session can delete every unrooted path: no corruption, just rebuilds.
  The cogsworth kernel already has deploy-rs GC roots.
- **Build users.** The client sets its own max-jobs, so a session can hold
  all 32 build users and stall a host deploy until it is killed.
- **Pinned disk.** Indirect GC roots are ungated, so a session can keep
  closures alive against determinate-nixd's GC. They live in the session's
  own tree, so removing the worktree releases them.
- **Store entries.** With `/nix/store` in `sandbox-paths`, a session build
  can read any store path, which the session can already do, and create
  entries in `/nix/store`, which is `drwxrwxr-t root:nixbld`. It cannot
  change or remove registered paths, which are root's and read-only. Nix
  deletes an unregistered path before it builds or substitutes into it
  ([derivation-builder.cc](https://github.com/NixOS/nix/blob/8624d7c74eaee2638d2aff9b1e30455a74baba8c/src/libstore/unix/build/derivation-builder.cc#L447-L448),
  [local-store.cc](https://github.com/NixOS/nix/blob/8624d7c74eaee2638d2aff9b1e30455a74baba8c/src/libstore/local-store.cc#L1137-L1138)).
- **The darwin sandbox itself.** Nix, nix-darwin and Hydra's Macs all
  leave it off, so few people exercise it. GHSA-m4vq left every build over
  about 250 inputs without file confinement, and nobody noticed until the
  advisory. Network denial held through that, and network is what this
  design needs most. Upstream does not promise either.

## Cost

- One darwin module: the launchd job, the config dir and the hook.
- The alamode wiring above, and the canary.
- A reviewer's estimate is a day or two, unmeasured. No patch, no proxy, no
  CA, and no allowlist to curate.

It does not make the verifier runnable in a session. alamode-e2e binds
loopback, which the hook refuses, and Linux derivations need the builders it
turns off. What it buys is "build and run my package".

A session-only Linux VM with no network would cover more of the verifier:
all nine checks exist under `checks.aarch64-linux` (evaluated, not built,
2026-10-14), and Linux gives a build its own loopback. It cannot build
`make build-mac build-trex`, and nothing it builds runs on trex. The
current Rosetta VM does not qualify: its lima config sets no network, so
lima's default NAT gives it the internet and the LAN
([module.nix](https://github.com/cpick/nix-rosetta-builder/blob/50e6070082e0b4fbaf67dd8f346892a1a9ed685c/module.nix#L202-L231)).

## Rejected: patched daemon plus intercepting proxy

The first draft patched Nix so FODs could reach only a local
TLS-intercepting proxy, which allowed GET and HEAD to allowlisted hosts.
The reviews found:

- **It widens default sessions.** One proxy has one allowlist, and SBPL can
  name only one fixed `localhost:PORT`, so sessions cannot be told apart.
  On trex a web-off session has no egress, and its builds would gain GET to
  every allowlisted host.
- **It adds a channel.** A GET to an attacker's repo shows in GitHub's
  traffic stats and release download counts, and on trex srt gives a
  web-off session nothing like it.
  [CVE-2026-54316](https://github.com/anthropics/claude-code/security/advisories/GHSA-fg94-h982-f3mm)
  used the same trick through huggingface.co.
- **Ongoing work**: a Nix patch rebased per release (the darwin builder
  moved in 2.35), a source override per advisory, a CA key, mitmproxy's
  fail-open defaults, Go broken until 1.27, `configurable-impure-env`, and
  substitution routed through the proxy.
- **srt-proxy**, the fail-closed alternative, is unreleased and still needs a
  decider written for it.

The patch did compile and work: against 2.34.9 a fixed-output build reached
only the proxy port. It is in this doc's history if a per-host allowlist
ever becomes the goal.

pf by build uid was rejected earlier. It cannot see DNS through
mDNSResponder or trustd, which run as other users.

## Open questions, needing root on trex

1. Does the hook fire for every build the session daemon runs, including
   substitutions that fall back to building?
2. Do the two daemons coexist under load: concurrent builds, Determinate's
   GC during a session build, SQLite busy errors?
3. Does dropping `/private/tmp` and `/private/var/tmp` from `sandbox-paths`
   break ordinary builds?
4. Does the `nix develop` route produce vendor FOD outputs that match their
   hashes?
5. Can another LAN host connect in to a build's `0.0.0.0` listener?
