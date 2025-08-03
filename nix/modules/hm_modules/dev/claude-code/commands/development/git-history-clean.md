---
allowed-tools: Bash(git:*), Read, LS
argument-hint: [--target-branch branch]
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

- Understanding of git rebase interactive mode
- Familiarity with git reflog for recovery

## Pre-flight Checklist

1. **Commit any uncommitted changes first**

   ```bash
   git add .
   git commit -m "WIP: save current work before history rewrite"
   ```

2. **Verify clean working directory**

   ```bash
   git status  # should show "working tree clean"
   ```

3. **Run tests to ensure current state is good**

   ```bash
   npm test  # or make test, cargo test, etc.
   ```

4. **Create backup branch**

   ```bash
   git branch backup-$(date +%Y%m%d-%H%M%S)
   ```

5. **Ensure you're not on a shared/protected branch**

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

3. **Interactive Rebase Step-by-Step**

   a. **Start the rebase**

   ```bash
   git rebase -i main  # or target branch like HEAD~5
   ```

   b. **Understanding the rebase editor**

   - Commits are listed in **chronological order** (oldest first)
   - This is **opposite** of `git log` (which shows newest first)
   - Each line: `<command> <commit-hash> <commit-message>`

   c. **Available rebase commands**

   - `pick` (p) - use commit as-is
   - `reword` (r) - keep changes, edit commit message
   - `edit` (e) - pause at commit to make changes
   - `squash` (s) - merge into previous commit, combine messages
   - `fixup` (f) - merge into previous commit, discard this message
   - `drop` (d) - remove commit entirely

   d. **Save and execute**

   - Save file and close editor to start rebase
   - Git processes commits in order, following your commands
   - Use `git rebase --abort` if you need to cancel

   e. **Handle interactive prompts**

   - For `reword`: Git opens editor for new commit message
   - For `edit`: Git pauses, make changes, then `git rebase --continue`
   - For `squash`: Git opens editor to combine commit messages

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

## Common Issues & Troubleshooting

**Merge Conflicts During Rebase**

```bash
# Fix conflicts in files, then:
git add <conflicted-files>
git rebase --continue
```

**Want to Skip a Problematic Commit**

```bash
git rebase --skip  # Skip current commit entirely
```

**Need to Edit a Commit During Rebase**

```bash
# When rebase pauses at 'edit' command:
# Make your changes, then:
git add <modified-files>
git commit --amend
git rebase --continue
```

**Accidentally Deleted Important Commit**

```bash
git reflog                    # Find the commit hash
git cherry-pick <commit-hash> # Restore it
```

## Recovery

If something goes wrong:

- `git rebase --abort` - Cancel ongoing rebase (safest option)
- `git reflog` - See recent operations and commit hashes
- `git reset --hard backup-branch-name` - Restore from backup
- `git reset --hard ORIG_HEAD` - Return to pre-rebase state

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
