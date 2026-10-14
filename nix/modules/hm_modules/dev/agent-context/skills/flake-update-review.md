---
name: flake-update-review
description: Update this repo's flake inputs and report what changed in the packages we actually configure, breaking changes first. Use when asked to update the flake, bump inputs, or review what an update brings.
---

# Flake Update Review

Answers one question after an update: did anything we configure change in a
way that needs attention or is worth adopting. Versions come from evaluation,
not builds, so a snapshot takes seconds per host.

Run everything from the worktree root with `DOTFILES_WORKTREE` exported and
`--impure`, as the Makefile does. Scratch files go in `$TMPDIR`.

## 1. Pre-flight

- `flake.lock` must be clean (`git diff --quiet flake.lock`). If not, stop and
  ask.
- Record `git rev-parse HEAD`.
- Hosts: `darwinConfigurations.{trex,work-mac}`,
  `nixosConfigurations.{tiger,pika,cogsworth}`. cogsworth fetches a private
  input over ssh; if its eval fails for that reason, drop it and say so.

## 2. Snapshot, update, snapshot

For each host, before and after the update:

```bash
nix eval --impure --json ".#<host>" \
  --apply 'import ./nix/lib/package-versions.nix' > "$TMPDIR/fur-<before|after>-<host>.json"
```

Between the two, run the update. `make update` updates everything; if the
user named inputs, `nix flake update <input>...` instead. Keep the
`Updated input` lines for the report. If nothing changed, say so and stop.

## 3. Diff

Per host, list every name whose version changed, appeared or disappeared:

```bash
jq -n --slurpfile a before.json --slurpfile b after.json '
  ($a[0] | keys) + ($b[0] | keys) | unique | map(
    select($a[0][.] != $b[0][.]) | {name: ., old: $a[0][.], new: $b[0][.]})'
```

Merge across hosts into one row per package with the hosts it affects.

## 4. Classify

**Watchlist**, researched when they move (match names case-insensitively):

| Area        | Packages                                                                                      |
| ----------- | --------------------------------------------------------------------------------------------- |
| tiger stack | grafana, VictoriaMetrics, grafana-loki, alertmanager, grafana-alloy, caddy, jellyfin, sabnzbd |
| hosts       | linux, zfs, nix                                                                               |
| daily tools | claude-code, pi, neovim, tmux, alacritty, zsh, starship, git, sops                            |

Anything else with a major-version bump (first number changed, or `0.x` minor
changed) also gets researched. Everything else is listed only.

If a package keeps showing up as a surprise, add it to the watchlist in this
file.

## 5. Research

For each researched package, read the release notes for every version between
old and new: GitHub releases or the project's changelog, fetched directly.
Grep this repo for where we configure it (`git grep -n <name> -- nix`) so the
findings are judged against our settings, not in general.

Per package, report:

- **Security**: every advisory a release in the range fixes, with severity and
  link, or "none"
- **Breaking**: what breaks, and the file and option in this repo it hits, or
  "nothing we use"
- **Worth adopting**: features that change how we would use the tool, skipping
  bug fixes and internals
- **Source**: the release-notes URL

Use subagents only when more than five packages need research, one or two
packages each, returning just the fields above.

## 6. Determinate Nix

trex's nix is Determinate's, installed outside the flake, so it never shows
in the snapshot and no update moves it. The `determinate` input carries only
its nix-darwin module, and the module and the running daemon drift apart.

Run `determinate-nixd version`. If the latest version differs from the
running daemon, or the `determinate` input moved, read the
[nix-src release notes](https://github.com/DeterminateSystems/nix-src/releases)
for every version between the running one and the latest. Report the fields
from step 5, judged against `determinateNix.customSettings` in
`nix/hosts/trex/configuration.nix` and against `docs/darwin-nix-sandbox.md`.

The upgrade needs root, so hand it over rather than running it:
`sudo determinate-nixd upgrade`, then `determinate-nixd version` to confirm
the daemon and client both moved.

## 7. Verify

Run the command in `.pi/verify.json`, which dry-builds both darwin configs
and builds the repo's checks. For
the Linux hosts, a dry run is `make deploy-rs-all-dry`; offer it rather than
running it, since it needs the cogsworth ssh key and takes a while.

## 8. Report and commit

Order: security advisories, build failures, breaking changes, worth adopting,
then the listed-only bumps as a compact table, then the changed inputs. A
Determinate upgrade that is due goes with the advisories.

Ask whether to commit, revert (`git checkout flake.lock`), or leave it. The
commit follows the repo's convention, `feat(sources): update all` (or
`update <input>` for a targeted bump), with the breaking and adopt items in
the body.
