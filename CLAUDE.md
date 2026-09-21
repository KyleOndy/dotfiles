# Dotfiles

Nix flake covering four hosts. Per-host detail, where it exists, lives in
`nix/hosts/<host>/`. Grafana dashboard rules live in
`nix/modules/nix_modules/monitoring-stack/DASHBOARD_CONVENTIONS.md`.

## Worktrees

The repo is a bare checkout at `/Users/kyle/src/dotfiles/.bare` with one
directory per branch beside it. Resolve every path from the worktree root,
not from `/Users/kyle/src/dotfiles/`:

```bash
git rev-parse --show-toplevel   # /Users/kyle/src/dotfiles/main
```

The flake reads the git tree, so a new file is invisible to `nix eval` and
`nix build` until it is `git add`ed.

## Hosts

| Host        | Platform       | Role                    | Deploy                                                  |
| ----------- | -------------- | ----------------------- | ------------------------------------------------------- |
| `tiger`     | x86_64-linux   | homelab server          | `deploy --skip-checks -- .`                             |
| `pika`      | x86_64-linux   | ODROID-H2, second copy  | deploy-rs, or `make iso-pika` for a fresh install       |
| `cogsworth` | aarch64-linux  | Raspberry Pi 5 kiosk    | deploy-rs, or `make sdcard-cogsworth` for a fresh image |
| `trex`      | aarch64-darwin | personal mac            | `make deploy-trex`                                      |
| `work-mac`  | aarch64-darwin | work mac (user `kondy`) | `make deploy-mac`                                       |

`make deploy-rs-all-dry` dry-runs the Linux hosts. `make help` lists the rest.

pika holds tier 2 of `docs/backup-strategy.md` and opens every connection
itself: tiger holds no credential for it and cannot initiate anything toward
it.

## Secrets

Managed with `sops` (`nix/secrets/secrets.yaml`). Never `.env` files, never
plaintext. The berkeley-mono fonts are git-crypt encrypted, which is why
`git worktree add` fails on a fresh checkout without the key.

`docs/onshape-api.md` records a case where this isn't followed yet:
Onshape API keys, currently handled ad hoc rather than through sops.

## Pi coding agent

Agents, extensions, themes and `AGENTS.md` live in
`nix/modules/hm_modules/dev/pi/`, symlinked into `~/.pi/agent/` so `/reload`
sees edits without a rebuild. The sandbox wrapper is `nix/pkgs/pi-wrapper`.

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
and `PI_ADVISOR_BASE_URL` from the wrapper's `sandbox.envVars` and stays
silent when either is unset. `agents/critic.md` still carries a
`model:` pin in its frontmatter, because pi resolves a subagent's model only
from that field and the `agents/` directory is symlinked out of this repo.

`.pi/verify.json` names this repo's verifier, which is what `verify-guard`
nags about. Deliberately not `nix flake check`, which also evaluates the
Linux hosts and cannot go green on a mac.

It needs the nix daemon socket, which the sandbox denies by default, so the
agent can only run it under `pi --allow-nix`. What that costs depends on the
daemon: a trusted client can make it build as root, which is equivalent to
`--no-sandbox`, and an untrusted one gets a builder running as `_nixbld`,
still outside the sandbox but not root. The flag asks and says which on
startup. trex answers untrusted (`nix store info --json` reports
`"trusted":false`, from `trusted-users = root` in `/etc/nix/nix.custom.conf`).
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
kiosk app at `/api/metrics`; pika exports zfs, smartctl and the S3 archive
counters through the textfile collector.

Every UI is `<name>.tiger.infra.ondy.org`, served by Caddy off a wildcard
cert. Grafana, Loki, metrics and vmalert also have `<name>.apps.ondy.org`
public aliases with individual Route53 DNS-01 certs; Alertmanager
deliberately does not.

### Label naming: `host`, not `instance`

`instance` renders as `127.0.0.1:9100`; `host` renders as `tiger`. Every
scrape config must set a `host` label, and every dashboard query must filter
on it. Full rules and the migration one-liners for imported dashboards are in
`DASHBOARD_CONVENTIONS.md`.

### Authentication

Caddy protects the VictoriaMetrics write endpoints, the Loki push endpoint,
and the whole vmalert and Alertmanager UIs with HTTP basic auth. Those two
UIs are not read-only: they create and expire silences.

tiger sets `monitoringStack.monitoringBasicAuth` to a sops secret holding
`username bcrypt-hash` lines (sops key `monitoring_basicauth`); Caddy checks
it per site via `basicAuthPaths` in
`nix/modules/nix_modules/caddyReverseProxy.nix`. Remote agents on cogsworth
and trex send the matching credentials from sops key `monitoring_password`.

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
2. Add it to the `imports` list in `monitoring-stack/default.nix`.
3. Add a scrape job in the host's `vmagent.scrapeConfigs`, with
   `labels.host = "<hostname>"`.

### Dashboards

Seven, each the investigation surface for one or more alert groups. A
dashboard nothing can send you to does not earn its place:

| Dashboard                 | Alert groups it serves                                                         |
| ------------------------- | ------------------------------------------------------------------------------ |
| `Hosts`                   | resource_usage, host_availability, disk_space, systemd_health                  |
| `Storage and Data Safety` | zfs_storage, backup_replication, offsite_archive, windows_backup, drive_health |
| `Media`                   | media_services_tiger, arr_queue_health, ytdl_sub, JellyfinDown                 |
| `Cogsworth`               | cogsworth_monitoring                                                           |
| `Caddy Reverse Proxy`     | none yet, reads Loki                                                           |
| `UniFi Network`           | unifi                                                                          |
| `Monitoring Stack Health` | monitoring_stack                                                               |

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
multi-line forms. `clj-paren-repair-claude-hook` fires on every Edit/Write
and fixes unbalanced delimiters plus cljfmt formatting; nothing to invoke by
hand.

## References

- [VictoriaMetrics](https://docs.victoriametrics.com/)
- [LogQL](https://grafana.com/docs/loki/latest/query/)
- [PromQL cheat sheet](https://promlabs.com/promql-cheat-sheet/)
