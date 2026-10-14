---
name: ai-update
description: Run make update/ai, then report what the new pi, Claude Code, codex and sandbox-runtime change for this repo's config and alamode's source, from breaking changes to workarounds we can drop and features worth adopting. Use when asked to update the AI tooling or review what a pi or Claude Code bump brings.
---

# AI Tooling Update

`make update/ai` moves two inputs: `llm-agents` (pi, codex, sandbox-runtime)
and `claude-code-nix` (claude-code). This answers what the bump means for how
we configure and build on them, not what the tools do in general. pi and
sandbox-runtime are alamode's engine and sandbox, so either one moving gets a
full pass over alamode's source (step 5).

Nothing gets skipped silently. Every changelog entry ends with a disposition,
every alamode file with a verdict, and the report says how many of each.

Run everything from the worktree root. Scratch files go in `$TMPDIR`. Other
sessions may share this worktree: stage and commit by explicit path only.

## 1. Pre-flight

`flake.lock` must be clean (`git diff --quiet flake.lock`). If not, stop and
ask.

## 2. Snapshot, update, snapshot

Before and after `make update/ai`, record the versions and the pi and
sandbox-runtime store paths (both come from the numtide cache):

```bash
nix eval --impure --json .#darwinConfigurations.trex.pkgs --apply 'p: {
  claude-code = p.claude-code.version;
  pi = p.llm-agents.pi.version;
  codex = p.llm-agents.codex.version;
  sandbox-runtime = p.llm-agents.sandbox-runtime.version;
}' > "$TMPDIR/ai-<before|after>.json"

for t in pi sandbox-runtime; do
  nix build --impure --no-link --print-out-paths ".#darwinConfigurations.trex.pkgs.llm-agents.$t"
done > "$TMPDIR/ai-<before|after>.paths"
```

Keep the `Updated input` lines. If no version moved, say so, revert
`flake.lock` and stop.

## 3. Read the release notes

Every version after the old one, up to and including the new one.

| Tool            | Release notes                                                                                       | Our config                                                                             |
| --------------- | --------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| claude-code     | `gh api repos/anthropics/claude-code/contents/CHANGELOG.md -H 'Accept: application/vnd.github.raw'` | `nix/modules/hm_modules/dev/claude-code/`, `nix/modules/hm_modules/dev/agent-context/` |
| pi              | `libexec/pi/CHANGELOG.md` in the new build                                                          | alamode, step 5                                                                        |
| sandbox-runtime | `gh release view v<version> -R anthropic-experimental/sandbox-runtime`                              | alamode, step 5                                                                        |
| codex           | `gh release view rust-v<version> -R openai/codex`, from `gh release list --exclude-pre-releases`    | `nix/modules/hm_modules/dev/codex/` (work-mac only)                                    |

claude-code-nix trails upstream, so the changelog's top entry is often newer
than what we got. Stop at the version the lock pins.

Changelogs leave things out. For pi, also diff the docs and the extension
examples between the two builds. For sandbox-runtime, diff its type
declarations and README. Each hunk counts as an entry.

```bash
{ read -r OLD_PI; read -r OLD_SRT; } < "$TMPDIR/ai-before.paths"
{ read -r NEW_PI; read -r NEW_SRT; } < "$TMPDIR/ai-after.paths"
diff -ru "$OLD_PI/libexec/pi/docs" "$NEW_PI/libexec/pi/docs" > "$TMPDIR/pi-docs.diff"
diff -ru "$OLD_PI/libexec/pi/examples" "$NEW_PI/libexec/pi/examples" > "$TMPDIR/pi-examples.diff"
srt=lib/node_modules/@anthropic-ai/sandbox-runtime
diff -ru -x node_modules -x vendor -x '*.js' -x '*.map' \
  "$OLD_SRT/$srt" "$NEW_SRT/$srt" > "$TMPDIR/srt.diff"
```

## 4. Judge against our config

Read the config directories above before judging. Give every changelog entry
a disposition, `not us` included, and keep the count. Per tool, report:

- **Breaking**: removed or renamed settings, hook fields, env vars, CLI flags
  or extension APIs we use, and default changes we would notice. Name the file
  and option it hits, or "nothing we use".
- **Workarounds to drop**: every upstream issue cited in our config
  (`git grep -nE '<owner>/<repo>#[0-9]+|github.com/<owner>/<repo>/issues/[0-9]+'`).
  Check each with `gh issue view` and the changelog. A fix in a version we now
  have means the workaround and its comment can go.
- **Pinned claims**: comments and docs that state upstream behavior at a
  version. Re-check each against the new one, and say whether it still holds
  or what changed and what that breaks.
  ```bash
  git grep -nE '(^|[^a-z-])(pi|sandbox-runtime|claude-code|codex)[ -]v?[0-9]+\.[0-9]+|github\.com/(earendil-works/pi|anthropics/claude-code|openai/codex|anthropic-experimental/sandbox-runtime)/blob/' -- nix docs .claude
  ```
- **Worth adopting**: settings, hook events, statusline fields, extension API,
  models or commands that would change how we use the tool, with the setting
  we would add. Skip bug fixes and internals.
- **Also know**: security fixes, model ids added or dropped, anything
  else we should know before deploying.
- **Source**: the release-notes URL, pinned to the version.

When more than one tool moved, research each in its own subagent, returning
only these fields. pi and sandbox-runtime go through step 5 as well.

## 5. Walk alamode

Only when pi or sandbox-runtime moved. Start from the map:
`.claude/rules/alamode.md`, `docs/alamode.md`, `docs/pi-sandbox-audit.md`.
Then take the inventory now, so files added since this skill was written
count:

```bash
git ls-files nix/modules/hm_modules/dev/alamode 'nix/pkgs/alamode*' \
  'nix/checks/alamode*' nix/pkgs/leak-guard nix/pkgs/mcloud-pins \
  'docs/alamode*' docs/pi-sandbox-audit.md .claude/rules/alamode.md
```

Split it into one subagent per area below. Each gets the pi changelog
sections, the three diffs and the sandbox-runtime notes, and reads every file
in its area in full. Tests (`test_*.py`, `nix/checks/alamode*`) go with the
area they test. `alamode/` is `nix/modules/hm_modules/dev/alamode/`; the rest
are under `nix/pkgs/`.

| Area                       | Paths                                                                                                                              | Look for                                                                                                                                                                                                                                                                                                                                                                                  |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Extensions                 | `alamode/source/extensions/`                                                                                                       | Every pi API, event and TUI call they make that was renamed, removed or changed in meaning. They import `@earendil-works/pi-coding-agent` and `pi-ai` types, and nothing typechecks them. Anything pi now ships that an extension builds by hand. New API that does an extension's job better.                                                                                            |
| Agent config               | `alamode/default.nix`, `alamode/settings.json`, the rest of `alamode/source/`                                                      | Settings keys, keybinding actions, theme tokens, agent frontmatter and `models.json` fields that were renamed, removed or given new defaults, and new ones worth setting.                                                                                                                                                                                                                 |
| Session and sandbox        | `nix/pkgs/alamode/`, `alamode-runtime/`, `docs/pi-sandbox-audit.md`, `docs/alamode-sessions.md`                                    | CLI flags the wrapper passes pi. Every file pi now reads from the agent dir or a repo without a trust decision, against `PLANTED_AGENT_NAMES` in `session.py` and `CONTEXT_FILES` and the `TRUST_GATED_*` lists in `workspace.py`; the audit asks for that inventory on every pi bump. New network endpoints, update checks or write paths. sandbox-runtime API and `dist/` path changes. |
| Coordination and inference | `alamode-coordinator/`, `alamode-delegate/`, `alamode-relay/`, `alamode-seats/`, `alamode-builder/`, `leak-guard/`, `mcloud-pins/` | RPC, print-mode and session-format changes. Provider, model and compat-field changes. Model ids added or dropped.                                                                                                                                                                                                                                                                         |

Each subagent returns:

- Every file in its area with a verdict, `unaffected`, `breaks`, `adopt` or
  `simplify`, and a `file:line` and reason for anything but `unaffected`.
- Every changelog entry and diff hunk that touches its area, with the file it
  hits.

Then check coverage. Diff the returned paths against the inventory and send
any missed file back to its area. A changelog entry or hunk no area claimed
gets a disposition from you.

## 6. Verify

Run the command in `.pi/verify.json`. It runs alamode against the real pi, and
`leak-guard` scrapes pi's bundled model ids and fails below 500, so a pi
release that changes their shape breaks it there. If pi or sandbox-runtime
moved, also run `nix run .#alamode-check-native`, since the containment tests
run only on the host.

## 7. Report and commit

Order: verify failures, breaking, workarounds to drop, pinned claims that
changed, worth adopting, simplify, also know, then a table of each tool's old
and new version. Close with coverage: changelog entries and diff hunks read
per tool, how many mattered, and alamode files reviewed out of the inventory.

Ask whether to commit, revert (`git checkout flake.lock`), or leave it. The
commit is `feat(sources): update ai`, with the version moves and the breaking
and adopt items in the body. Do not apply the adopt items in the same commit.
