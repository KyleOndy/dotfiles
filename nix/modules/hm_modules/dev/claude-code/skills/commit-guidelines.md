---
name: commit-guidelines
description: Commit message quality standards — applies when writing git commits, amending commits, rewording during rebase, or squashing commits
---

# Commit Message Guidelines

These standards apply to every git history-writing operation:
`git commit`, `git commit --amend`, interactive rebase reword/squash, or any other operation where Claude authors or rewrites a commit message.

## Precedence: Repo-Local Conventions Override Formatting Defaults

Before applying the formatting rules below, check for established conventions in the current repo:

1. **Recent history**: Run `git log --oneline -20`. If the commits consistently follow a different format (e.g., no scope, different types, capitalized descriptions, plain prose subjects), match that format.
2. **PR template**: Check for `pull_request_template.md` or `.github/pull_request_template.md`. If it implies a commit or PR message structure, follow it.

If either source reveals an established convention, **use that convention for all cosmetic/formatting decisions** — subject line style, whether scope is required, type prefix names, etc.

**Always apply regardless of repo conventions:**

- The **why rule** (body explains motivation, not the diff)
- The **receipts rule** (claims need evidence)
- The **anti-patterns** (no filler, no Co-Authored-By, no emoji in subjects)

When in doubt, the formatting rules below are the fallback.

## Subject Line

Format: `type(scope): description`

- **Type**: `feat`, `fix`, `refactor`, `chore`, `docs`, `test`, `perf`
- **Scope**: always present; use the module, host, or subsystem (e.g. `claude-code`, `tiger`, `cogsworth`, `monitoring`)
- **Description**: imperative mood, lowercase, no trailing period
- **Length**: 50 characters max (hard limit: 72)

## Body

**Required** for everything except trivial one-liners (version bumps, typo fixes, single-line config changes).

The diff shows **what** changed. The body explains **why**:

- What problem or gap motivated the change?
- What decision was made and why this approach over alternatives?
- What was observed before, and what should be observed after?

Wrap at 72 characters. Separate from subject with a blank line.

Commit bodies follow the voice rules in the personal-prose skill (no
leverage/robust/comprehensive/seamless, no em dashes, no emojis).

Use markdown formatting in the body: triple-backtick fenced code blocks
for command output or code snippets, single backticks for inline code
references.

## Receipts Rule

Every non-trivial claim in the body needs at least one piece of evidence:

- Error messages or stack traces that prompted the fix
- Command output showing the before/after behavior (`$ foo` → `bar`)
- Version-pinned doc links (GitHub permalink, versioned URL with `#anchor`)
- References to issues, PRs, or discussion threads
- Specific file paths and line numbers where the problem lived

No evidence = the claim is just an assertion. Show the receipts.

## Anti-Patterns

- No kitchen-sink commits; keep each commit atomic and focused
- No `Co-Authored-By` trailers
- No emoji in subject lines
- No restating the diff in prose ("adds X field to Y struct")
- No filler ("various improvements", "minor fixes", "updates")
- No future tense ("will fix") — describe the state after the commit

## Examples

### Feature with motivation

```
feat(claude-code): add commit-guidelines skill

The commit-smart command only fired when explicitly invoked via
/git:commit-smart. Organic commits during work had no guardrails
for capturing the "why" or linking to evidence.

Skills load automatically when their trigger matches, so converting
to a skill means every Claude-authored commit follows the same
standards without any user invocation.

Removes: commands/git/commit-smart.md (superseded by this skill)
```

### Fix with receipts

```
fix(cogsworth): increase watchdog failure threshold to 5

Cogsworth was restarting during normal startup — the Java process
takes ~45s to bind port 8080 on cold boot, but the health check
timeout was 30s (3 × 10s intervals).

Observed: `journalctl -u cogsworth-watchdog` showed "WATCHDOG
TRIGGERED" within 90s of every deploy, before the app was ready.

Threshold raised from 3 to 5 (150s window), matching the measured
worst-case startup time of 120s under memory pressure.
```

### Chore — body skippable

```
chore(source): update claude-code to 2.1.82
```
