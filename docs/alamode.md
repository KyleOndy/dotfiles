# alamode

**alamode** is this repository's session agent product: `pi`, but better.
The upstream [pi coding agent](https://github.com/earendil-works/pi) is
the engine, unmodified and unnamed on PATH. alamode owns the launch
surface: sandbox admission, grants, sessions, the coordinator, delegation,
model seats, and completion.

Goals are in [alamode-requirements.md](alamode-requirements.md); this
document defines names, commands, and state.

## 1. Names

alamode is the product. pi is the engine. Every word belongs to exactly
one layer, and the prefix of an environment variable says who reads it:
`ALAMODE_*` is ours, `PI_*` is upstream's.

### 1.1 Environment variables

Ours: every variable our code writes or reads (including test harness
variables) carries the `ALAMODE_` prefix.

Upstream's (read by the real pi binary, kept verbatim):
`PI_CODING_AGENT_DIR`, `PI_TELEMETRY`, `PI_SKIP_VERSION_CHECK`,
`PI_OFFLINE`.

Internal JSON keys: the session config carries `bundles`, `profiles`,
`coordinatorDaemon`, `delegateBin` and `seatsBin`. `pi` (the engine path)
and `piArgs` (engine arguments) are named for the engine. The coordinator
config key for the launcher binary is `launcher`. The coordinator wire
protocol ops are `spawn`, `status`, `result`, `events`, `send`, `answer`,
`interrupt`, `resume`, `close`, `teardown`, `report`, `question`,
`forge_boot`, `offer`, `admit` and `shutdown` (section 3).

### 1.2 Kept words

- **grant**: all authority; `--allow-*` is its only spelling.
- **session**: a launch and its recorded authority.
- **seat**: a role's model assignment; `alamode seats`.
- **delegate**: handing a durable task over the trust boundary.
- **admit / admission**: both trust gates (session admission, bundle admission).
- **bundle**: a named grant set (`--allow-go`), with no "network" qualifier because bundles also carry filesystem and service grants.
- **workspace, containment, relay, builder, supervisor, forge, advisor, human**: as the rest of the repo uses them.
- **agent**: the unit of delegated work (spawned, supervised, torn down). "worker" is never user- or module-visible (the option is `maxRetainedAgents`); it appears only inside the coordinator daemon, as the concurrent-RPC-process cap (`ALAMODE_COORD_MAX_WORKERS`), and in supervisor internals. **child** appears only as the coordinator role value (`role: child`).
- **coordinator**: the durable service and its identity, not "broker"; the daemon binary is `alamode-coordinator`.

### 1.3 Do not touch

- The upstream binary, its flags, and its env vars (section 1.1); the npm
  imports `@earendil-works/pi-coding-agent`, `pi-ai`, `pi-tui`.
- `~/.pi/**` (upstream's config root) and the repo's `.pi/` directory
  (`verify.json`, `secret-guard.json`, per-project agent state).
- macOS Keychain item labels (`-s pi`): renaming them requires manual
  host migration for no visible gain.
- `pika` (host), `pia-wireguard`, Raspberry Pi references (cogsworth), `RPI-RP2`.
- Historical records keep their era's names (`pi-sandbox-audit.md`),
  under a one-line note at the top that the names predate the alamode
  rename.
- `advisor-eval` keeps its name (no pi in it).
- `alamode-runtime`'s `$out/bin/nix`: the scoped build client intentionally
  shadows `nix` inside `--allow-nix` sessions.

## 2. Command surface

One binary, verb-first for management, flags for launches, `--` as the
hard boundary to the engine:

```
alamode [--profile NAME] [GRANTS] [-- PI-ARGS]
alamode resume [ID] [-- PI-ARGS]
alamode sessions [show ID | export ID]
alamode coord [GRANTS] | attach ID | start [GRANTS] | ls | stop ID
alamode delegate ...        # = alamode-delegate
alamode seats ...          # = alamode-seats
```

- Bare `alamode` launches an interactive session in `$PWD` (snapshotting
  the repository into private Git storage; empty scratch workspace
  outside one).
- **Strict boundary.** Wrapper flags and the verb must come before `--`;
  everything after `--` reaches pi verbatim. An unknown flag or positional
  before `--` is an error whose message says to move it after `--`, so
  the engine can never grow a flag that silently changes alamode's
  meaning.
- Grants: `--web`, `--allow HOST`, `--listen PORT`,
  `--allow-read|-write|-rw PATH`, `--allow-nix`, `--allow-git-write` /
  `--no-git-write`, `--allow-trustd`, `--allow-forge`, `--allow-clipboard`,
  `--allow-<bundle>`.
- `--help`/`-h` prints alamode's own usage (only ours; the engine's help
  is `alamode -- --help`). `--version`/`-v` pass through to the engine.
  `--managed-manifest` is coordinator-internal and undocumented in help.
- `resume` with no ID resumes the most recent record.
- `coord` starts a new coordinator; `coord attach ID` reconnects to a live
  or stopped one; `coord start` prints the JSON credentials (socket,
  token, coordinator, session, workspace) for headless consumers
  (`alamode-delegate` standalone mode consumes it).
- Grants hold exactly on resume/attach: recorded grants are replayed, any
  requested change is refused, children spawn through the wrapper with
  recorded policy, credentials stay in the relay.

### 2.1 Help text (canonical)

```
alamode [--profile NAME] [--web] [--allow HOST] [--listen PORT]
        [--allow-read PATH] [--allow-write PATH] [--allow-rw PATH]
        [--allow-nix] [--allow-git-write] [--no-git-write]
        [--allow-trustd] [--allow-forge] [--allow-clipboard]
        [--allow-BUNDLE] [--local] [--no-PROVIDER] [-- PI ARGS]
alamode resume [ID] [-- PI ARGS]
alamode sessions [show ID | export ID]
alamode coord [GRANTS] | attach ID | start [GRANTS] | ls | stop ID
alamode delegate ... | seats ...

A launch snapshots the current repository into private Git storage.
Outside a repository, launches use an empty private scratch workspace.
Grants persist on resume. Provider credentials stay in the host relay.
Flags after -- reach pi verbatim; alamode flags never follow it.
--allow-nix requires a configured isolated builder.
--local admits only loopback models and refuses every network grant.
--no-PROVIDER drops that provider and every model on its endpoints.
coord start prints JSON credentials without opening the UI.
```

`bin/alamode --help` must exit 0 and contain `resume` and `coord` (the
Makefile smoke greps this).

### 2.2 Profiles

`hmFoundry.dev.alamode.sandbox.profiles` is an attrsOf grant presets:

```nix
profiles.work = {
  readPaths = [ "~/work" ];
  bundles = [ "kagi" "linear" ];
  # also: domains, writePaths, listenPorts, trustd, nix, forge
};
```

`--profile NAME` (repeatable, merging by union / logical or) expands into
the same option fields the flags set, before grant-recording, so resumes
refuse drift exactly as they do for flags. An unknown profile name is a
launch-time error; a profile referencing an unknown bundle is a build-time
error. Profiles never imply a verb: `coord` stays explicit, as in `pic`:

```zsh
pic() {
  # …ticket sniff…
  alamode coord --profile work $grants "$@"
}
```

## 3. Coordinator lifecycle

The coordinator is not a system service: its policy comes from the
launching session's manifest, so on-demand start from a session is
correct. `coord ls` is its address book and `coord stop` its clean stop.

- `alamode coord ls` scans `~/.local/state/alamode/coordinators/*/`,
  pings each socket, and prints ID, live/stopped, repo, agent count.
- `alamode coord stop ID` sends the `shutdown` wire op (main token
  only) over the coordinator socket read from `broker.json`. The daemon
  releases its lock, unlinks its socket and pidfile, and exits. Agents
  are untouched: their supervisors are detached and keep running.
  Attaching to a stopped coordinator restarts the daemon from the
  recorded `broker.json` (the init path does this), so stop is
  reversible and cheap.
- Daemon CLI:
  `alamode-coordinator init --coord-dir DIR --repo DIR --launcher PATH --policy FILE`
  and `alamode-coordinator credentials DIR`. The internal re-entry flags
  are `--serve` and `--supervise`.
- Child spawn command inserts the boundary: `[launcher,
"--managed-manifest", path, "--", "--mode", "rpc", "--session", file,
…]`.
- `alamode-delegate` standalone mode runs
  `alamode coord start --grant…` (via `ALAMODE_DELEGATE_LAUNCHER`,
  default `alamode`) and stores connections under
  `~/.local/state/alamode/delegates/`.

## 4. Completion

The wrapper package installs `_alamode` at
`share/zsh/site-functions/_alamode` with `#compdef alamode`. The wrapper
build asserts the compdef token equals `meta.mainProgram`.

- Verb dispatch with `_arguments -C` state machine: first word completes
  `resume sessions coord delegate seats`; after `--`, file completion
  only; before it, grant flags (with `@bundleFlags@` and `@profileNames@`
  substituted at build time).
- IDs complete from pure globs over the state layout (no socket pings on
  TAB): `resume` and `sessions show|export` offer
  `~/.local/state/alamode/records/*/`; `coord attach|stop` offer
  `~/.local/state/alamode/coordinators/*/`; `delegate` offers
  `~/.local/state/alamode/delegates/*.json` stems.
- `delegate` and `seats` complete as subcommands of `_alamode` (no
  separate completion files).
- A check runs zsh against the installed wrapper:
  `autoload -Uz compinit; fpath=(<out>/share/zsh/site-functions $fpath);
compinit -u; whence -w _alamode` must print `_alamode: function`.
