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
which records the named grants it carries (`--allow-nix`, `-ssh-agent`, `-forge`, `-clipboard`, each bundle, and the
coordinator) in `ALAMODE_GRANTS` and the full catalog in
`ALAMODE_AVAILABLE_GRANTS`. `--allow <host>`
would go in `ALAMODE_ALLOWED_HOSTS`, which nothing exports today. Path grants,
`--allow-loopback`, `--allow-trustd` and `--allow-git-write` are not
recorded; `extensions/grants.ts` turns the carried
ones into system-prompt sections from `grants/<name>.md` and lists the rest,
so a session the sandbox blocks knows which flag to ask the human to restart
with.

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

`.pi/verify.json` names this repo's verifier, which is what `verify-guard`
nags about. Deliberately not `nix flake check`, which also evaluates the
Linux hosts and cannot go green on a mac.

It needs the nix daemon socket, which the sandbox denies by default, so the
agent can only run it under `alamode --allow-nix`, or `--allow-flake`, which
carries `--allow-nix` and adds the hosts for an input not in the store yet.
What that costs depends on the
daemon: a trusted client can make it build as root, which is equivalent to
`--no-sandbox`, and an untrusted one gets a builder running as `_nixbld`,
still outside the sandbox but not root. The flag asks and says which on
startup. Both macs answer untrusted (`nix store info --json` reports
`"trusted":false`): trex from `trusted-users = root` in
`/etc/nix/nix.custom.conf`, work-mac from the same list in
`nix/modules/darwin_modules/base.nix`, which also turns the daemon's build
sandbox on. Running the verifier yourself is still the cheaper option.

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
`sops edit nix/secrets/<host>.yaml` and a deploy; trying a model needs
neither, since a caller's env override may name an uncatalogued id and only
warns:

```bash
alamode-seats check --start
mcloud-pins
```
