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

Snapshot every host before and after the update, with `<when>` set to
`before` or `after`:

```bash
for h in darwinConfigurations.{trex,work-mac} nixosConfigurations.{tiger,pika,cogsworth}; do
  nix eval --impure --json ".#$h" --apply 'import ./nix/lib/package-versions.nix' \
    > "$TMPDIR/fur-<when>-${h#*.}.json" || echo "${h#*.} failed"
done
```

Between the two, run the update with its output in `$TMPDIR/fur-update.log`.
`make update` updates everything; if the user named inputs,
`nix flake update <input>...` instead. Each `Updated input` entry is three
lines, the name, the old ref and the new one, so `grep -A2 'Updated input'`
pulls them for the report. `work-config` is a path input and shows up on every
run unchanged. If nothing else changed, say so and stop.

Right after the second snapshot, start step 7's verify in the background. It
takes around 20 minutes, and steps 3 through 6 fit inside it.

## 3. Diff

List every name whose version changed, appeared or disappeared, one row per
package with the hosts it affects. Leave out a host whose snapshot failed.

```bash
for h in trex work-mac tiger pika cogsworth; do
  jq -n --arg h "$h" --slurpfile a "$TMPDIR/fur-before-$h.json" \
    --slurpfile b "$TMPDIR/fur-after-$h.json" '
    ($a[0] | keys) + ($b[0] | keys) | unique | map(
      select($a[0][.] != $b[0][.]) | {name: ., old: $a[0][.], new: $b[0][.], host: $h})'
done | jq -s 'add | group_by(.name, .old, .new)
  | map({name: .[0].name, old: .[0].old, new: .[0].new, hosts: (map(.host) | join(","))})'
```

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
old and new. Grep this repo for where we configure it
(`git grep -n <name> -- nix`) so the findings are judged against our settings,
not in general.

Fetch the notes as raw text. WebFetch hands back a summary of a GitHub
releases page and nothing at all from a rendered `CHANGELOG.md`.

- **GitHub releases**: `gh api repos/<owner>/<repo>/releases/tags/<tag> --jq .body`
- **Changelog files**: the `raw.githubusercontent.com` URL, cut to the range
- **linux**: skip the notes for a bump inside a stable series. Each point
  release is hundreds of commits with no advisories, since the kernel CNA
  assigns CVEs only after a fix lands in a stable tree
  ([process](https://www.kernel.org/doc/html/v6.18/process/cve.html#process)).
  What can break us is zfs, which step 7 checks.

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

Run `determinate-nixd version`. Read the
[nix-src release notes](https://github.com/DeterminateSystems/nix-src/releases)
for every release newer than the running daemon, plus the releases the
`determinate` input moved across. If both sets are empty, skip the rest of
this step and say so. Report the fields from step 5, judged against
`determinateNix.customSettings` in `nix/hosts/trex/configuration.nix` and
against `docs/darwin-nix-sandbox.md`.

When those notes fix Nix advisories, check what every other host runs with
`ssh <host> nix --version`. The snapshot shows the version a config pins, not
the one deployed. Report a host you cannot reach as unchecked.

The upgrade needs root, so hand it over rather than running it:
`sudo determinate-nixd upgrade`, then `determinate-nixd version` to confirm
the daemon and client both moved.

## 7. Verify

The command in `.pi/verify.json`, started back in step 2, builds both darwin
closures and the repo's checks. It builds nothing for the Linux hosts, so two
breakages it cannot see get their own builds:

- **caddy moved**: `caddy.withPlugins` in
  `nix/modules/nix_modules/caddyReverseProxy.nix` pins a hash of caddy's
  vendored modules, and a new caddy version changes them. Build it on the
  tiger builder (about a minute). A hash mismatch prints the hash to paste in.

  ```bash
  nix build --impure --no-link '.#nixosConfigurations.tiger.config.services.caddy.package'
  ```

- **linux moved**: check whether Hydra built the zfs module against the new
  kernel. `will be fetched` means it did. `will be built` is a deploy risk, so
  build it.

  ```bash
  nix build --impure --dry-run \
    '.#nixosConfigurations.tiger.config.boot.zfs.modulePackage' \
    '.#nixosConfigurations.pika.config.boot.zfs.modulePackage'
  ```

For a full Linux dry run, offer `make deploy-rs-all-dry` rather than running
it, since it needs the cogsworth ssh key and takes a while.

## 8. Report and commit

Order: security advisories, build failures, breaking changes, worth adopting,
then the listed-only bumps as a compact table, then the changed inputs. A
Determinate upgrade that is due goes with the advisories.

Ask whether to commit, revert (`git checkout flake.lock`), or leave it. The
commit follows the repo's convention, `feat(sources): update all` (or
`update <input>` for a targeted bump), with the breaking and adopt items in
the body.
