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

**CRITICAL**: The `reword` command does NOT work with `GIT_SEQUENCE_EDITOR` - git skips the editor and keeps the original message! Use `edit` + `git commit --amend` instead (see Pattern 7).

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

**Determine the base reference:**

The base reference can be any valid git ref:

- Branch names: `main`, `master`, `develop`
- Commit SHAs: `abc123`
- Tags: `v1.0.0`
- Relative refs: `HEAD~3`, `HEAD~N`

Default to `main` if no argument is provided.

**Validate the reference exists:**

Run `git rev-parse --verify "$BASE"` to check if the reference is valid.

- If it fails: Display `Error: '$BASE' is not a valid git reference` and exit
- If it succeeds: Continue to show what will be rebased

**Show what will be rebased:**

Run `git log --oneline "$BASE..HEAD"` to display the commits that will be affected by the rebase.

### 2. Create Backup Branch

**Create a timestamped backup branch:**

Generate a backup branch name using the current date and time in format: `backup-YYYYMMDD-HHMMSS`

Run `git branch "backup-$(date +%Y%m%d-%H%M%S)"` to create the backup branch.

Display: `Created backup branch: [branch_name]`

### 3. Handle Uncommitted Changes

**Option 1 (Recommended): Use --autostash**

The `--autostash` flag (used in all patterns below) automatically stashes uncommitted changes before the rebase and reapplies them afterward. No action needed.

**Option 2: Create a WIP commit**

If you want uncommitted changes to be part of the history:

1. Check for uncommitted changes using `git diff --quiet` and `git diff --cached --quiet`
2. If changes exist:
   - Display: `Uncommitted changes detected. Creating WIP commit...`
   - Run `git add .`
   - Run `git commit -m "WIP: save work before history rewrite"`

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

**Check for fixup!/squash! commits:**

Run `git log --oneline "$BASE..HEAD"` and check if any commit messages start with `fixup!` or `squash!`.

You can pipe to grep: `git log --oneline "$BASE..HEAD" | grep -E "^[a-f0-9]+ (fixup!|squash!)"`

If fixup commits exist, use **Pattern 4 (Autosquash)** below.

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
# WARNING: 'reword' does NOT work with GIT_SEQUENCE_EDITOR!
# Use 'edit' instead - see Pattern 7
sed -i 's/^pick abc123/edit abc123/'

# Drop specific commit by SHA
sed -i '/^pick abc123/d'

# Squash commits with "WIP" in message
sed -i '/^pick.*WIP/s/pick/squash/'
```

### Pattern 7: Rewrite Commit Messages (Programmatic)

**Use when**: You need to change specific commit messages without interactive editing

**CRITICAL**: The `reword` command does NOT work with `GIT_SEQUENCE_EDITOR` - git skips the editor and keeps the original message!

**Solution**: Use `edit` to pause the rebase, then `git commit --amend` to change the message.

```bash
BASE="${1:-main}"

# Step 1: Mark commits for editing
GIT_SEQUENCE_EDITOR="sed -i \
  -e 's/^pick abc123/edit abc123/' \
  -e 's/^pick def456/edit def456/' \
" git rebase -i --autostash "$BASE"

# Step 2: When rebase pauses at each commit, amend and continue
git commit --amend -m "new message for abc123"
git rebase --continue

git commit --amend -m "new message for def456"
git rebase --continue
```

**Example**:

```
Before: abc123 feat(soruce): update all
        def456 prepping dns cutover

After:  abc123 chore: update flake.lock inputs
        def456 feat(tf): add wolf IP variable for DNS migration
```

## Decision Framework

Use this flowchart to choose your pattern:

```
1. Do you have fixup!/squash! commits?
   YES → Use Pattern 4 (Autosquash)
   NO  → Continue to #2

2. Do you need to REWRITE commit messages?
   YES → Use Pattern 7 (Rewrite messages with edit + amend)
   NO  → Continue to #3

3. Do you want ONE final commit?
   YES → Use Pattern 1 (Squash all into one)
   NO  → Continue to #4

4. Do you need to DROP specific commits?
   YES → Use Pattern 3 (Drop by pattern)
   NO  → Continue to #5

5. Do you want to keep first commit message only?
   YES → Use Pattern 5 (Fixup all)
   NO  → Continue to #6

6. Multiple logical commits but need cleanup?
   → Use Pattern 2 (Keep first separate) or Pattern 6 (Custom)

7. Complex restructuring needed?
   → See "Advanced: Manual Rebase" section below
```

## Verification & Finalization

### 1. Verify Rebase Success

**Show the new clean history:**

Run `git log --oneline "$BASE..HEAD"` to display the cleaned-up commit history.

**Verify content is identical:**

Run `git diff "$BACKUP_BRANCH"` to compare the current state with the backup.

- If the diff is empty: The rebase preserved all changes ✅
- If there are differences: Review them carefully to ensure nothing was lost

### 2. Test the Changes

**Run the project's test suite:**

Determine the appropriate test command for the project:

- For JavaScript/Node: `npm test`
- For Rust: `cargo test`
- For Python: `pytest`
- For Go: `go test ./...`
- For Make-based projects: `make test`

Run the tests to ensure nothing broke during the rebase.

### 3. Cleanup Backup (Optional)

**Delete the backup branch:**

Only after verifying everything works!

Run `git branch -d "$BACKUP_BRANCH"` to delete the backup branch.

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

**Current history:**

Run `git log --oneline main..HEAD` to see:

```
abc123 fix typo
def456 WIP: add validation
ghi789 WIP: fix styling
jkl012 feat: add login form
```

**Use Pattern 1: Squash all**

Run the following command:

```bash
GIT_SEQUENCE_EDITOR="sed -i '2,$ s/^pick/squash/'" git rebase -i --autostash main
```

**Result:** One commit with all changes

```
xyz789 feat: add complete login form with validation and styling
```

### Example 2: Removing debug commits

**Current history:**

Run `git log --oneline main..HEAD` to see:

```
abc123 remove debug
def456 add more debug
ghi789 debug: add logging
jkl012 feat: add feature
```

**Use Pattern 3: Drop by pattern**

Run the following command to drop all commits containing "debug":

```bash
GIT_SEQUENCE_EDITOR="sed -i '/^pick.*debug/d'" git rebase -i --autostash main
```

**Result:** Only feature commit remains

```
jkl012 feat: add feature
```

### Example 3: Using autosquash workflow

**During development, mark fixups:**

```bash
git commit -m "feat: add authentication"
```

Later, when you find a typo:

```bash
git add .
git commit --fixup=abc123  # References the auth commit
```

Later, another fix:

```bash
git add .
git commit --fixup=abc123
```

**When ready to clean up:**

Run the following command:

```bash
GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash --autostash main
```

**Result:** All fixups automatically squashed into original commit

```
abc123 feat: add authentication (with all fixes included)
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
reword  # Change commit message (requires interactive editor - humans only!)
edit    # Pause to amend commit (AI agents: use this + git commit --amend)
squash  # Combine with previous, keep both messages
fixup   # Combine with previous, discard this message
drop    # Remove commit entirely
```

**Note for AI Agents**: When using `GIT_SEQUENCE_EDITOR`, the `reword` command does not work - use `edit` instead and run `git commit --amend -m "message"` when the rebase pauses.

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
- Git autosquash workflow: <https://thoughtbot.com/blog/autosquashing-git-commits>
- GIT_SEQUENCE_EDITOR: <https://git-scm.com/docs/git-rebase#_sequence_editor>
