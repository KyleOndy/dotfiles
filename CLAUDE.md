# Dotfiles

Nix flake covering five hosts. Per-host detail, where it exists, lives in
`nix/hosts/<host>/`. Grafana dashboard rules live in
`nix/modules/nix_modules/monitoring-stack/DASHBOARD_CONVENTIONS.md`.

## Worktrees

The repo is a bare checkout with one directory per branch beside its
`.bare`: `/Users/kyle/src/dotfiles/` on trex, `/Users/kondy/src/kyleondy/dotfiles/`
on work-mac. Resolve every path from the worktree root, not from that parent:

```bash
git rev-parse --show-toplevel   # trex: /Users/kyle/src/dotfiles/main
```

The flake reads the git tree, so a new file is invisible to `nix eval` and
`nix build` until it is `git add`ed.

Build and deploy through `make`. It exports `DOTFILES_WORKTREE` and passes
`--impure`, and without both, pi-coding-agent's `sourceDir` throws on every
host that enables it (all but pika and cogsworth).

## Hosts

| Host        | Platform       | Role                    | Deploy                                                  |
| ----------- | -------------- | ----------------------- | ------------------------------------------------------- |
| `tiger`     | x86_64-linux   | homelab server          | `make deploy-rs HOSTNAME=tiger`                         |
| `pika`      | x86_64-linux   | ODROID-H2, second copy  | deploy-rs, or `make iso-pika` for a fresh install       |
| `cogsworth` | aarch64-linux  | Raspberry Pi 5 kiosk    | deploy-rs, or `make sdcard-cogsworth` for a fresh image |
| `trex`      | aarch64-darwin | personal mac            | `make deploy-trex`                                      |
| `work-mac`  | aarch64-darwin | work mac (user `kondy`) | `make deploy-mac`                                       |

`make deploy-rs HOSTNAME=<host>` lets deploy-rs run its own `nix flake check`
first, which fetches the private cogsworth input, so it needs that ssh key.
`make deploy-rs-all-dry` runs `nix flake check`, then dry-activates tiger,
pika and cogsworth. `make help` lists only the targets marked `##`, which
leaves out the `deploy-rs*` ones.

pika holds tier 2 of `docs/backup-strategy.md` and opens every connection
itself: tiger holds no credential for it and cannot initiate anything toward
it.

## Secrets

Managed with `sops` (`nix/secrets/secrets.yaml`). Never `.env` files, never
plaintext. The berkeley-mono and pragmata-pro fonts and the `tf/` state are
git-crypt encrypted. The key lives per worktree
(`.bare/worktrees/<name>/git-crypt/keys/`) and the filter is marked required,
so every `git worktree add` fails until the key is copied into the new
worktree's git dir.

`docs/onshape-api.md` records a case where this isn't followed yet:
Onshape API keys, currently handled ad hoc rather than through sops.

## Pi coding agent

Agents, extensions, grants, themes, `keybindings.json` and `AGENTS.md` live
in `nix/modules/hm_modules/dev/pi/`, symlinked into `~/.pi/agent/` so
`/reload` sees edits without a rebuild. `settings.json` is the exception: it
is copied from `dev/pi-coding-agent/` on each switch. The sandbox wrapper is `nix/pkgs/pi-wrapper`,
which records every carried `--allow-*` grant in `PI_GRANTS` and the full
catalog in `PI_AVAILABLE_GRANTS`; `extensions/grants.ts` turns the carried
ones into system-prompt sections from `grants/<name>.md` and lists the rest,
so a session the sandbox blocks knows which flag to ask the human to restart
with.
The `pi-usage` extension (Z.ai quota in the footer, `/usage` command) is the
one pi resource not from there: a third-party pi package from the `pi-usage`
flake input, symlinked to `~/.pi/agent/packages/pi-usage` and registered in
the module's `settings.json`; `make update/pi-usage` moves the pin.

Every provider the agent reaches is an internal or account-billed endpoint.
work-mac takes its ids, base URLs, costs and reasoning maps from the private
work-config input, which lands as `~/.pi/agent/models.json`. trex uses pi's
built-in `zai` provider (GLM Coding Plan subscription), so it registers no
modelsJson of its own and gets the real catalog: costs, context windows and
reasoning maps come from pi.

No key is stored in nix on either mac. work-config resolves one from the
Keychain through the wrapper's `envFromCommands`; on trex, `/login zai`
writes it to `~/.pi/agent/auth.json`, which no module owns and the sandbox
can read because the wrapper re-allows `~/.pi`. sops still carries the
now-orphaned `trex_mcloud_api_key` from the retired mcloud setup.

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

## Monitoring

tiger is the server: VictoriaMetrics, Loki, Grafana, Alertmanager, vmalert.
Retention is 400 days for both metrics and logs
(`nix/hosts/tiger/configuration.nix`).

Agents run on tiger, pika, cogsworth and trex: vmagent, promtail,
node_exporter. tiger additionally runs the zfs, jellyfin, exportarr (\*arr plus
sabnzbd) and unpoller exporters, and scrapes its own stack (VictoriaMetrics,
vmagent, vmalert, Alertmanager, Loki, promtail, Grafana). cogsworth exposes the
kiosk app at `/api/metrics`. pika runs zfs_exporter, and exports smartctl
health, ZFS scrub and snapshot age, and the S3 archive counters through the
textfile collector.

Every UI is `<name>.tiger.infra.ondy.org`, served by Caddy off a wildcard
cert. Grafana, Loki, metrics and vmalert also have `<name>.apps.ondy.org`
public aliases with individual Route53 DNS-01 certs; Alertmanager
deliberately does not.

### Label naming: `host`, not `instance`

`instance` renders as `127.0.0.1:9100`; `host` renders as `tiger`. Every
scrape config must set a `host` label, and every dashboard query that can span
hosts must filter on it (single-source panels like UniFi and the monitoring
stack's own metrics do not). Full rules and the migration one-liners for imported dashboards are in
`DASHBOARD_CONVENTIONS.md`.

### Authentication

Caddy protects the VictoriaMetrics write endpoints, the Loki push endpoint,
and the whole vmalert and Alertmanager UIs with HTTP basic auth. Those two
UIs are not read-only: they create and expire silences.

tiger sets `monitoringStack.monitoringBasicAuth` to a sops secret holding
`username bcrypt-hash` lines (sops key `monitoring_basicauth`); Caddy checks
it per site via `basicAuthPaths` in
`nix/modules/nix_modules/caddyReverseProxy.nix`. Remote agents on pika,
cogsworth and trex send the matching credentials from sops key
`monitoring_password`.

Loopback callers bypass all of this: vmalert's notifier and tiger's upssched
dispatcher post to `127.0.0.1:9093` directly.

Caddy terminates TLS and provisions its own certs, so `security.acme` is not
involved.

### SMTP

One MXRoute account at `london.mxroute.com:587` sends as
`monitoring@ondy.org` to `kyle@ondy.org`, shared by Alertmanager and
Grafana (`monitoring-stack/default.nix`, sops key
`monitoring_smtp_password`). MXRoute uses server-specific hostnames, so keep
this in step with `nix/modules/hm_modules/terminal/email.nix`; check
`dig ondy.org MX +short` if the provider changes.

### Adding an exporter

1. Write `monitoring-stack/<name>.nix` with options under
   `systemFoundry.monitoringStack.<name>`, gated on
   `mkIf (parentCfg.enable && cfg.enable)`.
2. Nothing to register: `flake.nix` imports every `.nix` under
   `nix/modules/nix_modules/`.
3. Add a scrape job in the host's `vmagent.scrapeConfigs`, with
   `labels.host = "<hostname>"`.

### Dashboards

Seven, each the investigation surface for one or more alert groups. A
dashboard nothing can send you to does not earn its place:

| Dashboard                 | Alert groups it serves                                                         |
| ------------------------- | ------------------------------------------------------------------------------ |
| `Hosts`                   | resource_usage, host_availability, disk_space, systemd_health                  |
| `Storage and Data Safety` | zfs_storage, backup_replication, offsite_archive, windows_backup, drive_health |
| `Media`                   | media_services_tiger, arr_queue_health, ytdl_sub, ytdl_sub_logs (Loki)         |
| `Cogsworth`               | cogsworth_monitoring                                                           |
| `Caddy Reverse Proxy`     | none yet, reads Loki                                                           |
| `UniFi Network`           | unifi                                                                          |
| `Monitoring Stack Health` | monitoring_stack                                                               |

JellyfinDown is an alert in systemd_health rather than a group of its own.
textfile_collector, audio_language and Loki's ruler_heartbeat have no
dashboard yet.

Drop the JSON in `monitoring-stack/dashboards/<folder>/` and fix its label
references per `DASHBOARD_CONVENTIONS.md`. That is the whole procedure:
`grafana.nix` walks the directory with `listFilesRecursive`, and the
subdirectory becomes the Grafana folder. Grafana reloads every 10 seconds.

### Silences

`silence-host` (`nix/modules/hm_modules/dev/monitoring.nix`) silences every
alert for one host:

```bash
silence-host cogsworth "7 days" "Maintenance window"
```

Duration is anything `date -d` accepts. For narrower matchers, use the
Alertmanager UI.

### Queries

```bash
# metrics
ssh tiger 'curl -s "http://127.0.0.1:8428/api/v1/query?query=up" | jq .'
ssh tiger 'curl -s "http://127.0.0.1:8428/api/v1/label/host/values" | jq .'

# alerts: vmalert is what fires, alertmanager is what routes
ssh tiger 'curl -s http://127.0.0.1:8880/api/v1/alerts | jq .'
ssh tiger 'curl -s http://127.0.0.1:9093/api/v2/alerts | jq .'
```

A dashboard showing "No data" is usually one of five things: the exporter is
down (`systemctl status`), vmagent is not scraping it (no job in
`scrapeConfigs`), the query filters on `instance` instead of `host`, the
metric name never existed, or it is a Loki panel selecting on `job` instead of
`unit`. Loki has three job values (`systemd-journal`, `darwin-unified-log`,
`caddy-access`), so per-service log queries must name the unit.

Before writing a panel, prove the query returns rows:

```bash
ssh tiger 'curl -sG --data-urlencode "query=<promql>" \
  http://127.0.0.1:8428/api/v1/query | jq ".data.result | length"'
```

A `0` here is a panel that will ship broken. `scrape_samples_scraped == 0`
finds the nastier version, where the endpoint answers and parses to nothing
while `up` still reads 1; `ScrapeReturnedNoSamples` alerts on it.

## Clojure

`clojure -M:nrepl` starts an nREPL on port 7888. `clj-nrepl-eval -p 7888
'(+ 1 1)'` evaluates against it statelessly, and takes a heredoc for
multi-line forms. It and `clj-paren-repair` are on PATH only inside this
repo's devShell (`.envrc`). No hook config registers
`clj-paren-repair-claude-hook`, so nothing repairs delimiters after an edit;
run `clj-paren-repair <file>` by hand.

## References

- [VictoriaMetrics](https://docs.victoriametrics.com/)
- [LogQL](https://grafana.com/docs/loki/latest/query/)
- [PromQL cheat sheet](https://promlabs.com/promql-cheat-sheet/)
