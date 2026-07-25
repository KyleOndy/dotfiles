---
allowed-tools: Bash(git:*), Bash(sed:*), Read, Grep, AskUserQuestion
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

Show that log and confirm with AskUserQuestion before running anything
below. The backup branch is what makes the verification step work, so
create it even though `git reflog` would also get you home.

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
`git reset --hard "$BACKUP"` once it has finished. Delete the backup
branch with `git branch -D "$BACKUP"` after you have checked.

## References

- [git-rebase, sequence editor](https://git-scm.com/docs/git-rebase#_sequence_editor)
- [git-rebase, --autosquash](https://git-scm.com/docs/git-rebase#Documentation/git-rebase.txt---autosquash)
