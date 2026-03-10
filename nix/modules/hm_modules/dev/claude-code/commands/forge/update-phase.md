---
allowed-tools: Read, Write, Edit, Grep, Glob, Bash(git:*), Bash(ls:*), Bash(find:*), AskUserQuestion
description: Update forge phase README and artifacts after running a phase test
---

# Forge: Update Phase

After running a forge phase test, updates the README with what was proved, what wasn't, and known issues discovered. Optionally surfaces code changes suggested by the test results.

## Workflow

### 1. Locate the Forge Directory

Determine the ticket ID from the current worktree path or branch name:

```bash
git branch --show-current
# e.g. CLIN-742/init -> ticket is CLIN-742
```

The forge scratch directory is at `~/work/tickets/CLIN-<ticket>/forge/`.

Use `ls` to list its contents and identify the highest-numbered `phase_NN/` directory -- that is the phase just completed.

### 2. Read the Current README

Read `~/work/tickets/CLIN-<ticket>/forge/README.md` in full.

Note:

- Which phases already have complete entries
- The current state of the TODO list
- Any pending items marked as open

### 3. Gather Phase Artifacts

For the most recent phase directory, read:

- `test.sh` -- what tests were run
- `validate.py` -- what was validated and what the pass/fail criteria were
- Any recording or output files in `recordings/` or similar runtime artifacts

If runtime artifacts exist (e.g., `recordings/*.json`, `output.txt`), read them to understand actual test outcomes.

Also check for any notes left in the phase directory (e.g., `notes.md`, `results.txt`).

### 4. Identify Updates Needed

Based on the test scripts and artifacts, determine:

**README updates needed:**

- **What Was Proved**: Behaviors confirmed by the test
- **What Was NOT Proved**: Things in scope that weren't tested, or explicitly deferred
- **Known Issues**: Bugs, unexpected behaviors, or limitations discovered
- **TODO updates**: Items to check off, new items to add

**Code feedback (if applicable):**

Search for any error messages, unexpected responses, or edge cases in the recordings that suggest a bug or missing feature in the middleware source. If found, note the file and line where the issue likely lives.

### 5. Draft README Updates

Present the proposed changes as a unified diff or clear before/after for each section:

```
## Proposed README Updates

### Phase NN section (new or updated)

**What Was Proved:**
- <item 1>
- <item 2>

**What Was NOT Proved:**
- <item 1>

**Known Issues:**
- <item 1 -- or "None">

### TODO list changes
- [x] <completed item> (was open)
- [ ] <new item discovered during testing>
```

If no updates are needed for a section, say so explicitly rather than omitting it.

### 6. Confirm and Apply

Use the AskUserQuestion tool:

**Question:** "How should I proceed with these README updates?"
**Header:** "Update Phase README"
**Options:**

- Label: "Apply all updates (Recommended)"
  Description: "Write the proposed changes to README.md"
- Label: "Apply with edits"
  Description: "I'll tell you what to change before writing"
- Label: "Skip README update"
  Description: "Don't modify README.md"

If "Apply all updates": use the Edit tool to apply each change to `README.md`.

If "Apply with edits": ask the user what to change, incorporate the feedback, then apply.

If "Skip README update": acknowledge and exit.

### 7. Surface Code Feedback (Optional)

If the test artifacts revealed potential bugs or missing features in the middleware source, present them:

```
## Code Feedback from Test Results

### Potential Issue: <description>
- **Observed**: <what happened in the test recording>
- **Expected**: <what should have happened>
- **Likely location**: <file:line range>
- **Suggested fix**: <brief description>
```

Do not make code changes automatically. Present findings for the user to act on.
