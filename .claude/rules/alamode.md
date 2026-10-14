---
paths:
  - "nix/modules/hm_modules/dev/alamode/**"
  - "nix/pkgs/alamode/**"
  - "nix/pkgs/alamode-runtime/**"
  - "nix/pkgs/alamode-coordinator/**"
  - "nix/pkgs/alamode-seats/**"
  - "nix/pkgs/leak-guard/**"
  - ".pi/**"
---

# alamode

Agents, extensions, grants, themes, `keybindings.json` and `AGENTS.md` live
in `nix/modules/hm_modules/dev/alamode/source/`, symlinked into `~/.pi/agent/`
so `/reload` sees edits without a rebuild. `settings.json` is the exception:
the wrapper writes the deployed copy from `dev/alamode/` over it on every
start, so a `/settings` edit lasts one session. The sandbox wrapper is
`nix/pkgs/alamode` (the runtime is `nix/pkgs/alamode-runtime`),
which records the grants it carries (`--web`, `--allow-nix`, `-forge`,
`-clipboard`, `-trustd`, `-git-write`, each bundle, and the coordinator) in
`ALAMODE_GRANTS` and the ones it could carry in `ALAMODE_AVAILABLE_GRANTS`.
`--allow <host>` hosts, a profile's domains among them, go in
`ALAMODE_ALLOWED_HOSTS`; `--listen` and path grants are not exported.
`extensions/grants.ts` turns the carried ones into system-prompt sections
from `grants/<name>.md` and lists the rest, so a session the sandbox blocks
knows which flag to ask the human for. `/regrant` (`extensions/regrant.ts`)
quits pi with a request; the wrapper asks y/N at the terminal and relaunches
the same session with the new grants (`regrant()` in `session.py`), and
`alamode resume ID GRANTS` does the same from the shell.

Every provider the agent reaches is an internal or account-billed endpoint,
and mcloud is the primary on both macs. Model ids are private, since the org
can reach a model before it is announced, so none appears here in plaintext:
not in files, commit messages, branch names or fixtures. Each mac's whole
`models.json` and its seats are sops secrets, `alamode_models_json` and
`alamode_seats` in `nix/secrets/<host>.yaml`, which sops-nix decrypts to `/run/secrets` at
activation. `modelsJsonFile` links `~/.pi/agent/models.json` there, and the
wrapper grants the sandbox each link on the way plus the file, never the
directory. leak-guard (`nix/pkgs/leak-guard`) refuses a commit message or a
push that names an id or a provider endpoint's host; `leak-guard install`
puts its hooks in a clone.

A seat is one model choice, an env var holding `provider/id[:level]`:
`ALAMODE_SESSION_MODEL`, `ALAMODE_ADVISOR_MODEL`, `ALAMODE_AGENT_MODEL_<NAME>`
per task agent, `ALAMODE_SPAWN_MODEL` for coordinator children,
`ALAMODE_DELEGATE_MODEL` and `ALAMODE_CLASSIFY_MODEL`. The wrapper loads each
from the seats file unless the caller's env sets it, so
`ALAMODE_AGENT_MODEL_CRITIC=<value> alamode` changes one seat for one run.
`alamode-seats get VAR` prints what a seat resolves to. The level
suffix is pi's own, and `--thinking` beats it, so no host passes
`--thinking` in `defaultArgs`.

`trustedProviders` lists the providers allowed to see an id: mcloud, plus
the internal gateways and loopback providers work-config adds. pi refuses to
start a session on any other, and task.ts and the advisor refuse an
untrusted seat through the `ALAMODE_TRUSTED_PROVIDERS` the wrapper exports.
The sandbox reaches each trusted provider's endpoint, the host of its
`baseUrl`, which the wrapper reads from models.json at start, and only
through home-manager's link, since a session can write `~/.pi`. Endpoints
are private too, so this repo lists none in `allowedDomains`.

`alamode --local` keeps a session on the mac. Its `allowed_models` holds
only models whose effective `baseUrl` is loopback, so the relay builds no
route to anything else and pi's `/model` lists nothing else. Seats on any
other model are dropped from the manifest, with one line naming them. It
drops the host's `allowedDomains`, `allowTrustd` and `allowNix` defaults
and refuses `--web`, `--allow`, `--allow-nix`, `--allow-forge`,
`--allow-trustd`, `--allow-clipboard` (Universal Clipboard) and any bundle
with domains, alongside it or through a profile. The policy records it, so
resume and coordinator children keep it. It does not cover
`alamode-delegate` or domestique's classifier, which run on the host, or a
granted path that syncs, such as iCloud Drive.

`alamode --no-PROVIDER`, one flag per trusted provider, drops that
provider's models and every other model whose effective `baseUrl` shares a
`host:port` with one of them, with one line naming those. It does not see
through a gateway on another host that forwards to the provider. Seats on a
dropped model go the way `--local` drops them, the session seat included,
so pi falls back to what is left. The policy records it like `--local`, and
`alamode-delegate --grant=--no-PROVIDER` passes it to a standalone
coordinator. Under either flag a provider left with no model gets no catalog
block, so the relay never holds its key. Neither covers domestique's
classifier, leak-guard's `/models` call or `mcloud-pins`, which run on the
host.

`alamode --local-model PROVIDER/ID` adds a model the catalog lacks, so a
model on trex's mlx server runs without a sops edit or a deploy (`mlx serve
HF_ID` puts it there). The provider must be trusted and the new entry
copies the effective fields of the provider's first model, which must be
on a loopback `baseUrl`. The policy records it, so resume and coordinator
children re-add it before checking the scope digest. Select it with
`-- --model PROVIDER/ID` or a seat.

No key is stored in nix on either mac. trex reads mcloud's from
`/run/secrets/mcloud_api_key`, and work-config resolves work-mac's from the
Keychain, both through the wrapper's `envFromCommands`. models.json reads it
as `$MCLOUD_API_KEY`.

Two seats must not run the session's own model, because self-preference bias
survives a fresh context: the advisor (`extensions/advisor.ts`, off unless the session
starts with `-- --advisor`, and then refusing to start without
`ALAMODE_ADVISOR_MODEL`) and the critic. `alamode-seats check` holds both to that, which
is only a floor: "a different family" is a judgment, written in the seat's
comment. critic.md and vision.md say `seat: required` in their frontmatter,
so an unset seat refuses rather than falling back to the session model, and
vision.md says `needs: image`, so it refuses a model whose catalog entry
takes no images.

`alamode coord` (work-mac and trex, `coordinator.enable`) gives the session
`spawn_agent` and friends (`extensions/coordinator.ts`). Each agent gets its
own worktree, branch and tmux window from `nix/pkgs/alamode-coordinator`,
and a forge instance when the spawn names a size, which only work-mac allows
(`coordinator.forge.enable`). The wrapper starts the daemon outside the
sandbox and it survives the session; agents keep running,
`alamode coord ls` finds them and `alamode coord attach <id>` reattaches.
State is under `~/.local/state/alamode/`, outside `~/.pi` so a child cannot
write the coordinator's requests.

Quitting lands a session's commits in the repository it started from
(`docs/alamode-sessions.md`, Landing): `land()` in
`nix/pkgs/alamode-runtime/session.py` fast-forwards the launch branch or
leaves the commits on `alamode-<id>`. Every outcome at quit goes through
`tell()`: what happened in plain sentences, then the exact next commands. One
that holds work back says what was NOT moved and why. An exit path that
prints nothing, or a bare reason clause, is a bug. At launch the wrapper
cannot print, since pi's fullscreen TUI covers it, so `landing_notice()`
hands pi the same forecast: the header's lands row shows it, and
`extensions/landing-notice.ts` repeats a warning in full.

`.pi/verify.json` names this repo's verifier, which is what `verify-guard`
nags about. Deliberately not `nix flake check`, which also evaluates the
Linux hosts and cannot go green on a mac.

No session can run it on trex. `--allow-nix` never grants the host daemon
socket: the daemon gives a fixed-output derivation the network outside srt's
proxy, so a session with the web off could still send out what it reads.
Under the flag the session's `nix` is a client that submits `build` and
`eval` to a fresh Tart VM (`nix/pkgs/alamode-builder/README.md`), and the
wrapper refuses it on a host without `sandbox.builderConfig`. Only work-mac
sets that, and whether its VM can run the whole verifier is untested; the
README says why trex has none. Run the verifier yourself.

A dead model id fails silently at runtime, so the seats are checked before a
run: `alamode-seats check` at every start, and after every `make deploy-trex`
or `make deploy-mac`, which then runs `mcloud-pins --deploy` against the live
endpoint. That probes each pin for an answer, a declared image input, a
seat's reasoning level and tool calls; `mcloud-pins --context` also fills
each declared context window, which takes minutes. An endpoint that does not
answer at all only warns under `--deploy`. At start only a problem
in the session's own seat (or the advisor's, under `-- --advisor`) stops the run;
the rest warn, and the seat's consumer refuses when used. Every message
names the seat var and what to change, never the value. pi runs a level the
catalog entry does not support at the nearest one it does (no
`"reasoning": true` supports only off; xhigh and max need a
`thinkingLevelMap` entry), so `alamode-seats check` fails a seat whose level
would move. A catalog or seat change is
`sops edit nix/secrets/<host>.yaml` and a deploy. A caller's env override
may name an uncatalogued id and `alamode-seats` only warns, but the relay
refuses it with `403 Model is outside this capability`; on a loopback
provider, `--local-model` admits it. The checks by hand:

```bash
alamode-seats check --start
mcloud-pins
```
