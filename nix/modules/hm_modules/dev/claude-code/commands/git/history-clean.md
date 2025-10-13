---
allowed-tools: Bash(git:*), Bash(sed:*), Read, Grep
argument-hint: [--base <ref>]
description: AI-friendly git history cleanup with automated rebase patterns
---

# Git History Clean

**Skill Level:** Intermediate to Advanced
**Risk Level:** High (destructive operation - backup recommended)

Clean up git history using AI-friendly automation patterns. Accepts any git ref: branches, commit SHAs, tags, `HEAD~N`, or merge bases.

## 🤖 AI Agent Note

**IMPORTANT**: Claude cannot use interactive editors. This command uses `GIT_SEQUENCE_EDITOR` with `sed` for programmatic rebase automation instead of manual editor interaction.

## Common Use Cases

- Squash multiple WIP commits into meaningful units
- Remove debugging commits before merging
- Drop temporary/experimental commits
- Fix commit messages that don't reflect actual changes
- Clean up fixup!/squash! commits automatically

## Prerequisites & Safety

1. **Ensure you're not on a shared/protected branch**
   - Protected branches (main, master, develop, etc.) should never have their history rewritten
   - Only rebase commits that exist solely in your local repository

2. **Run pre-flight checks**
   !`git status`
   !`git branch --show-current`

## Initial Setup

### 1. Validate Base Reference

```bash
BASE="${1:-main}"  # Accepts: branches, SHAs, tags, HEAD~N, etc.

# Validate the ref exists
if ! git rev-parse --verify "$BASE" >/dev/null 2>&1; then
  echo "Error: '$BASE' is not a valid git reference"
  exit 1
fi

# Show what will be rebased
echo "Commits to be rebased from $BASE:"
git log --oneline "$BASE..HEAD"
```

### 2. Create Backup Branch

```bash
BACKUP_BRANCH="backup-$(date +%Y%m%d-%H%M%S)"
git branch "$BACKUP_BRANCH"
echo "Created backup branch: $BACKUP_BRANCH"
```

### 3. Handle Uncommitted Changes

Git's `--autostash` will automatically handle uncommitted changes:

```bash
# Option 1: Let rebase handle it (recommended)
# The --autostash flag automatically stashes and reapplies changes

# Option 2: Commit changes first (if you want them in history)
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Uncommitted changes detected. Creating WIP commit..."
  git add .
  git commit -m "WIP: save work before history rewrite"
fi
```

## Analysis Phase

### 1. Examine Commit History

Run these commands to understand your commits:

!`git log --oneline $BASE..HEAD`
!`git log --stat $BASE..HEAD`

### 2. Categorize Commits

Based on the output, identify:

- **Squash candidates**: WIP, fixup, typo fixes, related changes
- **Drop candidates**: debug, temporary, experimental commits
- **Reword candidates**: Unclear or inaccurate commit messages
- **Keep separate**: Significant features, bug fixes, refactors

### 3. Check for Fixup Commits

```bash
# Check if you used git commit --fixup during development
git log --oneline "$BASE..HEAD" | grep -E "^[a-f0-9]+ (fixup!|squash!)"
```

If fixup commits exist, use Pattern 4 (Autosquash) below.

## 🚀 Automated Rebase Patterns

Choose the appropriate pattern based on your analysis above.

### Pattern 1: Squash All Commits Into One

**Use when**: All commits represent one logical change

```bash
BASE="${1:-main}"

# Squash everything after the first commit
GIT_SEQUENCE_EDITOR="sed -i '2,$ s/^pick/squash/'" git rebase -i --autostash "$BASE"

# Then edit the combined commit message when prompted
```

**Example**:

```
Before: feat: add login → WIP: fix styling → fix typo → add validation
After:  feat: add complete login form with validation
```

### Pattern 2: Squash All But Keep First Commit Separate

**Use when**: First commit is significant, rest are refinements

```bash
BASE="${1:-main}"

# Keep first commit (pick), squash the rest
GIT_SEQUENCE_EDITOR="sed -i '3,$ s/^pick/squash/'" git rebase -i --autostash "$BASE"
```

**Example**:

```
Before: feat: add login → fix: address review comments → fix: typo → refactor: cleanup
After:  feat: add login
        fix: address review comments and cleanup
```

### Pattern 3: Drop Commits Matching Pattern

**Use when**: Need to remove debug/temporary commits

```bash
BASE="${1:-main}"
PATTERN="debug\|WIP\|temp\|experiment"  # Customize this

# Drop any commits with these keywords in message
GIT_SEQUENCE_EDITOR="sed -i '/^pick.*\($PATTERN\)/d'" git rebase -i --autostash "$BASE"
```

**Example**:

```
Before: feat: add feature → debug: add logging → more debug → feat: polish
After:  feat: add feature → feat: polish
```

### Pattern 4: Autosquash (for fixup!/squash! commits)

**Use when**: You used `git commit --fixup=<sha>` during development

```bash
BASE="${1:-main}"

# Git automatically reorders and squashes fixup!/squash! commits
GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash --autostash "$BASE"
```

This is fully automated - no editor interaction needed!

**Workflow**:

```bash
# During development:
git commit -m "feat: add login"
# ... later, fix something in that commit:
git commit --fixup=abc123

# When cleaning up:
GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash main
```

### Pattern 5: Fixup All (Discard All Messages Except First)

**Use when**: Only the first commit message matters, rest are noise

```bash
BASE="${1:-main}"

# Use fixup (like squash but discards commit messages)
GIT_SEQUENCE_EDITOR="sed -i '2,$ s/^pick/fixup/'" git rebase -i --autostash "$BASE"
```

**Example**:

```
Before: feat: add login → fix whitespace → fix typo → address comments
After:  feat: add login  (other messages discarded)
```

### Pattern 6: Custom Sed Transformation

**Use when**: Complex transformation needed

```bash
BASE="${1:-main}"

# Template for custom sed commands
# Multiple sed commands can be chained with -e
GIT_SEQUENCE_EDITOR="sed -i -e 's/^pick abc123/edit abc123/' -e '/^pick.*debug/d'" \
  git rebase -i --autostash "$BASE"
```

**Common sed operations**:

```bash
# Change specific commit to edit
sed -i 's/^pick abc123/edit abc123/'

# Reword specific commit
sed -i 's/^pick abc123/reword abc123/'

# Drop specific commit by SHA
sed -i '/^pick abc123/d'

# Squash commits with "WIP" in message
sed -i '/^pick.*WIP/s/pick/squash/'

# Change all picks to rewords
sed -i 's/^pick/reword/'
```

## Decision Framework

Use this flowchart to choose your pattern:

```
1. Do you have fixup!/squash! commits?
   YES → Use Pattern 4 (Autosquash)
   NO  → Continue to #2

2. Do you want ONE final commit?
   YES → Use Pattern 1 (Squash all into one)
   NO  → Continue to #3

3. Do you need to DROP specific commits?
   YES → Use Pattern 3 (Drop by pattern)
   NO  → Continue to #4

4. Do you want to keep first commit message only?
   YES → Use Pattern 5 (Fixup all)
   NO  → Continue to #5

5. Multiple logical commits but need cleanup?
   → Use Pattern 2 (Keep first separate) or Pattern 6 (Custom)

6. Complex restructuring needed?
   → See "Advanced: Manual Rebase" section below
```

## Verification & Finalization

### 1. Verify Rebase Success

```bash
# Show new clean history
git log --oneline "$BASE..HEAD"

# Verify content is identical (diff should be empty)
git diff "$BACKUP_BRANCH"

# If diff is empty, the rebase preserved all changes ✅
```

### 2. Test the Changes

```bash
# Run tests to ensure nothing broke
npm test  # or cargo test, pytest, etc.
```

### 3. Cleanup Backup (Optional)

```bash
# Only after verifying everything works!
git branch -d "$BACKUP_BRANCH"
```

## Handling Conflicts

If rebase encounters conflicts:

```bash
# 1. Git will pause and show conflicted files
git status

# 2. Fix conflicts in the files (remove <<<, ===, >>> markers)
# 3. Stage the resolved files
git add <conflicted-files>

# 4. Continue the rebase
git rebase --continue

# If it's too complex:
git rebase --abort  # Start over with different approach
```

## Recovery & Troubleshooting

### Abort Rebase

```bash
git rebase --abort  # Cancel and return to pre-rebase state
```

### Restore from Backup

```bash
git reset --hard "$BACKUP_BRANCH"  # Restore from backup
```

### Find Lost Commits

```bash
git reflog                         # Show all recent operations
git cherry-pick <commit-hash>      # Restore specific commit
```

### Skip Problematic Commit

```bash
git rebase --skip  # Skip current commit entirely (during rebase)
```

## Success Criteria

- [ ] `git diff $BASE` shows same changes as before rewrite
- [ ] Each commit compiles and passes tests
- [ ] Commit messages accurately describe changes
- [ ] No merge conflicts with base branch
- [ ] Backup branch created and verified

## Examples

### Example 1: Squashing WIP commits

```bash
# Current history:
git log --oneline main..HEAD
# abc123 fix typo
# def456 WIP: add validation
# ghi789 WIP: fix styling
# jkl012 feat: add login form

# Use Pattern 1: Squash all
BASE="main"
GIT_SEQUENCE_EDITOR="sed -i '2,$ s/^pick/squash/'" git rebase -i --autostash "$BASE"

# Result: One commit with all changes
# xyz789 feat: add complete login form with validation and styling
```

### Example 2: Removing debug commits

```bash
# Current history:
git log --oneline main..HEAD
# abc123 remove debug
# def456 add more debug
# ghi789 debug: add logging
# jkl012 feat: add feature

# Use Pattern 3: Drop by pattern
BASE="main"
PATTERN="debug"
GIT_SEQUENCE_EDITOR="sed -i '/^pick.*debug/d'" git rebase -i --autostash "$BASE"

# Result: Only feature commit remains
# jkl012 feat: add feature
```

### Example 3: Using autosquash workflow

```bash
# During development, mark fixups:
git commit -m "feat: add authentication"
# ... later, found a typo:
git add .
git commit --fixup=abc123  # References the auth commit

# ... later, another fix:
git add .
git commit --fixup=abc123

# When ready to clean up:
BASE="main"
GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash --autostash "$BASE"

# Result: All fixups automatically squashed into original commit
# abc123 feat: add authentication (with all fixes included)
```

## Warnings

⚠️ **NEVER** rewrite history on shared/main branches
⚠️ **ALWAYS** create backup branch before starting
⚠️ **VERIFY** tests pass after rebase
⚠️ **NEVER** force push to shared branches without team agreement

---

## Advanced: Manual Rebase

For complex scenarios where automation isn't sufficient, you can perform manual interactive rebase. **Note**: This requires human interaction and cannot be performed by AI agents.

### Understanding Commit Order

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

### Manual Rebase Commands

```bash
pick    # Use commit as-is
reword  # Change commit message
edit    # Pause to amend commit
squash  # Combine with previous, keep both messages
fixup   # Combine with previous, discard this message
drop    # Remove commit entirely
```

### Starting Manual Rebase

```bash
BASE="${1:-main}"
git rebase -i --autostash "$BASE"

# This opens an editor - only works for humans, not AI agents
# Edit the file manually, save, and close
```

### Editing a Commit During Rebase

When rebase pauses at an `edit` command:

```bash
# Make your changes
git add <modified-files>
git commit --amend
git rebase --continue
```

### Splitting a Commit

```bash
# When rebase pauses at 'edit':
git reset HEAD~1              # Uncommit
git add <files-for-commit-1>  # Stage first group
git commit -m "First part"
git add <files-for-commit-2>  # Stage second group
git commit -m "Second part"
git rebase --continue
```

## Further Reading

- `git rebase --help` - Official documentation
- `git reflog --help` - Understanding reflog for recovery
- Git autosquash workflow: https://thoughtbot.com/blog/autosquashing-git-commits
- GIT_SEQUENCE_EDITOR: https://git-scm.com/docs/git-rebase#_sequence_editor
