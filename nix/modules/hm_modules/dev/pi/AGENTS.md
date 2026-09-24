# Working Agreement

## Phases

Research, Plan, Assert, Execute, Verify. Name the phase you are entering when
you switch. When an assumption breaks, replan instead of patching around it.

### Research

Read before acting. Grep and web search are cheaper than a wrong edit. When a
question cannot be answered from what you read, say so instead of filling the
gap.

### Web

`kagi search` and `kagi read` are the research tools, and `pi --allow-kagi`
is what lets them reach the network; without it the sandbox denies the
network and the commands fail rather than returning nothing. Under that flag
their cost model and usage habits arrive in the system prompt with the grant
itself (extensions/grants.ts reading grants/kagi.md), so they are not
repeated here. `--web` reaches kagi.com too, but without that guidance. The
API key is resolved on trex and work-mac only.

### Plan

State the change, the files it touches, and the assumptions it rests on. Stop
for approval on anything structural.

### Assert

Before the first edit, name the command whose output changes when the work is
done, and record what it says now. Where no such command exists, say so and
name what a human will have to look at instead.

An assertion is a command and its current output, not a promise. A plan
carrying no assertion cannot be checked, and neither can the work that comes
out of it.

### Execute

Work the plan in small steps.

### Verify

Run the command from the Assert step and report its real output, failures
included. "Should work" is not a result. A claim of done that names no
verifier run is not a claim of done. Where `.pi/verify.json` or
`~/.pi/agent/verify.json` names a verifier, verify-guard nags until it has
run.

## Fresh eyes

Review in a context that did not write the code. Separating the review from
the session that produced the work catches errors a second pass in the same
session does not, and repetition alone does not substitute
(arxiv.org/abs/2603.12123). A fresh context alone does not remove
self-preference bias, and a `task` with no agent named runs on your own
model. Use `task` with `agent: "critic"`, which is sessionless and pinned to
a different model. It is read-only, so hand it the verifier output rather
than asking it to run anything.

## Communication

Concise. Cite code as file:line. Be honest about uncertainty. No emojis, no em
dashes.

## Safety

Confirm before deleting files, running sudo, pushing, or rewriting history.
Check `git status` before git operations.

Commits land as the wrapper's agent identity (`ai-daemon@noreply.ondy.org`
by default), unsigned, with repo hooks disabled. On main, master or a
detached HEAD the git dirs are read-only, so `git add` and `git commit`
fail; ask the human to start the session on a branch (`wtp`). The human re-authors the work with
`git claim` and signs it with `git adopt`.
