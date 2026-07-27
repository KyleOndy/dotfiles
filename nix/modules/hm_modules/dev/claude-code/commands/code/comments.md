---
allowed-tools: Bash(git:*), Read, Grep, Glob, Edit, AskUserQuestion
argument-hint: [path] [--all]
description: Strip narration and redundancy from comments in the working diff
disable-model-invocation: true
---

# Comment Cleanup

Apply the code-comments skill to code that is already written. Read that
skill first; this command is only the procedure for running it over
existing files.

## Scope

Default to the working diff. Comments that predate the current change are
not in scope, because touching them turns a focused diff into a review
problem.

```bash
git diff --stat
git diff
git diff --cached
```

Widen only when `$ARGUMENTS` names a path or passes `--all`. For a named
path, read the whole file. For `--all`, confirm with AskUserQuestion first
and show the file count, because the diff will be large and the change
touches code nobody asked about.

## Pass 1: delete

Remove, without asking:

- Commented-out code.
- Comments that restate the line below them.
- Comments built from the words already in the identifier they sit on.
- Change markers: `NEW:`, `UPDATED:`, `FIXED:`, `WAS:`.
- Phase banners over code that does not need signposting.

Keep, without asking: `TODO`, `FIXME`, tool directives
(`shellcheck disable`, `eslint-disable`, `ts-ignore`, `prettier-ignore`),
and any comment holding open an otherwise empty or invalid block.

## Pass 2: rewrite

Narration comments get rewritten, not deleted, when they contain a real
reason. The reason is worth keeping; the framing is what is wrong.

```
# BAD   updated to poll every 30s because the old interval missed spikes
# GOOD  the UPS reports at 30s intervals; polling slower aliases the spikes
```

If the comment narrates an edit and contains no reason, delete it.

## Pass 3: what is missing

The pass everyone skips, and the reason a cleanup can leave code worse
than it found it. Scan the same scope for constraints that deserve a
comment and do not have one:

- A magic number whose units or origin are not stated.
- A boundary where inclusive and exclusive both look plausible.
- A resource with no stated owner.
- A workaround with no reference to the thing it works around.
- An ordering dependency that is load-bearing and invisible.

Add those. A cleanup that only subtracts has removed information from the
repo.

## Verify

```bash
git diff
```

Confirm the diff touches comments only. Any change to executable code, to
formatting away from a moved comment, or to a generated file is a bug in
this pass: revert it.

If a language toolchain is configured, run its formatter and linter over
the touched files. Removing a comment can change line wrapping.

## Report

State the counts plainly: how many comments were deleted, how many
rewritten, how many added. Name any comment that was kept despite looking
redundant, and why.
