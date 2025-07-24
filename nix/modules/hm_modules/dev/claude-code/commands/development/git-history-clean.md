---
allowed-tools: all
description: Rewrite git history to ensure clean, logical, and atomic commits with interactive rebase
---

# Git History Clean

**Skill Level:** Intermediate to Advanced  
**Risk Level:** High (destructive operation - backup recommended)

Rewriting git history back to `main` or another target branch to ensure clean, logical, and atomic commits. Common use cases:

- Squash multiple WIP commits into meaningful units
- Separate mixed changes into focused commits
- Fix commit messages that don't reflect actual changes
- Remove debugging commits before merging

## Prerequisites

- Make a commit with any uncommitted changes
- Understanding of git rebase interactive mode
- Familiarity with git reflog for recovery

## Requirements

- No current uncommitted git changes (`git status` should be clean)
- All tests are passing (`npm test`, `make test`, or equivalent)
- Create backup branch: `git branch backup-$(date +%Y%m%d-%H%M%S)`
- Ensure you're not on a shared/protected branch

## Workflow

1. **Chat History Examination**

   - Summarize current chat history for important context
   - Identify root intentions behind the changes
   - Note any "one-off" quick fixes that should be separate commits
   - Document any experimental changes that should be excluded

2. **Git History Analysis**

   - Run `git log --oneline main..HEAD` to see commits to rewrite
   - Run `git log --stat main..HEAD` to see files changed per commit
   - Compare commit messages to actual changes
   - Identify commits that should be:
     - Squashed together (related changes)
     - Split apart (mixed concerns)
     - Reordered (logical sequence)
     - Dropped (debugging/temporary)

3. **Interactive Rebase**

   - Run `git rebase -i main` (or target branch)
   - Use rebase commands:
     - `pick` - keep commit as-is
     - `reword` - change commit message
     - `edit` - pause to modify commit
     - `squash` - combine with previous commit
     - `fixup` - combine with previous, discard message
     - `drop` - remove commit entirely

4. **Create New Logical Commits**
   - Ensure each commit represents one logical change
   - Write clear, descriptive commit messages
   - Make atomic commits (each should compile/work independently)
   - Group related changes together
   - Separate unrelated changes into different commits

## Success Criteria

- [ ] `git diff main` shows same changes as before rewrite
- [ ] Each commit compiles and tests pass
- [ ] Commit messages accurately describe changes
- [ ] No merge conflicts with target branch

## Recovery

If something goes wrong:

- `git reflog` to see recent operations
- `git reset --hard backup-branch-name` to restore
- `git rebase --abort` if currently in rebase

## Examples

**Example 1: Squashing WIP commits**

```
Before: feat: add login → WIP: fix styling → WIP: add validation → fix typo
After:  feat: add login form with validation and styling
```

**Example 2: Separating mixed changes**

```
Before: add user auth + fix unrelated bug + update docs
After:
- feat: add user authentication system
- fix: resolve navigation bug in sidebar
- docs: update API documentation
```

**Example 3: Removing debug commits**

```
Before: feat: new feature → debug logging → more debug → remove debug
After:  feat: implement new feature functionality
```

## Warnings

⚠️ **NEVER** rewrite history on shared/main branches  
⚠️ **ALWAYS** create backup branch before starting  
⚠️ **VERIFY** tests pass after each major change
