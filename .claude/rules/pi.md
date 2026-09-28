---
paths:
  - "nix/modules/hm_modules/dev/pi/**"
  - "nix/modules/hm_modules/dev/pi-coding-agent/**"
  - "nix/pkgs/pi-wrapper/**"
  - "nix/pkgs/pi-broker/**"
  - ".pi/**"
---

# Pi coding agent

Agents, extensions, grants, themes, `keybindings.json` and `AGENTS.md` live
in `nix/modules/hm_modules/dev/pi/`, symlinked into `~/.pi/agent/` so
`/reload` sees edits without a rebuild. `settings.json` is the exception: it
is copied from `dev/pi-coding-agent/` on each switch. The sandbox wrapper is `nix/pkgs/pi-wrapper`,
which records every carried `--allow-*` grant in `PI_GRANTS` and the full
catalog in `PI_AVAILABLE_GRANTS`; `extensions/grants.ts` turns the carried
ones into system-prompt sections from `grants/<name>.md` and lists the rest,
so a session the sandbox blocks knows which flag to ask the human to restart
with.

Every provider the agent reaches is an internal or account-billed endpoint.
work-mac takes its ids, base URLs, costs and reasoning maps from the private
work-config input, which lands as `~/.pi/agent/models.json`. trex uses pi's
built-in `zai` provider (GLM Coding Plan subscription), so it registers no
modelsJson of its own and gets the real catalog: costs, context windows and
reasoning maps come from pi.

No key is stored in nix on either mac. work-config resolves one from the
Keychain through the wrapper's `envFromCommands`; on trex, `/login zai`
writes it to `~/.pi/agent/auth.json`, which no module owns and the sandbox
can read because the wrapper re-allows `~/.pi`.

Two seats must not run the session's own model, because self-preference bias
survives a fresh context: `extensions/advisor.ts` reads `PI_ADVISOR_MODEL`
and `PI_ADVISOR_BASE_URL` from the wrapper's `sandbox.envVars`, is off
unless pi starts with `--advisor`, and stays silent when either var or
`MCLOUD_API_KEY` is missing, which on trex is always. `agents/critic.md`
carries a `model:` pin in its frontmatter, because `extensions/task.ts` takes
a named agent's model only from that field and otherwise reuses the
session's. `PI_AGENT_MODEL_<NAME>` in `sandbox.envVars` overrides that pin
per host; work-mac sets `PI_AGENT_MODEL_CRITIC` to mcloud's kimi-k2.7-code
so the critic stays off the personal Z.ai plan.

`pi --coordinator` (work-mac, `coordinator.enable`) gives the session
`spawn_agent` and friends (`extensions/coordinator.ts`). Each agent gets its
own worktree, branch, forge instance and tmux window from `nix/pkgs/pi-broker`,
which the wrapper starts outside the sandbox and which exits with the
coordinator; the agents keep running and `pi --coordinator=<id>` reattaches.
State is under `~/.local/state/pi-coord/`, outside `~/.pi` so a child cannot
write the coordinator's requests.

`.pi/verify.json` names this repo's verifier, which is what `verify-guard`
nags about. Deliberately not `nix flake check`, which also evaluates the
Linux hosts and cannot go green on a mac.

It needs the nix daemon socket, which the sandbox denies by default, so the
agent can only run it under `pi --allow-nix`, plus `--allow-flake` when an
input is not in the store yet. What that costs depends on the
daemon: a trusted client can make it build as root, which is equivalent to
`--no-sandbox`, and an untrusted one gets a builder running as `_nixbld`,
still outside the sandbox but not root. The flag asks and says which on
startup. trex answers untrusted (`nix store info --json` reports
`"trusted":false`, from `trusted-users = root` in `/etc/nix/nix.custom.conf`).
work-mac answers trusted (`@admin` in `nix/modules/darwin_modules/base.nix`),
so there it is equivalent to `--no-sandbox`.
Running the verifier yourself is still the cheaper option.

A dead model id fails silently at runtime, so check the pins against their
endpoints rather than waiting for a seat to go quiet. `mcloud-pins` covers
work-config's ids (mcloud, work-mac only); the `critic.md` pin is
`zai/glm-5.3-flash`, checked by listing the zai catalog. The Coding Plan
serves only glm-5.3 and glm-5.3-flash directly, older ids are silently
rerouted to glm-5.3, so a pin that looks different can still be the session
model in disguise:

```bash
MCLOUD_API_KEY=$(security find-generic-password -s work-secrets -a mcloud-inference -w) mcloud-pins  # work-mac only
pi --list-models | grep zai                                                            # trex
```
