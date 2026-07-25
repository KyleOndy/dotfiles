# Dotfiles

Nix flake covering four hosts. Per-host detail lives in
`nix/hosts/<host>/CLAUDE.md`. Grafana dashboard rules live in
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
| `cogsworth` | aarch64-linux  | Raspberry Pi 5 kiosk    | deploy-rs, or `make sdcard-cogsworth` for a fresh image |
| `trex`      | aarch64-darwin | personal mac            | `make deploy-trex`                                      |
| `work-mac`  | aarch64-darwin | work mac (user `kondy`) | `make deploy-mac`                                       |

`make deploy-rs-all-dry` dry-runs both Linux hosts. `make help` lists the rest.

## Secrets

Managed with `sops` (`nix/secrets/secrets.yaml`). Never `.env` files, never
plaintext. The berkeley-mono fonts are git-crypt encrypted, which is why
`git worktree add` fails on a fresh checkout without the key.

## Monitoring

tiger is the server: VictoriaMetrics, Loki, Grafana, Alertmanager, vmalert.
Retention is 400 days for both metrics and logs
(`nix/hosts/tiger/configuration.nix`).

Agents run on tiger, cogsworth and trex: vmagent, promtail, node_exporter.
tiger additionally runs the zfs, jellyfin, exportarr (\*arr plus sabnzbd) and
unpoller exporters.

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

### Adding a dashboard

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

A dashboard showing "No data" is usually one of four things: the exporter is
down (`systemctl status`), vmagent is not scraping it (no job in
`scrapeConfigs`), the query filters on `instance` instead of `host`, or it is
a Loki panel selecting on `job` instead of `unit`. Loki only has two job
values (`systemd-journal`, `darwin-unified-log`), so per-service log queries
must name the unit.

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
