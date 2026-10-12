> Historical record. Names in it predate the alamode rename.

# Pi sandbox audit: what held, what didn't

Status: audit report, 2026-10-11. Run from inside the sandbox the way a
compromised session would run it: one coordinator session in this worktree on
trex (aarch64-darwin, srt 0.0.78 in strict mode), carrying `nix`, `flake` and
`coordinator`. The wrapper (`nix/pkgs/pi-wrapper`) and the srt profile it
generates were the map, and every claim below was probed live unless it says
otherwise. Nothing sensitive was read or moved: proofs are file-touch markers
and child stderr, the one credential file involved was a scratch copy, and
every plant was removed in the turn that made it.

## What held

The OS layer survived every probe aimed at it:

- Read denies: `$HOME` root, `~/.ssh`, `~/.gnupg`, `/run/secrets`, sibling
  worktree admin dirs, the git-crypt key dirs (the worktree-root
  `.git-crypt/keys/` export is GPG ciphertext; the plaintext key stays
  denied), other projects' transcripts (names listable by design, contents
  denied), `/tmp`, `/Users/Shared`.
- `link(2)` and APFS `clonefile(2)` both fail with EPERM on denied sources,
  so Seatbelt's path-based denies cannot be sidestepped by inode aliasing.
- Write denies: `/tmp`, `~/Library`, `$HOME` root, `/nix/store`,
  `.gitmodules`, `.bare/hooks`, `.bare/config`, `commondir`, and
  `config.worktree`; `git worktree add` dies at `commondir`; `refs/heads/main`
  is immovable (the reflog deny fires first).
- Sockets and mach: ssh-agent, tmux, the docker socket, launchctl and `sudo`
  are all denied. Keychain queries are contained by the `~/Library` read deny
  (the database opens client-side), so `envGrantGates` holds for the
  Keychain-stored Kagi key: an ungated session cannot query it out.
- Network: DNS resolution is dead, direct IP connections are dead, and the
  srt proxy 403s any host not on the allowlist. Only loopback to the session's
  own proxy port answers.
- The broker's request path validates everything the coordinator can write
  (agent/model/thinking shapes, a regular-file check after the atomic rename,
  no decision read back from child-writable state); no injection was found.

The escapes below are therefore not Seatbelt breaks. They are crossings
through state the sandbox shares between sessions, or grants whose cost is
larger than their name.

## Findings

### 1. `~/.pi/agent/bin`: sessions plant binaries pi's own tools execute (high)

pi prepends `<agent-dir>/bin` to every session's child PATH and checks it
before PATH (`getToolPath` in pi's `tools-manager.ts`: `if
(existsSync(localPath)) return localPath`). The managed `fd`/`rg` downloads
carry no hash or signature check (the GitHub-Releases-API checksum dependency
was removed, pi CHANGELOG #418), and `github.com` is allowlisted under
`flake`, so a session can even fetch the real artifacts and trojan them.
`bin` is absent from the wrapper's `pi_loadable_names` denyWrite list.

Proof: a pass-through `rg` planted in `~/.pi/agent/bin` was executed by pi's
own structured grep tool in a fresh subagent (the marker logged the pid), and
by bash-tool children. The wrapper ships fd and rg on PATH, and a subagent's
grep and find worked with no `bin/` at all, so the deny costs nothing.

Fix: add `bin` to `pi_loadable_names` (and cover `npm/`, where pi installs
packages it loads).

### 2. settings.json: `shellPath` and `shellCommandPrefix` execute in the next session (high)

The file is writable by every session ("pi's own state"), and both keys are
documented exec primitives (pi docs/settings.md). No env var or CLI flag
overrides settings keys in pi 1.0.0 or 1.1.0 (researched across both), so
there is nothing to pin the values with; `PI_CODING_AGENT_DIR` relocates the
whole agent dir, too blunt a lever.

Proof: in a scratch agent dir, a fresh headless child ran the planted
`shellPath` (`$0` reported `/bin/sh`) and executed the planted
`shellCommandPrefix` (marker). On trex the attack is masked by the
stall-guard bug below, which is luck rather than policy: it still lands in
`-e` runs, extension-load failures, pi-delegate/SDK children, and any host
without the mask.

Fix: wrapper start-time validation. Read settings.json before dispatch and
refuse on exec-shaped keys that differ from the deployed values (`shellPath`,
`shellCommandPrefix`, `npmCommand`, `defaultProjectTrust`, `httpProxy`,
`sessionDir`, `defaultTools`), the same refuse-don't-widen shape as
`__pi_refuse_untrusted`.

### 3. auth.json: outranks the env key, and executes `!command` (high)

pi's resolution order is a runtime `--api-key`, then `auth.json`, then the
models.json `apiKey`, then the environment (pi docs/models.md), so the
session-writable file beats the wrapper's carefully env-resolved key. Values
can be `!command` (executed when the credential is first needed, pi
docs/providers.md) plus an `env` object that overrides the process
environment.

Proof: a scratch auth.json with `!touch <marker>` as the mcloud credential
made a fresh child execute the command (marker) and then fail auth with "No
API key found for mcloud", while the control run with no auth.json entry
authenticated fine through the env key.

Fix: purge stored credentials (`/logout` leaves models.json and env alone),
denyWrite `auth.json` and `mcp-auth.json`, and add `auth.json` to
secret-guard's denyPatterns. Check per host first that nothing depends on a
stored credential or an OAuth login.

The deny needs the file to exist: pi's credential store writes `{}` to
`auth.json` before its first read (`FileAuthStorageBackend.ensureFileExists`
in `dist/core/auth-storage.js`), so with the file absent and the deny in
place every session dies at start with EPERM on `auth.json`. Create the
empty store (mode 600) outside the sandbox when it is missing.

### 4. mcp.json: user-level MCP servers spawn at startup (high)

Agent-dir `mcp.json` is read with no trust decision (project `.pi/mcp.json`
needs trust; the agent-dir one does not, pi docs/mcp.md), and `command` is an
executable pi spawns.

Proof: a planted mcp.json made a fresh child spawn `/bin/sh -c touch
<marker>` at startup; the session then ran on normally.

Fix: denyWrite `mcp.json` and `mcp-auth.json`.

### 5. trust.json plus project settings plus a project extension: arbitrary code in the next session (high)

Trust decisions live in session-writable `trust.json` as `{abs-path: bool}`
(pi's `trust-manager.ts`); project `.pi/settings.json` loads once trust is
granted, and its `extensions` list names code pi loads in-process.

Proof: planting a `true` decision for this worktree, a project settings.json
naming one extension, and the extension file made the next pi process execute
the extension's module-level side effect (marker), with no prompt shown.

Fix: denyWrite `trust.json`. First-trust grants become an unsandboxed act
(`pi --no-sandbox`), which is the right side of the line for a trust decision
anyway.

### 6. models-store.json: registry poisoning (medium)

The file is read at startup and merged into the live model registry, and
model entries can carry `baseUrl` (a model-level baseUrl takes precedence
over the provider endpoint, pi docs/custom-provider.md).

Proof: an entry appended to a scratch copy of the file, templated off a real
one, appeared in the next child's `--list-models` with attacker-chosen
metadata.

Fix: denyWrite, and run `pi update --models` unsandboxed: pi itself writes
this file at catalog refresh, so the deny has to be paired with that.

### 7. `$PWD/.direnv/bin`: shadows the human's PATH (medium-high)

direnv puts the worktree's `.direnv/bin` first on the PATH it exports, the
directory sits inside the workspace write grant, and direnv's allow hash
covers `.envrc` only, not directory contents, so planting there needs no
re-allow. The human cd's in, direnv loads, and their next `git` runs the
planted shim as the human, unsandboxed.

Proof: a pass-through `git` shim resolved first and executed as the user under
the exact PATH direnv exported at this session's launch.

Fix: add `$PWD/.direnv` to the wrapper's persistence denies, beside
`.git/hooks` and `.gitmodules`.

### 8. `--allow-nix` / `--allow-flake`: daemon-side FOD egress (medium, by design)

Fixed-output derivations keep the network daemon-side; the srt proxy never
sees it, and `grants/nix.md` already says so. One tempting fix does not
work, for the record: `allowed-uris` is evaluator-side and
`restrict-eval`-gated (`EvalState::checkURI` returns immediately unless
restrict-eval is on, and libstore's fetchurl builtin checks no URL at all),
and an attacker owns their own evaluator. There is no daemon-side knob for
an untrusted client on this nix.

Proof: `fetchurl` with a payload-shaped URL was fetched daemon-side (curl
reported the origin's 404) from a host the proxy 403s for the session
directly.

Fix: one line in `grants/flake.md` that the bundle inherits the nix grant and
its daemon-side egress, and a second look at `nix,flake` as a standing
coordinator launch grant. Network-layer containment for `_nixbld` would be
the real fix and is out of scope for a homelab.

### 9. Transcript forgery on resume (medium)

Other projects' transcripts are read-denied, but this project's own
directory is writable (pi records there), and `--session <file>` resumes
whatever the file holds.

Proof: a forged entry appended behind a real session header (mutating a
real message envelope; a hand-built envelope was silently dropped) became
live context: the resume child quoted a codeword that existed only in the
forged line.

Fix: none available in-process; append-only transcripts are an upstream ask.
A session that can rewrite its own record can lie to a later audit.

### 10. Sentry crash telemetry from the nix client (low)

Determinate's nix embeds sentry-native; under the sandbox the crashpad
handler's mach bootstrap is denied, so every nix invocation prints FATAL
crashpad noise while working fine. The endpoint comes from
`NIX_SENTRY_ENDPOINT` or `/etc/nix/sentry-endpoint` unless
`DETSYS_IDS_TELEMETRY=disabled`.

Fix (measured): exporting `NIX_SENTRY_ENDPOINT=` and
`DETSYS_IDS_TELEMETRY=disabled` silences it, noise lines 1 to 0. Worth doing
host-wide: it is crash telemetry to Determinate, the nix-side analogue of
`PI_TELEMETRY=0`.

### 11. The allowlist is an exfil surface (medium)

Every bash child holds the provider key, and the allowlisted hosts are
reachable. `GH_TOKEN` and `GITHUB_TOKEN` are on the wrapper's `pi_keep_env`
survive-list while `github.com` is allowlisted under `flake`, so an inherited
GitHub credential has both the secret and the channel.

Proof (contained): the key's presence was checked and never printed, and an
allowlisted host answered 200. No GitHub token was present in this session.

Fix: gate both tokens like `KAGI_API_KEY` (`envGrantGates`) or drop them from
the keep-list, and treat every allowed domain as a leak boundary.

### Minor, informational

- srt's proxy auth token (in `HTTP_PROXY` and friends) base64-encodes the
  wrapped command line, model seat included, and is visible to every child.
  Each session's proxy port answers only that session, so no cross-session
  use was found.
- secret-guard's documented jq false positive fired on the accessor token
  `.mcloud.key` matching `?*.key`; the split form passes as designed. The
  stem rule is doing its job.

## Bugs the proofs surfaced in this repo

- **stall-guard drops `shellPath` and `shellCommandPrefix`.** It re-registers
  bash from `createBashToolDefinition(process.cwd())`
  (`nix/modules/hm_modules/dev/pi/extensions/stall-guard.ts:213`) with no
  settings, overriding pi's settings-built definition in every
  extension-loading session. Its header comment justifies this with "this
  repo sets neither" (`stall-guard.ts:15`), but home-manager deploys
  `shellPath` (`dev/pi-coding-agent/default.nix:898`, the `/bin/bash` 3.2
  heredoc fix), so the deployed setting is dead in every session that loads
  extensions and the 3.2 heredoc bug it exists to fix is live. Pass the
  settings-built definition through instead of a bare rebuild, and fix the
  comment. Until then it coincidentally masks finding 2 on this host.
- **A headless child without `--model` dies at the proxy.** pi falls back to
  a built-in catalog model whose endpoint is not in this host's allowlist,
  so the child 403s before its first turn. Anything spawning raw pi children
  in-sandbox (pi-delegate-style flows) must pass the seat model explicitly.

## The class fix

Findings 1 through 6 are one class: files under `~/.pi/agent` that a future
session trusts, writable by every session. The wrapper already denies some
(`extensions`, `grants`, `agents`, `skills`, `themes`, `AGENTS.md`,
`models.json`); this audit adds `bin`, `npm`, `mcp.json`, `mcp-auth.json`,
`trust.json`, `auth.json`, and `models-store.json` (with the refresh caveat
in finding 6).

The durable shape is to invert the default: denyWrite the whole agent
directory and allowWrite an explicit set (`sessions/`, `task-logs/`,
`job-logs/`, and `settings.json` under start-time validation). What that
moves out of sandboxed sessions is worth saying plainly, because the wrapper
wraps the human's pi too: `/login`, first-trust grants, `pi install`,
managed-binary downloads and `pi update --models` become unsandboxed acts
(`pi --no-sandbox`). Those are human decisions, which is the right side of
the line for them. Then encode the inventory as a flake-check assertion and
re-run it on every pi bump: pi 1.1.0 changes nothing here (checked), but new
trusted paths arrive over time, and a deny-by-default list turns each into a
refusal instead of a hole.

## Residuals, after the fixes

- Grants that are escapes by definition: `--allow-nix` builds outside the
  sandbox, and the flake bundle inherits it.
- Every allowlisted domain is a leak boundary, and the provider key must
  exist in every session's env.
- Plaintext in the working tree is readable in-tree: srt cannot carve read
  denies inside `$PWD`, so git-crypt files are plaintext in the human's main
  worktree once decrypted. Sessions should not run there; the broker already
  avoids it.
- The coordinator/broker chain audited clean this pass, and remains the
  permanently exposed surface; re-audit on every broker change.
- The shared toolchain caches under `~/.pi/sandbox-cache` are cross-session
  state, verified by ecosystems rather than policy.
- A session can still rewrite its own transcript (finding 9).
- srt's own profile breadth (`SecurityServer`, `securityd.xpc`, unrestricted
  `process-exec`) is upstream's surface; re-verify on every srt bump.
- Linux hosts (bwrap) were not probed: the wrapper-level fixes carry over
  mechanically, the OS-layer claims do not.
- pi's upstream issue tracker was not read (`api.github.com` is not
  allowlisted), so which of these upstream already tracks is unknown.
