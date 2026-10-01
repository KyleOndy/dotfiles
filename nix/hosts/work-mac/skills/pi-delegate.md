---
name: pi-delegate
description: Hand a well-defined, self-contained job to glm-5.3 on mcloud through a headless pi run, to save Claude tokens. Use for lookups and summaries that mean reading many files, and for mechanical edits with a clear definition of done. Not for design calls, work that needs this conversation's context, or anything touching secrets.
---

# Delegating to pi

`pi-delegate` runs a pi session on `mcloud/zai-org/glm-5.3` in RPC mode.
Every command that waits prints one line per tool call, then the turn's
outcome. The run's own reading never reaches this context, only what it
reports.

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

Run it with Bash `run_in_background`, always with `--name`, and read the
output when the completion notice arrives. Only use Monitor when the user
wants to watch progress, because every `tool:` line then becomes its own
notification and costs a full turn here.

```bash
pi-delegate --name hosts-coordinator "Which hosts set ... Max 5 lines." 2>&1
```

Names are lowercase letters, digits, `.`, `_` and `-`, and unique per run.

- `--edit`: adds bash, edit and write, in a new worktree and branch named
  after the run, off `--base` or the current branch. The caller's checkout
  is never touched. glm can commit there.
- `--tmux`: also shows the run in a tmux window, for when the human wants to
  watch. Headless otherwise.
- `PI_DELEGATE_MODEL`, `PI_DELEGATE_TIMEOUT` (default `30m`, the whole run
  including idle time) and `PI_DELEGATE_IDLE` (default `300` seconds)
  override the model and clocks.

Several runs can go at once. Each `--edit` run gets its own worktree.

## Talking to a run

Once a turn is done, the run stays open for `PI_DELEGATE_IDLE` seconds, in
the same session with everything it has read:

- `pi-delegate send <name> "<message>"`: a follow-up question or a
  correction. It starts the next turn and waits for it, with the same output
  as the first. Sent while a turn is still going, it steers that turn.
  This is the cheap way to ask for more detail, since glm does not re-read
  what it already has.
- `pi-delegate follow <name>`: re-attach to the turn in progress, or reprint
  the last one.
- `pi-delegate stop <name>`: abort and close. Use it on a stuck run instead
  of waiting out the timeout.
- `pi-delegate ls`: every run, `running`, `open` or `exited:<status>`, with
  its turn count.

## Reading the result

The output ends with one of:

- `DONE turn=<n> tokens=<n> cost=<usd>`, then for `--edit` the worktree's
  status and diffstat against its base, then glm's reply, then an `open:`
  line while the run still takes `send`.
- `FAILED turn=<n> exit=<n>`, the reason, and the tail of pi's stderr. 124
  is the timeout, 143 a killed run, 1 an error reply, an aborted turn, or a
  rejected prompt.

`retry:` lines mean mcloud is failing and pi is backing off. A long run of
them is worth a `stop`. `~/.local/state/pi-delegate/<name>/events.ndjson`
is the full record.

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
(`offsetcko`), which shows up as repeated or odd `tool:` lines. `stop` it.
One retry with a tighter brief, or a `send` with the correction, is worth it;
after that, do the job here.
