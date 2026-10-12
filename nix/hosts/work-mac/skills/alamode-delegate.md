---
name: alamode-delegate
description: Hand a well-defined, self-contained job to a cheaper mcloud model through a headless alamode run, to save this conversation's tokens. Use for lookups and summaries that mean reading many files, and for mechanical edits with a clear definition of done. Not for design calls, work that needs this conversation's context, or anything touching secrets.
---

# Delegating to alamode

`alamode-delegate` (also `alamode delegate`) runs an agent in RPC mode on
the `ALAMODE_DELEGATE_MODEL` seat, or the session seat when this host's
seats leave it unset. Every command that waits prints one line per tool
call, then the turn's outcome. The run's own reading never reaches this
context, only what it reports.

## When it pays

Delegate when the reading is large and the answer is small: "which hosts
set X, with file:line", "summarize what each of these 12 files does",
"rename this option everywhere and fix the callers". Keep it here when
the job needs judgment, this conversation's context, or fewer than a
handful of reads, since writing the brief costs about as much as doing
it.

## The brief

The run sees none of this conversation. The brief is its whole world:

- The goal, and the paths to start from.
- What done looks like, and the output shape with a length cap ("max 10
  lines", "a table of file:line and value").
- What to leave alone. For edits, say whether it may commit.
- For anything it should cite, ask for file:line so the answer can be
  verified without re-reading.

## Commands

```sh
alamode-delegate --name web-research "brief"   # new run, waits for it
alamode-delegate --edit --name renamer "brief" # mutation tools on
alamode-delegate follow web-research           # wait again (timeout: 1800s)
alamode-delegate status web-research           # state, last tool, outcome
alamode-delegate stop web-research             # interrupt a run
alamode-delegate ls                            # every recorded run
```

Inside a coordinator session the run joins that coordinator and
`--grant` is refused; standalone, `--grant=--allow-nix` style bootstrap
grants start a private coordinator for the run. Runs and their
credentials are recorded under `~/.local/state/alamode/delegates/`, so
a closed shell does not orphan them.

Send follow-up work with `send`, steer mid-turn with `steer`, answer a
dialog with `answer <id> <value>`, and close without losing the
workspace with `close`. A run that outlives its wait window keeps
going; `follow` re-attaches.
