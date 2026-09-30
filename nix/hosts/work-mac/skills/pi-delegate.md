---
name: pi-delegate
description: Hand a well-defined, self-contained job to glm-5.3 on mcloud through a headless pi run, to save Claude tokens. Use for lookups and summaries that mean reading many files, and for mechanical edits with a clear definition of done. Not for design calls, work that needs this conversation's context, or anything touching secrets.
---

# Delegating to pi

`pi-delegate` runs one pi session on `mcloud/zai-org/glm-5.3` and streams
back one line per tool call, then the outcome. The run's own reading never
reaches this context, only what it reports.

## When it pays

Delegate when the reading is large and the answer is small: "which hosts
set X, with file:line", "summarize what each of these 12 files does", "rename
this option everywhere and fix the callers". Keep it here when the job needs
judgment, this conversation's context, or fewer than a handful of reads,
since writing the brief costs about as much as doing it.

## The brief

glm sees none of this conversation. The brief is its whole world:

- The goal, and the paths to start from.
- What done looks like, and the output shape with a length cap ("max 10
  lines", "a table of file:line and value").
- What to leave alone. For edits, say whether it may commit.
- For anything it should cite, ask for file:line so the answer can be
  checked.

Pass long briefs on stdin with `-`.

## Running it

Start it under Monitor, always with `--name`, so `follow` can pick it back
up. Names are lowercase letters, digits, `.`, `_` and `-`, and unique per
run.

```bash
pi-delegate --name hosts-coordinator "Which hosts set ... Max 5 lines." 2>&1
```

Set Monitor's `timeout_ms` to the maximum. The run outlives the Monitor, so
on expiry re-arm with:

```bash
pi-delegate follow hosts-coordinator 2>&1
```

- `--edit`: adds bash, edit and write, in a new worktree and branch named
  after the run, off `--base` or the current branch. The caller's checkout
  is never touched.
- `--tmux`: also shows the run in a tmux window, for when the human wants to
  watch. Headless otherwise.
- `PI_DELEGATE_MODEL`, `PI_DELEGATE_TIMEOUT` (default `30m`) override the
  model and wall clock.

Several read-only runs can go at once. Each `--edit` run gets its own
worktree, so those can too.

## Reading the result

The stream ends with one of:

- `DONE tokens=<n> cost=<usd>`, then for `--edit` the worktree's status and
  diffstat against its base, then glm's final message.
- `FAILED exit=<n>` and the tail of pi's stderr. 124 is the timeout, 143 a
  killed run.

Everything a run leaves is under `~/.local/state/pi-delegate/<name>/`:
`events.ndjson` is the full record, `result.md` the final message.

glm's work is a lead, not a fact. Spot-check a couple of the file:line
claims before repeating them. For `--edit`, read the diff before using it:

```bash
git -C <worktree> diff <base>
```

Bring the change over with `git -C <worktree> diff <base> | git apply`, or a
cherry-pick when it committed. Then clean up:

```bash
git worktree remove <worktree> && git branch -D <name>
```

## When it goes wrong

glm can get stuck inside a tool call or emit garbled argument names
(`offsetcko`), which shows up as repeated or odd `tool:` lines, or none at
all. There is no stop command, so set `PI_DELEGATE_TIMEOUT` short for small
jobs. One retry with a tighter brief is worth it; after that, do the job
here.
