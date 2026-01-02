---
allowed-tools: Read, Write, Edit, Bash(git:*), AskUserQuestion
description: Review last commit and check/update task list for validity
---

# Task Sync

Review the most recent commit and validate that the task list still reflects current reality. This ensures tasks remain relevant and assumptions haven't been invalidated by recent work.

## Workflow

### 1. Check for Recent Commits

First, determine if there are any commits on the current branch since it diverged from main.

Use `git log main..HEAD --oneline` to list commits on the current branch.

If there are no commits yet, skip commit review and proceed to task validation.

### 2. Review Last Commit (if exists)

If commits exist on the current branch, analyze the most recent one using git commands:

- `git log -1 --pretty=format:"%h %s%n%b" HEAD` to show commit message
- `git show --stat HEAD` to show files changed

**Analysis Questions:**

- What was changed in this commit?
- Was this a task from TASKS.md? (Check if task was removed from TASKS.md in the commit)
- Did the changes introduce any new considerations?
- Were there any unexpected complications or learnings?

### 3. Impact on Remaining Tasks

Use the Read tool to read `TASKS.md`.

For each remaining task, consider:

**Dependency Changes:**

- Did the last commit add/change functionality that affects task dependencies?
- Should any tasks be reordered based on what was just completed?

**Assumption Changes:**

- Did the implementation reveal that certain tasks are no longer needed?
- Are there new tasks needed that weren't anticipated?
- Do any task descriptions need updating based on new information?

**Technical Discoveries:**

- Did the last commit reveal constraints or opportunities?
- Are there architectural decisions that impact remaining tasks?

### 4. Check Current Project State

Verify task assumptions still hold by checking relevant files.

Use `git status` to check:

- Are there uncommitted changes that might affect the task list?
- Has work already been started on the next task?

### 5. Update Task List (if needed)

If any of the following are true, update TASKS.md:

**IMPORTANT**: When modifying task headings, preserve any existing status markers like `[IN PROGRESS]` or `[BLOCKED]`. These markers track workflow state and should be maintained unless explicitly changing the status.

**Reorder tasks** if dependencies have changed

```markdown
# Before

## Task B (depends on X)

## Task A (provides X)

# After

## Task A (provides X)

## Task B (depends on X)
```

Example with status markers:

```markdown
# Before

## [BLOCKED] Task B (depends on X)

## Task A (provides X)

# After

## Task A (provides X)

## [BLOCKED] Task B (depends on X)
```

**Remove tasks** that are no longer needed

- Delete the entire task section (heading + context)
- Status markers are removed with the task

**Modify task descriptions** if context has changed

- Update the context to reflect new information
- Clarify scope based on recent learnings
- Preserve status markers in the heading (e.g., keep `[IN PROGRESS]` if present)

**Add new tasks** if gaps were discovered

- Insert in appropriate position based on dependencies
- Include context about why the task is needed
- New tasks typically have no status marker (unless immediately blocked)

**Change status markers** when appropriate

- Add `[BLOCKED]` if task cannot proceed without user input
- Remove `[IN PROGRESS]` if work hasn't actually started yet
- Add `[BLOCKED]` with explanation if dependencies are missing

### 6. Handle Blockers

**If any tasks are blocked:**

Use the AskUserQuestion tool:

**Question:** "I've identified a blocker for the next task. How would you like to proceed?"
**Header:** "Blocked"
**Options:**

- Label: "Provide guidance now"
  Description: "I'll answer the questions/provide the missing information"
- Label: "Skip to different task"
  Description: "Move this task down and work on something else"
- Label: "Mark blocked and stop"
  Description: "Update TASKS.md with [BLOCKED] status and pause work"

**Handle responses:**

- "Provide guidance now" → Wait for user input, then continue workflow
- "Skip to different task" → Reorder TASKS.md and proceed to /task:plan
- "Mark blocked and stop" → Add [BLOCKED] marker and end session

**Blocker Types to Identify:**

- **Missing information**: Task requires clarification or decision
- **External dependency**: Waiting on user input, API access, etc.
- **Technical uncertainty**: Unclear how to implement without research
- **Assumption invalidated**: Core assumption no longer holds

Example of marking a task as blocked:

```markdown
## [BLOCKED] Implement JWT token generation

Need to decide: Which JWT library? Token expiration time? Refresh tokens?
```

### 7. Summary Report

Provide a concise summary:

```text
📋 Task Sync Complete

Last Commit: [hash] [message]
Remaining Tasks: [count]

Changes Made:
- [List any reordering, removals, modifications]
OR
- No changes needed - all tasks remain valid

Status: [Ready for /task:plan | BLOCKED]

Blocking Issues: [if any]
```

If no blockers exist:

```text
✅ Ready to proceed with next task
Run /task:plan to begin deep planning
```

## Example Scenarios

### Scenario 1: Task List is Valid

```text
📋 Task Sync Complete

Last Commit: abc123f feat(auth): add password hashing utility
Remaining Tasks: 6

Changes Made:
- No changes needed - all tasks remain valid

Status: Ready for /task:plan

✅ The next task is:
## Build user registration endpoint
Create POST /api/register endpoint that accepts email/password and creates user records.
```

### Scenario 2: Reordering Needed

```text
📋 Task Sync Complete

Last Commit: def456a feat(db): add email uniqueness constraint
Remaining Tasks: 5

Changes Made:
- Moved "Add duplicate email validation" after "Build registration endpoint"
  (Database now enforces uniqueness, so validation logic simplified)

Status: Ready for /task:plan
```

### Scenario 3: Blocked

```text
📋 Task Sync Complete

Last Commit: ghi789b feat(api): add registration endpoint structure
Remaining Tasks: 4

Status: BLOCKED

Blocking Issue:
The next task requires implementing JWT token generation, but we need to decide:
1. Which JWT library to use? (jsonwebtoken vs jose)
2. What should the token expiration time be?
3. Do we need refresh tokens?

Please provide guidance on these decisions before proceeding.
```

## Error Handling

**If TASKS.md doesn't exist:**

```text
❌ TASKS.md not found

You need to create a task list first.

Run `/task` to see your status and get guidance on next steps.
Likely you need to run `/task:decompose` first.
```

**If no commits on branch:**

```text
ℹ️ No commits yet on this branch

Nothing to sync - no work has been completed yet.

Run `/task` to see your status and suggested next steps.
Likely you need `/task:plan` to start working on the first task.
```

**If uncommitted changes exist:**

```text
⚠️ Uncommitted changes detected

Complete your current work first before syncing.

Run `/task` for guidance - likely you need `/task:done`.
```

## Tips

- **Be thorough**: Really think about whether recent changes affect future work
- **Be honest**: If something's unclear or blocked, say so immediately
- **Be proactive**: Suggest improvements to task descriptions based on learnings
- **Stay focused**: Only update what's actually affected by recent work

---

**Next Steps:**

- If unblocked → Run `/task:plan` to begin working on the next task
- If blocked → Wait for user input to resolve blocker
