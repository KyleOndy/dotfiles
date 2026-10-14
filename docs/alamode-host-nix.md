# Host nix builds for alamode sessions

Status: spiked, built and deployed on trex on 2026-10-14.
The spike ran the session daemon below as a root launchd job for 24 minutes
and then removed it; [What the spike answered](#what-the-spike-answered) has
the results. A first draft proposed a patched daemon plus a TLS-intercepting
proxy. Four adversarial reviews replaced it with what follows; the rejected
design is summarized at the end. Claims marked _untested_ come from reading
source.

A session should be able to `nix build` what it is working on and run the
result. Before this design, on trex it could not. `--allow-nix` meant the
Tart builder ([alamode-builder](../nix/pkgs/alamode-builder/README.md)), trex
has no guest for it, and that builder never imports outputs into the host
store anyway.
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
([daemon.cc](https://github.com/DeterminateSystems/nix-src/blob/v3.23.2/src/libstore/daemon.cc#L291-L303)).
Running an output is no different from running anything else in the
session: it stays inside srt.

It can still do a fair amount. It can build any derivation, add
content-addressed paths, add temporary and indirect GC roots, and run
garbage collection and store optimisation.

The network exposure is what a build can reach. Builds run in the daemon as
`_nixbldN`, outside srt ([darwin-nix-sandbox.md](darwin-nix-sandbox.md)).

- **Fixed-output derivations** get
  [sandbox-network.sb](https://github.com/DeterminateSystems/nix-src/blob/v3.23.2/src/libstore/darwin/build/sandbox-network.sb#L4-L23):
  any IP, mDNSResponder and trustd. The session writes both the URL and the
  build script, so a build can send out anything the session can read, over
  HTTP or DNS, and reach the LAN and every service on trex's loopback.
  `builtin:fetchurl` is the same: it runs as `_nixbldN` under that profile
  ([derivation-builder.cc](https://github.com/DeterminateSystems/nix-src/blob/v3.23.2/src/libstore/unix/build/derivation-builder.cc#L1002-L1027)).
- **`__darwinAllowLocalNetworking`** works on any derivation. `sandbox =
true` refuses only `__sandboxProfile` and `__noChroot`
  ([derivation-builder.cc](https://github.com/DeterminateSystems/nix-src/blob/v3.23.2/src/libstore/unix/build/derivation-builder.cc#L1823-L1835)).
  The attribute opens `localhost:*` and mDNSResponder
  ([sandbox-defaults.sb](https://github.com/DeterminateSystems/nix-src/blob/v3.23.2/src/libstore/darwin/build/sandbox-defaults.sb#L49-L71)).
  A probe with it resolved external names, reached every loopback port and
  `::1`, and reached `0.0.0.0` listeners through the LAN address. That is
  DNS exfiltration from an ordinary build.
- **Unix sockets under the daemon's `TMPDIR`**, `/private/tmp` for the main
  daemon, are reachable from every build
  ([sandbox-defaults.sb](https://github.com/DeterminateSystems/nix-src/blob/v3.23.2/src/libstore/darwin/build/sandbox-defaults.sb#L32-L39)).
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

A second daemon serves sessions only. It is Determinate's own `nix` binary
run as `nix daemon`, with its own socket and config, and a `pre-build-hook`
that refuses every build that would get network. Sessions bring their own
sources, fetched under their own srt policy, and reach it through a patched
client ([The session's client](#the-sessions-client)).

### The hook

Nix runs `pre-build-hook` for every local build, `builtin:fetchurl`
included, with the derivation as JSON in `NIX_DERIVATION_V4` and the `.drv`
path as its argument. Any non-zero exit fails the build
([derivation-builder.cc](https://github.com/DeterminateSystems/nix-src/blob/v3.23.2/src/libstore/unix/build/derivation-builder.cc#L598-L647),
called from `getPathsInSandbox`, which darwin's
[prepareSandbox](https://github.com/DeterminateSystems/nix-src/blob/v3.23.2/src/libstore/darwin/build/darwin-derivation-builder.cc#L36-L39)
runs, and `startBuild` calls that for every build
([L475](https://github.com/DeterminateSystems/nix-src/blob/v3.23.2/src/libstore/unix/build/derivation-builder.cc#L475))).
It is not on the list an untrusted client may set.

The policy is an allowlist: every output input-addressed, and no local
networking. On trex an input-addressed output is `{"path": ...}` and a
fixed-output one `{"hash": ..., "method": "flat"}`. Impure and floating
content-addressed outputs have other shapes, so they fail too.

```sh
jq -e '
  (.outputs | all(keys == ["path"]))
  and ([.env.__darwinAllowLocalNetworking?, .structuredAttrs.__darwinAllowLocalNetworking?]
       | all(. == null or . == "" or . == false))
' "$NIX_DERIVATION_V4"
```

Run against `nix derivation show` output, which is the same JSON, it allows
`hello`, refuses `hello.src` (fixed-output) and refuses
`python3Packages.aiohttp` (local networking).

What the spike taught about the script around it:

- **jq by store path.** Under launchd a bare `jq` would not be on PATH,
  and every build would fail the hook (_untested_; the spike pinned it from
  the start). The module interpolates `${pkgs.jq}`, which also keeps it
  rooted.
- **stdout is a command channel.** Nix reads each line as
  `extra-sandbox-paths` or `extra-chroot-dirs` and fails the build on
  anything else
  ([derivation-builder.cc](https://github.com/DeterminateSystems/nix-src/blob/v3.23.2/src/libstore/unix/build/derivation-builder.cc#L624-L646)).
  Messages go to stderr.
- **stderr lands in the daemon's log**, not the client's terminal. The
  client sees only:

  ```
  building '/nix/store/84prp0ljw7sfkay3sphg7rk2jn6ignd8-canary-fod-1791986476.drv'...
  error: pre-build hook '/private/var/run/alamode-nix-spike/hook' failed with exit code 1
  ```

  With parallel builds several `building` lines are in flight, so nothing
  the client prints names the refused derivation.

What gets through is an input-addressed build under `sandbox = true` with
no local networking. Probes showed that profile gets EPERM for every
address, UDP included, resolves no names, and cannot bind or listen. So
session builds have no network at all.

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
   since `AddToStore` has no trust check beyond repair and
   content-addressed paths need no signature
   ([daemon.cc](https://github.com/DeterminateSystems/nix-src/blob/v3.23.2/src/libstore/daemon.cc#L413-L460),
   [path-info.cc](https://github.com/DeterminateSystems/nix-src/blob/v3.21.8/src/libstore/path-info.cc#L120-L123)).
   The path is fixed by the content, so this cannot poison anything.

A client can turn substitution off, since `substitute` is not a restricted
setting. Then every build runs locally until the first fixed-output one not
in the store, which the hook refuses: the spike's `figlet` with
`--option substitute false` planned 530 derivations and stopped at
`bash-5.2.tar.gz.drv`. So "offline" means everything not on cache.nixos.org
must already be in the store.

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

- **fetchurl**: `nix store prefetch-file`, with `--name` when the URL ends
  in `/`.
- **fetchzip, fetchFromGitHub**: `nix-prefetch-url --unpack --name source`.
- **fetchgit**: check out the rev without `.git`, then
  `nix store add --mode nar --name <name>`. _Untested_, and
  `nix-prefetch-git` is not on a session's PATH.
- **Vendor FODs** (npm, cargo, Go, yarn): `nix print-dev-env` turns a fixed
  output into a deferred one and points `$out` at `$PWD/outputs/out`
  ([develop.cc](https://github.com/DeterminateSystems/nix-src/blob/v3.23.2/src/nix/develop.cc#L267-L288)),
  so the fetch runs in the session:

  ```sh
  nix print-dev-env "$F#fzf.goModules" > env.sh
  mkdir outputs
  bash -c 'source ./env.sh && unset phases && set -e && genericBuild'
  nix store add --mode nar --name fzf-0.60.3-go-modules outputs/out
  ```

  For cargo the fixed output is `<pkg>.cargoDeps.vendorStaging`;
  `cargoDeps` itself is input-addressed and then builds through the hook.
  `mkdir outputs` is needed because installPhase will not create the
  parent. `unset phases` matters only when the caller is itself in a nix
  shell that exports `phases=buildPhase`, as this repo's devshell does.

Measured against the spike daemon on 2026-10-14, as an untrusted user
outside srt: `fzf.goModules` (11 downloads, 2 s) and
`hyperfine.cargoDeps.vendorStaging` (155 crates, 6 s) both landed on
nixpkgs' own paths, `p6p6c1ck...-fzf-0.60.3-go-modules` and
`hykap8qr...-hyperfine-1.19.0-vendor-staging`. `hyperfine.cargoDeps` then
built through the hook to nixpkgs' `lqg7mmnx...-hyperfine-1.19.0-vendor`.
`nix develop --command bash -c genericBuild` does not work: functions do not
reach the child shell (`genericBuild: command not found`), and `nix develop`
also fetched flakehub's nixpkgs-weekly client-side, which `print-dev-env`
did not. Inside srt the route also needs the download hosts
(proxy.golang.org, crates.io) granted. _Untested_ there.

New FOD hashes are rare here: a reviewer counted 15 of 1,092 commits since
April that changed one.

### Daemon setup

- **Binary**: `/nix/var/nix/profiles/default/bin/nix`, run as
  `nix --extra-experimental-features nix-command daemon --socket-path <path>`.
  The legacy `nix-daemon` entry point takes only `--daemon`, `--stdio`, the
  trust flags and `--process-ops`
  ([daemon.cc](https://github.com/DeterminateSystems/nix-src/blob/v3.23.2/src/nix/unix/daemon.cc#L592-L633));
  `--socket-path` exists only on `nix daemon`
  ([L676-L685](https://github.com/DeterminateSystems/nix-src/blob/v3.23.2/src/nix/unix/daemon.cc#L676-L685)).
  `nix-daemon` is a link to the same `nix`, so one
  `determinate-nixd upgrade` moves both daemons, and the schema, temproots
  and GC formats always match. A running daemon keeps the binary it started with, so
  sessions see an upgrade at the session daemon's next restart: a deploy
  that changes its job, a reboot, or a kickstart.
- **Socket**: `/private/var/run/alamode-nix/socket`, in a root-owned 0755
  directory, never session-writable. `/private/var/run` empties at boot, so
  the job creates the directory each time it starts. The daemon makes the
  socket 0666 (`srw-rw-rw- 1 root wheel` in the spike). 2.35 made the
  default path follow the shared state dir, which would collide with
  Determinate's.
- **Config**: its own `NIX_CONF_DIR` and `NIX_USER_CONF_FILES` set to
  empty, so neither `/etc/nix/nix.conf`, `nix.custom.conf` nor root's own
  config leaks in. That means stating everything. The keys the spike ran
  with:
  - `sandbox = true`. darwin defaults to false, and without it the hook
    still refuses FODs but input-addressed builds run unconfined.
  - `sandbox-paths`: darwin's default
    ([globals.cc](https://github.com/DeterminateSystems/nix-src/blob/v3.23.2/src/libstore/globals.cc#L97-L108))
    without `/private/tmp` and `/private/var/tmp`, plus `/nix/store`, or a
    build with more than about 1,069 inputs cannot start:
    `/System/Library/Frameworks /System/Library/PrivateFrameworks /bin/sh /bin/bash /usr/lib /nix/store`.
  - `pre-build-hook` as above.
  - `builders =` empty. Remote builds skip the local hook.
  - `trusted-substituters =` empty, and `substituters` and
    `trusted-public-keys` as the main daemon's.
  - `ssl-cert-file = /etc/nix/macos-keychain.crt`, the bundle
    Determinate's own config names. Whether substitution needs it was not
    tested.
  - `max-jobs = auto` and `cores = 0`, as the main daemon has them.
- **Environment**: a private `TMPDIR`, a root 0700 directory beside the
  socket. Build directories land in `/nix/var/nix/builds` either way (the
  spike's probe saw `TMPDIR=/nix/var/nix/builds/nix-73546-1050701419`).
  What the daemon's `TMPDIR` decides is the unix-socket rule above: every
  build may connect to sockets beneath it
  ([darwin-derivation-builder.cc](https://github.com/DeterminateSystems/nix-src/blob/v3.23.2/src/libstore/darwin/build/darwin-derivation-builder.cc#L158-L173)).
- **launchd**: a `KeepAlive` job, since Nix has no launchd socket activation
  ([nix#5739](https://github.com/NixOS/nix/issues/5739)). nix-darwin's
  `command`, so it waits for `/nix/store` (the exit 78 after a reboot),
  `NumberOfFiles` raised to 1048576, and not the label
  `org.nixos.nix-daemon`. The spike ran without `KeepAlive` or wait4path,
  so neither is tested yet.

Both daemons share the store, state dir and the 32 `nixbld` users. Every
lock is a file in the shared state dir, the user pool locks keep them from
handing out the same user
([user-lock.cc](https://github.com/DeterminateSystems/nix-src/blob/v3.21.8/src/libstore/unix/user-lock.cc#L66-L100)),
and the daemon already forks a worker per connection that opens the store
itself
([daemon.cc](https://github.com/DeterminateSystems/nix-src/blob/v3.21.8/src/nix/unix/daemon.cc#L341-L363)).
The spike ran both under load with no conflict; see
[Q2](#what-the-spike-answered) for what that does and does not cover.

### The session's client

Since 2.35.2, and Determinate 3.23.2, the client reads a path one directory
at a time, and without `O_PATH`, which darwin lacks, it opens each
directory `O_RDONLY`: intermediate components in
`src/libutil/unix/file-system-at.cc`, the parent in
[posix-source-accessor.cc](https://github.com/NixOS/nix/blob/8624d7c74eaee2638d2aff9b1e30455a74baba8c/src/libutil/posix-source-accessor.cc#L389-L395),
whose own comment says read permission is "unavoidable". srt grants a
session only metadata on the ancestors of what it may read, so inside srt
every read by absolute path fails:

```
error: opening directory '/private': Operation not permitted
```

That covers `builtins.pathExists /etc/hosts`, importing a file by absolute
path, and this repo's alamode `sourceDir`, which fails at
`opening directory '/Users'`. Flakes in a git repo are read from the repo
root and work. It reproduces with no sandbox at all, beneath a directory
that grants search but not read (0311):

```
nix-2.35.3                 error: opening directory '.../repro/locked': Permission denied
nix-2.35.3, O_SEARCH       "read through a search-only directory"
determinate-nix-3.21.8     "read through a search-only directory"
determinate-nix-3.23.2     error: opening directory '.../repro/locked': Permission denied
```

The fix is `O_SEARCH`, which needs only search permission.
[alamode-nix-client](../nix/pkgs/alamode-nix-client/default.nix) is the
`nix-upstream` input built the way its own packages.nix builds it, plus
[o-search.patch](../nix/pkgs/alamode-nix-client/o-search.patch). Only nix's
own components rebuild, about 6 minutes. `checks.aarch64-darwin.alamode-nix-client`
runs the 0311 reproducer and is part of `.pi/verify.json`, so a session that
edits the client finds out. The patch is not sent upstream yet. Pinning a
client older than 2.35.2 was rejected: sessions should move with Nix.

Measured inside srt with the patched client, against the main daemon's
socket (the spike daemon was gone by then): `pathExists` and an absolute
import worked, the `/Users` read worked, `store add` worked, and
`prefetch-file` went through srt's proxy, which refused a domain outside
the list with `CONNECT tunnel failed, response 403`. The repo's alamode
check evaluated to the host's derivation, and so did trex's system once
`XDG_CACHE_HOME` was unset.

The client also needs:

- **Its own `NIX_CONF_DIR`.** Otherwise it reads Determinate's
  `/etc/nix/nix.conf` and warns on every command:
  `warning: unknown setting 'eval-cores'` and
  `warning: unknown setting 'lazy-trees'`.
- **A writable `TMPDIR` and a readable cwd**, or it fails with
  `error: cannot get cwd: Operation not permitted`, and `prefetch-file`
  with `Operation not permitted ["/tmp"]`. Sessions have both.
- **The flake bundle's five domains** for eval-time fetches: github.com,
  codeload.github.com, gitlab.com, api.flakehub.com and flakehub.com.
  Inputs download in the client, so without them the trex eval stops at
  NUR's rycee firefox-addons archive on gitlab
  (`unable to download 'https://gitlab.com/api/v4/projects/rycee%2Fnur-expressions/...`).
  A seeded fetcher cache and `--offline` did not get past it.
- **Eval parity.** Every home-manager host runs `stateVersion` 18.09, and
  below 20.09 home-manager takes all five `XDG_*_HOME` paths from the
  evaluating environment
  ([xdg.nix](https://github.com/nix-community/home-manager/blob/db7d5e2332710f5abb088f6b5de927d7f9511b35/modules/misc/xdg.nix#L173-L180)).
  Sessions set three of them, so a session evaluated trex to six
  different derivations, from a `.keep` file named after its cache dir up
  to the system. a6bbbecb pins the five in
  `nix/profiles/common/base.nix`; trex, work-mac and tiger now evaluate the
  same with the variables set or unset.

In the spike, the stock client with `NIX_REMOTE` set printed
`warning: ignoring the client-specified setting 'store', because it is a restricted setting and you are not a trusted user`
on every command. alamode-nix-client with `NIX_REMOTE` prints nothing; only
`--store` on the command line brings the warning back (measured against the
main daemon, 2026-10-14).

### alamode wiring

- **Module.** `nix/modules/darwin_modules/alamode-nix-daemon.nix`
  (`systemFoundry.alamodeNixDaemon`), enabled on trex. The config dir and
  the hook are store paths, so a deploy that changes either rewrites the
  launchd plist and nix-darwin reloads the job.
- **Config.** trex's home config hands the socket and launchd label to
  alamode as `sandbox.nixDaemon`, exclusive with `sandbox.builderConfig`.
  The session config carries `nixDaemonSocket`, `nixDaemonLabel`,
  `nixClient` (alamode-nix-client's bin dir), `nixClientConf` and
  `nixCanary`, as top-level strings, so `pin_store_roots` pins the store
  ones like every other deployment path. `--allow-nix` means the session
  daemon on a host that configures one and the Tart builder on a host with
  `sandbox.builderConfig`, and `policy()` refuses nix on a host with neither
  (`nix/pkgs/alamode-runtime/session.py`).
- **Environment.** The client goes first on PATH, `NIX_REMOTE` is
  `unix:///private/var/run/alamode-nix/socket` (the real path, three
  slashes, the form the spike reached from srt), and `NIX_CONF_DIR` holds
  only `experimental-features = nix-command flakes`.
- **srt** allows the one socket. `/nix/var/nix/daemon-socket` stays denied;
  the spike's srt refused the main daemon by that path and by
  `/private/var/run/nix-daemon.socket` alike.
- **Canary**, at every nix-granted start: launch, resume, regrant and
  coordinator children. Before the session gets the socket, alamode builds
  five derivations through it (`nix/pkgs/alamode-runtime/nix-canary.nix`),
  each with a nonce so none is ever cached, and with `substitute = false`,
  which the daemon takes from an untrusted client. Without it a cache that
  times out fails every canary before the hook runs, which reads as a
  daemon that would give a build network (2026-10-14).
  - **fod**, **fetchurl** (`builtin:fetchurl`) and **localnet**
    (`__darwinAllowLocalNetworking`) must be refused by the hook.
  - **net**, input-addressed, opens 1.1.1.1:443 through bash's `/dev/tcp`
    and must fail in the sandbox, not at the hook.
  - **large** takes `/run/current-system` as an input, 1,994 paths on trex,
    and must succeed. It exits 0 only when it can open its input and is
    denied `/private/etc/ssh/ssh_config` and the network.

  Each canary is its own `nix build`, all five in parallel, since the
  hook's error names no derivation and one `--keep-going` run could not say
  which build it refused. Any other outcome refuses the start, names the
  canaries that failed, and writes each one's output to the session
  record's `nix-canary.log`. A daemon that does not answer gets the
  `launchctl kickstart` to start it instead. This catches a missing
  `sandbox = true`, a hook that fails open, and a sandbox regression like
  GHSA-m4vq, which left the small canaries confined while every large build
  ran unconfined. On the main daemon (2026-10-14) the set took about 3 s,
  nearly all of it the large canary's 2.9 s. On the session daemon it took
  3.08 s: the three refusals came back in 0.6 to 1 s and net in 1.1 s, so
  large sets the time on either daemon. The same file on the main daemon showed the detection works: fod and
  fetchurl reached the network and localnet built, so all three would have
  refused the start, while net was denied and large stayed confined.

- **Refusals** are explained in the grant doc, not parsed out of the build.
  The error names no derivation, so `grants/nix-daemon.md`, which a host
  with a session daemon deploys as `grants/nix.md`, tells a session to list
  what a build would build (`nix build --dry-run`), find the fixed-output
  ones, and prefetch them. `grants/flake.md`, `.claude/rules/alamode.md` and
  the alamode docs follow.

## What the spike answered

The spike ran on trex on 2026-10-14 from 14:01Z to 14:25Z, Determinate
3.23.2 (nix 2.35.3), as the launchd job `org.ondy.alamode-nix-spike` with
the config above and a copy of the hook that also logged each verdict. The
probes ran as kyle, an untrusted user, outside srt unless noted.

1. **Does the hook fire for every build, including substitutions that fall
   back to building?** For every local build, yes, and substitution never
   calls it:

   | Build                                              | Hook       |
   | -------------------------------------------------- | ---------- |
   | fixed-output, `builtin:fetchurl`, local networking | refused    |
   | input-addressed, small and with 1,994 inputs       | allowed    |
   | `--rebuild` of hello, figlet, jq                   | allowed    |
   | `print-dev-env`'s `-env` derivation                | allowed    |
   | substitution of `hello` and `hello.src`            | not called |
   | `--fallback` on a fixed output the cache has       | not called |
   | `--option substitute false`                        | called     |

   A substitution that fails and falls back to building was not exercised;
   forcing builds stood in for it. A fallback build takes the same
   `startBuild` path. _Untested_. The client's attempts to switch the
   policy off were all ignored:

   ```
   warning: ignoring the client-specified setting 'sandbox-paths', because it is a restricted setting and you are not a trusted user
   warning: ignoring the client-specified setting 'sandbox', because it is a restricted setting and you are not a trusted user
   warning: ignoring the client-specified setting 'pre-build-hook', because it is a restricted setting and you are not a trusted user
   warning: ignoring the client-specified setting 'builders', because it is a restricted setting and you are not a trusted user
   error: pre-build hook '/private/var/run/alamode-nix-spike/hook' failed with exit code 1
   ```

2. **Do the two daemons coexist under load?** Build users and locks, yes.
   40 builds of 8 s, 20 on each daemon at once:

   ```
   both done in 22s
   distinct uids: 32 peak concurrent: 32
   same uid overlapping: 0
   cross-daemon overlap seen: True
   ```

   No SQLite busy or lock errors. The last 8 builds waited for a free
   build user, which is the stall in
   [What still gets through](#what-still-gets-through). The main daemon
   honored the session daemon's temp roots, refusing to delete a `.drv`
   it was building:

   ```
   error: Cannot delete path '/nix/store/b0dfrwgghv9jn4lw91mqx3x6a2z9g4wg-gc-b.drv' because it's in use by '{censored}'.
   ```

   **Not tested: deleting a running build's real input.** The runs meant
   to do it deleted unrelated paths, because each evaluation took a fresh
   nonce from `builtins.currentTime`, so the build in flight depended on a
   different input from the one deleted. From the source, _untested_:
   darwin finds runtime roots only through lsof
   ([local-gc.cc](https://github.com/DeterminateSystems/nix-src/blob/v3.23.2/src/libstore/local-gc.cc#L123-L141)),
   but inputs are held by temp roots, which each input's own goal adds
   ([substitution-goal.cc](https://github.com/DeterminateSystems/nix-src/blob/v3.23.2/src/libstore/build/substitution-goal.cc#L45-L54),
   [derivation-goal.cc](https://github.com/DeterminateSystems/nix-src/blob/v3.23.2/src/libstore/build/derivation-goal.cc#L66-L70)),
   and the `.drv` refusal above shows temp roots crossing daemons. Nor did
   determinate-nixd's own GC run during a session build; `nix store
delete` from the main daemon stood in for it. A rerun should realise
   `b` from a single instantiation and delete its actual `env.dep`.

3. **Does dropping `/private/tmp` and `/private/var/tmp` break ordinary
   builds?** No. `--rebuild` of hello, figlet and jq built (their outputs
   differ from cache.nixos.org's on the main daemon too). Seven of the
   verify checks rebuilt bit-identical, `pre-commit-run` built fresh, and
   alamode-e2e was refused by the hook. A probe build was denied writes to
   `/private/tmp`, `/private/var/tmp` and `/tmp`.
4. **Does the `nix develop` route produce vendor outputs that match their
   hashes?** Through `print-dev-env`, yes, for Go and cargo
   ([Where sources come from](#where-sources-come-from)). Not run inside
   srt.
5. **Can another LAN host connect in to a build's `0.0.0.0` listener?**
   Moot. A build the hook allows cannot bind or listen at all:

   ```
   canary-scratch> 0.0.0.0 listen: [Errno 1] Operation not permitted
   canary-scratch> 127.0.0.1 listen: [Errno 1] Operation not permitted
   ```

   Binding needs `_ALLOW_LOCAL_NETWORKING`
   ([sandbox-defaults.sb](https://github.com/DeterminateSystems/nix-src/blob/v3.23.2/src/libstore/darwin/build/sandbox-defaults.sb#L51-L54)),
   which only `__darwinAllowLocalNetworking` sets, and the hook refuses
   that.

The canaries behaved as designed on the spike daemon: fod, builtin:fetchurl
and localnet refused by the hook; net allowed by the hook and failed with
`curl: (7) Failed to connect to 1.1.1.1:443 after 0 ms`; large, with 1,994
paths in its closure, read its own input and was denied
`/private/etc/ssh/ssh_config` and example.com.

## Deployed

The spike daemon was removed before alamode-nix-client existed, so nothing
reached its socket from srt on the patched client. After the deploy, an
`alamode --allow-nix` session on trex passed the canary and then, inside
srt:

- **Evaluated** nixpkgs from `/nix/store` in 1 s.
- **Substituted** curl's dev output from cache.nixos.org through the
  session daemon.
- **Built** `hello` from source in 28 s, with an extra attribute to force
  the build, and ran it: `Hello, world!`.
- **Was refused** a nixpkgs `fetchurl`:

  ```
  building '/nix/store/adzih8g9f7qp1rkqwrfx3alc57lln42c-e2e-18518.drv'...
  error: pre-build hook '/nix/store/nk0ssfhk89h0b8c810qmc85kc1npx56r-alamode-nix-pre-build-hook' failed with exit code 1
  ```

- **Could not reach the host daemon**, as `daemon` or by its socket path:

  ```
  error: cannot connect to socket at '/nix/var/nix/daemon-socket/socket': Operation not permitted
  ```

Still untested: `KeepAlive` and wait4path, a real substitution fallback,
and the deletion of a running build's input (Q2).

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
  all 32 build users and stall a host deploy until it is killed. The spike
  had all 32 in use across both daemons, with the rest queued.
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

- **Done**: the spike, the client patch carried in the repo with its check,
  the darwin module, the alamode wiring, the canary, the grant docs, and
  the deploy to trex with a session building through it. The patch
  rebuilds nix's own components on every nix-upstream bump until upstream
  takes it or another fix lands.
- **Left**: the items under [Deployed](#deployed) that are still untested.
- No proxy, no CA, and no allowlist to curate.

It does not make the verifier runnable in a session. alamode-e2e binds
loopback, which the hook refuses (the spike's log:
`refuse /nix/store/68j329k6nf79f0b7rd08vq4p6pkhwj9y-alamode-e2e-check.drv`),
and Linux derivations need the builders it turns off. Any build that needs
an uncached derivation with `__darwinAllowLocalNetworking` fails the same
way. The alamode-nix-client check's build closure holds nine, curl, openssl
and rustc among them, so the check builds in a session only while those
come from the cache or the host's store. What the design buys is "build and
run my package".

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
