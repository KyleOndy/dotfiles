---
allowed-tools: Bash(git:*), Bash(sed:*), Bash(grep:*), Bash(gh api:*), Bash(curl:*), Read, Grep, AskUserQuestion
argument-hint: [--base <ref>]
description: Rebase and tidy unpushed commits without an interactive editor
disable-model-invocation: true
---

# Git History Clean

Tidy unpushed commits on the current branch. `$BASE` is any git ref and
defaults to `main`.

Scope is commits that exist only in this repo. Nothing here is safe on
history someone else has already pulled, and none of it tries to be.

## The two things that actually bite

Claude cannot drive an interactive editor. Every rebase below runs
through `GIT_SEQUENCE_EDITOR`, which pipes the todo list through `sed`
instead of opening `$EDITOR`.

`reword` does not work under `GIT_SEQUENCE_EDITOR`. Git skips the editor
and silently keeps the original message. Use `edit` and then
`git commit --amend`. See the rewrite recipe below.

## Try the simple thing first

For unpushed work most cleanups are a soft reset, not a rebase:

```bash
git reset --soft "$BASE"
git commit -m "feat(scope): the message you actually wanted"
```

That collapses everything since `$BASE` into one commit with the tree
untouched. Reach for rebase only when you need more than one commit out
the far end.

## Setup

```bash
BASE="${1:-main}"
git rev-parse --verify "$BASE" || exit 1
BACKUP="backup-$(date +%Y%m%d-%H%M%S)"
git branch "$BACKUP"
git log --oneline "$BASE..HEAD"
```

Run the reference check below, then show that log and its findings and
confirm with AskUserQuestion before running anything else. The backup
branch is what makes the verification step work, so create it even
though `git reflog` would also get you home.

## Check every reference

A rewrite is the last cheap chance to fix a commit message, so every URL
and SHA in the range gets checked, not just the commits being cleaned:

```bash
for c in $(git rev-list "$BASE..HEAD"); do
  git log -1 --format=%B "$c" |
    grep -oE 'https?://[^] )>"`]+|\b[0-9a-f]{7,40}\b' |
    sed "s|^|$(git rev-parse --short "$c") |"
done
```

Each one must resolve and still say what the message claims:

- A permalink resolves at its ref and its `#L` anchor lands on the code
  the message describes. `gh api "repos/OWNER/REPO/contents/PATH?ref=REF"`
  reaches private repos that curl sees as 404.
- Any other URL returns 2xx. Skip localhost and elided examples.
- A SHA of this repo is reachable from `HEAD`:
  `git merge-base --is-ancestor SHA HEAD`. One held only by the reflog, a
  backup branch or a dangling `wip:` commit dies at the next gc.
- A SHA of another repo is on that repo's remote:
  `git -C OTHER branch -r --contains SHA`. That repo may have been
  cleaned with this same command; its rewritten commit has the same
  `git patch-id --stable`.

The rewrite then changes every SHA from the oldest edited commit to
`HEAD`. A later message citing one of them, as a short SHA or a
permalink, needs the new SHA at its own `edit` stop. The cited commit is
older, so it is already rewritten when the rebase pauses at the citing
one:

```bash
git log --format='%H %s' "$BASE..HEAD" | grep -F 'subject of the cited commit'
```

The old SHAs die with the backup branch, so search every repo that cites
this one before rewriting:

```bash
OLD=$(git rev-list "$BASE..HEAD" | cut -c1-7 | paste -sd'|' -)
git -C OTHER log --all --format='%h %s%n%b' | grep -E "\b($OLD)"
git -C OTHER grep -nE "\b($OLD)" HEAD
```

An unpushed citation there gets re-pointed like one here. A pushed one
can only be fixed by rewriting that repo's pushed history as well, so it
goes into the confirmation as a cost of the rewrite.

## Line numbers are inverted

`git log` prints newest first. The rebase todo list is oldest first. So
the first line of the todo is the OLDEST commit, and `2,$` means "every
commit except the oldest".

```text
git log --oneline        rebase todo
abc123 fix typo          pick ghi789 feat: add login form
def456 WIP: validation   pick def456 WIP: validation
ghi789 feat: add login   pick abc123 fix typo
```

Get this backwards and you squash the wrong end.

## sed vocabulary

Every recipe has the shape
`GIT_SEQUENCE_EDITOR="sed -i <script>" git rebase -i --autostash "$BASE"`.
`--autostash` shelves uncommitted changes and reapplies them after.

| Goal                         | sed script                      |
| ---------------------------- | ------------------------------- |
| squash all but the oldest    | `'2,$ s/^pick/squash/'`         |
| same, but discard messages   | `'2,$ s/^pick/fixup/'`          |
| keep the two oldest separate | `'3,$ s/^pick/squash/'`         |
| drop commits matching a word | `'/^pick.*debug/d'`             |
| drop one commit by sha       | `'/^pick abc123/d'`             |
| pause at one commit          | `'s/^pick abc123/edit abc123/'` |
| squash only the WIP ones     | `'/^pick.*WIP/s/pick/squash/'`  |

Chain several with `-e`.

## Recipes

Squash everything into one commit:

```bash
GIT_SEQUENCE_EDITOR="sed -i '2,$ s/^pick/squash/'" git rebase -i --autostash "$BASE"
```

Autosquash `fixup!` commits. Fully automated, no sed. This is the payoff
for running `git commit --fixup=<sha>` during the work:

```bash
GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash --autostash "$BASE"
```

Drop debug commits:

```bash
GIT_SEQUENCE_EDITOR="sed -i '/^pick.*debug/d'" git rebase -i --autostash "$BASE"
```

Rewrite messages. `reword` is broken here, so mark `edit` and amend at
each pause:

```bash
GIT_SEQUENCE_EDITOR="sed -i -e 's/^pick abc123/edit abc123/' -e 's/^pick def456/edit def456/'" \
  git rebase -i --autostash "$BASE"

git commit --amend -m "chore: update flake.lock inputs"
git rebase --continue
git commit --amend -m "feat(tf): add wolf IP variable for DNS migration"
git rebase --continue
```

To change part of a message and keep the rest, pipe it through `sed`:

```bash
git log -1 --format=%B | sed 's/cfe1f67/b63f350/' | git commit --amend -F -
```

## Picking one

- `fixup!` or `squash!` commits present: autosquash.
- Messages are wrong: edit plus amend.
- One logical change: squash all, or just `reset --soft`.
- Junk commits to remove: drop by pattern.
- Anything else: chain sed scripts by hand.

## After

```bash
git log --oneline "$BASE..HEAD"
git diff "$BACKUP"
```

An empty diff means the rewrite preserved the tree. If it is not empty
the rebase lost something: `git rebase --abort` mid-flight, or
`git reset --hard "$BACKUP"` once it has finished.

Run the reference check again. Every URL and SHA must resolve against
the rewritten history, and no message may still cite a SHA that only
`$BACKUP` holds. Delete the backup branch with `git branch -D "$BACKUP"`
after you have checked.

## References

- [git-rebase, sequence editor](https://git-scm.com/docs/git-rebase#_sequence_editor)
- [git-rebase, --autosquash](https://git-scm.com/docs/git-rebase#Documentation/git-rebase.txt---autosquash)
