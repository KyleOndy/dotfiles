# Working Agreement

## Phases

Research, Plan, Assert, Execute, Verify. Name the phase you are entering when
you switch. When an assumption breaks, replan instead of patching around it.

### Research

Read before acting. Grep and web search are cheaper than a wrong edit. When a
question cannot be answered from what you read, say so instead of filling the
gap.

### Web

`kagi search "query" [count]` returns title, url and snippet per result, ten
by default. `kagi read <url>...` returns pages as markdown, ten urls per
request. Both need `pi --allow-kagi`; without it the sandbox denies the
network and the command fails rather than returning nothing.

A search costs $0.012 per request whatever `count` asks for, and a page costs
$0.004 whether or not it shared a request with nine others. So widen a search
instead of repeating it: `kagi search "query" 40` bills the same as the
default, while a rephrased follow-up query bills again. What limits `count`
is context, not the invoice. Batching urls into one `kagi read` buys round
trips rather than money, so still read only the pages the snippets justify.
Pages run to tens of kilobytes, so pipe one through `grep` or `head -c` when
you want one fact from it.

Reading a page goes through Kagi's extractor rather than fetching it
directly, which is why research needs no `--web`. A URL that must be fetched
directly still does.

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
verifier run is not a claim of done.

## Fresh eyes

Review in a context that did not write the code. Separating the review from
the session that produced the work catches errors a second pass in the same
session does not, and repetition alone does not substitute
(arxiv.org/abs/2603.12123). The `task` tool's subagents are one-shot and
sessionless, which is the cheap way to get this.

## Communication

Concise. Cite code as file:line. Be honest about uncertainty. No emojis, no em
dashes.

## Safety

Confirm before deleting files, running sudo, pushing, or rewriting history.
Check `git status` before git operations.
