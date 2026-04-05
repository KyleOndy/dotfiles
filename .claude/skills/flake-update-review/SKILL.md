---
name: flake-update-review
description: Update all flake inputs, build all deploy targets, diff closures across hosts, and research package changes before committing
disable-model-invocation: true
---

# Flake Update Review

Update all flake inputs, build every deploy target, diff the closures, and research
what changed before committing. The goal is a clear picture of what's being upgraded
and whether anything needs attention.

Hosts: dino (x86_64), wolf (x86_64), elk (x86_64), cogsworth (aarch64).

## Phase 0: Pre-flight

1. Run `git status --porcelain` to check for uncommitted changes. If dirty, warn the
   user and use AskUserQuestion to ask whether to proceed or stash first.
2. Record the current HEAD: `git rev-parse HEAD` (save as OLD_COMMIT).
3. Verify worktree root: `git rev-parse --show-toplevel`.

## Phase 1: Capture pre-update store paths

Before updating anything, build each host's current toplevel and record the store path.
These should be fast if the user has deployed recently (already in the nix store).

For each host in `dino wolf elk cogsworth`, run:

```
nix build --no-link --print-out-paths \
  .#nixosConfigurations.<host>.config.system.build.toplevel
```

Save the output (a `/nix/store/...` path) for each host. These are the "old" paths.

Run all four builds. If a build fails (unlikely for the current committed state), note
it and continue.

## Phase 2: Update flake inputs

Run `make update` and capture its output. The `nix flake update` output shows which
inputs changed:

```
* Updated input 'nixpkgs':
    github:nixos/nixpkgs/abc123 (2026-03-15)
  -> github:nixos/nixpkgs/def456 (2026-04-01)
```

Parse this output and present a summary to the user:

- Which inputs changed
- How many days/commits between old and new

If nothing changed, tell the user and stop.

**Checkpoint**: Use AskUserQuestion to ask: "N inputs changed. Proceed to build all
hosts?" Options: "Yes, build all 4 hosts" / "Stop here (revert with git checkout flake.lock)".

## Phase 3: Build post-update state

Run `make deploy-rs-all-dry` to verify everything builds. This runs `nix flake check -L`
and then `deploy --skip-checks --dry-activate .`.

This is a long-running command. Run it and wait for completion.

After it succeeds, build each host's new toplevel and record the store paths:

```
nix build --no-link --print-out-paths \
  .#nixosConfigurations.<host>.config.system.build.toplevel
```

These are the "new" paths. If a host fails to build, report the Nix error output and
continue with the other hosts.

## Phase 4: Diff closures

For each host where both old and new paths exist, run:

```
nix store diff-closures <old-path> <new-path>
```

The output looks like:

```
packageName: 1.2.3 -> 1.3.0, +0.5 MiB
otherPackage: 2.0.0 -> 2.1.0, -0.1 MiB
```

Parse each line into: `{package, old_version, new_version, size_delta}`.

Then deduplicate across hosts. Create a unified list of unique version bumps:
`{package, old_version, new_version, hosts: ["dino", "wolf", ...]}`.

If there are no version changes across any host, report "no package changes" and
skip to the commit checkpoint.

## Phase 5: Classify packages

Split the deduplicated bump list into two tiers:

**Tier 1 (deep research)**: Packages the user explicitly configures. Identify these by
grepping the NixOS and home-manager configuration files for each package name:

```
grep -rl '<package-name>' nix/hosts/ nix/modules/ nix/profiles/ --include='*.nix'
```

If a package name appears in any `.nix` config file, it's Tier 1.

**Tier 2 (list only)**: Everything else. Transitive dependencies, libraries, build
tooling. These just go in a summary table.

Present the classification to the user before researching:

- "Found N unique version bumps. M are Tier 1 (user-configured), K are Tier 2 (transitive)."
- List the Tier 1 packages so the user can see what will be researched.

## Phase 6: Deep research (subagents)

For each Tier 1 package, spawn a subagent (Agent tool, general-purpose type) to do
a deep dive. Batch 1-2 packages per subagent. Launch up to 5 subagents in parallel.

### Subagent prompt template

Use this prompt for each research subagent, filling in the variables:

```
Research the changes in {PACKAGE_NAME} between version {OLD_VERSION} and {NEW_VERSION}.

This package is used on these NixOS hosts: {HOSTS}

It appears in the user's NixOS configuration in these files:
{GREP_RESULTS}

Your task:
1. WebSearch for "{PACKAGE_NAME} {NEW_VERSION} changelog" or "{PACKAGE_NAME} release notes"
2. WebFetch the changelog/release notes page and read through it
3. Based on the changelog and the user's config shown above, determine:
   - Are there breaking changes that affect the config?
   - Are there security fixes (CVEs)?
   - Are there new features worth knowing about?
   - Does the user's config need any changes?

Return your findings in EXACTLY this format (no other text):

## {PACKAGE_NAME}: {OLD_VERSION} -> {NEW_VERSION}
**Hosts**: {comma-separated list}
**Impact**: low|medium|high
**Breaking changes**: none / description of what breaks
**Security**: none known / CVE-XXXX-YYYY: description
**Config changes needed**: none / description of what to change and where
**New features**: none notable / brief description
**Changelog**: URL to the changelog or release notes
```

### Collecting results

After all subagents complete, collect their structured summaries. These are the only
research results that enter the main context. The raw web content stays in the subagents.

## Phase 7: Report

Present the full report as markdown in the conversation:

```markdown
# Flake Update Review

## Inputs Changed

- **nixpkgs**: abc123 -> def456 (17 days newer)
- **home-manager**: ...
- ...

## Tier 1: User-Configured Packages (N packages)

[Insert each subagent's structured summary here]

## Tier 2: Transitive Dependencies (K packages)

| Package | Old | New | Size | Hosts |
| ------- | --- | --- | ---- | ----- |
| ...     | ... | ... | ...  | ...   |

## Build Failures

[List any hosts that failed to build, or "None"]

## Summary

- N total version bumps across 4 hosts
- M packages need attention (high/medium impact)
- Config changes needed: [yes, list them / none]
```

**Checkpoint**: Use AskUserQuestion to ask: "What would you like to do with the
flake.lock update?" Options:

- "Commit the update"
- "Revert (git checkout flake.lock)"
- "I'll handle it manually"

If the user chooses to commit, create a commit with:

- Subject: `chore(flake): update flake inputs`
- Body: summary of inputs changed and notable package bumps

## Error handling

- If `make update` fails, report the error and stop.
- If `make deploy-rs-all-dry` fails, report which host failed and why. Ask the user
  whether to continue with the hosts that did build or stop entirely.
- If a `nix store diff-closures` call fails, skip that host's diff and note it.
- If a research subagent fails or times out, note the package as "research failed"
  and continue.
- If `git status` shows the tree is dirty at the start, do NOT proceed without user
  confirmation.

## Important notes

- The pre-update builds (Phase 1) MUST complete before running `make update` (Phase 2).
  The whole point is to capture the "before" state.
- `nix store diff-closures` only shows packages where the version string changed.
  Hash-only rebuilds (same version, different derivation) are not shown. This is the
  desired behavior; those are noise.
- cogsworth is aarch64-linux. It may take longer to build than the x86_64 hosts.
  Do not skip it.
- The Makefile is at the worktree root. Always run make commands from there.
