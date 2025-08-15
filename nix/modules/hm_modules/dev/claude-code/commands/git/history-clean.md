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

1. **Run tests to ensure current state is good**

   ```bash
   npm test  # or make test, cargo test, etc.
   ```

2. **Ensure you're not on a shared/protected branch**

   Protected branches (main, master, develop, etc.) should never have their history rewritten.

## Automated Setup and Verification

!`git status`
!`git branch --show-current`

## Initial Setup

1. **Create backup branch automatically**

   ```bash
   BACKUP_BRANCH="backup-$(date +%Y%m%d-%H%M%S)"
   git branch "$BACKUP_BRANCH"
   echo "Created backup branch: $BACKUP_BRANCH"
   ```

2. **Handle uncommitted changes with guided commit**

   ```bash
   # Check for uncommitted changes
   if ! git diff --quiet || ! git diff --cached --quiet; then
     echo "🔍 Detected uncommitted changes. Let's create a commit first."

     # Show current status
     echo "Current git status:"
     git status --short

     # Count and categorize changes
     MODIFIED_FILES=$(git diff --name-only | wc -l)
     STAGED_FILES=$(git diff --cached --name-only | wc -l)
     TOTAL_FILES=$((MODIFIED_FILES + STAGED_FILES))

     # Smart commit message suggestion
     if [ $TOTAL_FILES -le 3 ]; then
       # Few files - suggest descriptive message based on files
       CHANGED_FILES=$(git diff --name-only && git diff --cached --name-only | head -3 | tr '\n' ' ')
       SUGGESTED_MSG="WIP: update $CHANGED_FILES"
     else
       # Many files - generic message
       SUGGESTED_MSG="WIP: save current work before history rewrite"
     fi

     echo "Suggested commit message: $SUGGESTED_MSG"

     # Stage all changes and commit
     git add .
     git commit -m "$SUGGESTED_MSG"

     echo "✅ Created WIP commit. Proceeding with history rewrite..."
   else
     echo "✅ Working directory is clean"
   fi
   ```

## Analysis Phase

1. **Chat History Examination**
   - Summarize current chat history for important context
   - Identify root intentions behind the changes
   - Note any "one-off" quick fixes that should be separate commits
   - Document any experimental changes that should be excluded

2. **Git History Analysis**
   !`git log --oneline main..HEAD`
   !`git log --stat main..HEAD`

   Based on the above output, identify commits that should be:
   - **Squashed together**: Related changes that belong in one commit
   - **Split apart**: Mixed concerns that need separation
   - **Reordered**: Logical sequence improvements
   - **Dropped**: Debugging/temporary commits

## Interactive Rebase Execution

1. **Concrete Rebase Example**

   **Before starting**: Understand the commit order in rebase editor

   ```text
   git log --oneline shows (newest first):
   abc123 fix typo
   def456 WIP: add validation
   ghi789 feat: add login form

   Rebase editor shows (oldest first):
   pick ghi789 feat: add login form
   pick def456 WIP: add validation
   pick abc123 fix typo
   ```

2. **Start Interactive Rebase**

   ```bash
   TARGET_BRANCH="${1:-main}"
   git rebase -i "$TARGET_BRANCH"
   ```

3. **Common Rebase Patterns**

   **Pattern 1: Squash WIP commits**

   ```text
   pick ghi789 feat: add login form
   squash def456 WIP: add validation
   squash abc123 fix typo
   ```

   **Pattern 2: Separate mixed changes with edit**

   ```text
   edit ghi789 feat: add login form + fix bug
   pick def456 WIP: add validation
   ```

   Then when rebase pauses:

   ```bash
   git reset HEAD~1           # Uncommit the mixed changes
   git add login-files        # Stage only login-related files
   git commit -m "feat: add login form"
   git add bug-fix-files      # Stage bug fix files
   git commit -m "fix: resolve navigation issue"
   git rebase --continue
   ```

4. **Handle Each Rebase Step**
   - **For `reword`**: Editor opens → Edit message → Save and close
   - **For `edit`**: Make changes → `git add` → `git commit --amend` → `git rebase --continue`
   - **For `squash`**: Editor opens with combined messages → Edit → Save and close
   - **For conflicts**: Fix files → `git add` → `git rebase --continue`

## Verification and Finalization

1. **Verify Rebase Success**

   ```bash
   git log --oneline "$TARGET_BRANCH..HEAD"  # Show new clean history
   git diff "$BACKUP_BRANCH"                 # Should show no differences
   ```

2. **Final Quality Checks**
   - Each commit should compile and pass tests
   - Commit messages should accurately describe changes
   - No merge conflicts with target branch

## Success Criteria

- [ ] `git diff main` shows same changes as before rewrite
- [ ] Each commit compiles and tests pass
- [ ] Commit messages accurately describe changes
- [ ] No merge conflicts with target branch

## Common Issues & Troubleshooting

### Merge Conflicts During Rebase

```bash
# Fix conflicts in files, then:
git add <conflicted-files>
git rebase --continue
```

### Want to Skip a Problematic Commit

```bash
git rebase --skip  # Skip current commit entirely
```

### Need to Edit a Commit During Rebase

```bash
# When rebase pauses at 'edit' command:
# Make your changes, then:
git add <modified-files>
git commit --amend
git rebase --continue
```

### Accidentally Deleted Important Commit

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

### Example 1: Squashing WIP commits

```text
Before: feat: add login → WIP: fix styling → WIP: add validation → fix typo
After:  feat: add login form with validation and styling
```

### Example 2: Separating mixed changes

```text
Before: add user auth + fix unrelated bug + update docs
After:
- feat: add user authentication system
- fix: resolve navigation bug in sidebar
- docs: update API documentation
```

### Example 3: Removing debug commits

```text
Before: feat: new feature → debug logging → more debug → remove debug
After:  feat: implement new feature functionality
```

## Warnings

⚠️ **NEVER** rewrite history on shared/main branches  
⚠️ **ALWAYS** create backup branch before starting  
⚠️ **VERIFY** tests pass after each major change
