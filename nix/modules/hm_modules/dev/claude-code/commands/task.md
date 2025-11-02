---
allowed-tools: Read, Bash(git:*)
description: Smart context-aware task status and command suggestions
---

# Task Status and Command Suggester

Display current task management status and suggest the most appropriate next command based on git state and TASKS.md.

## Purpose

This command serves as the single entry point to the task management system. Instead of remembering which command to run next, just run `/task` and it will:

- Show your current position in the workflow
- Display the active task (if any)
- Suggest the most logical next command
- Provide quick reference for the workflow

## Workflow

### 1. Gather Git Context

Run git commands to understand current state:

```bash
# Get current branch
git rev-parse --abbrev-ref HEAD

# Get number of commits on this branch (vs main)
# Handle case where main branch doesn't exist
git rev-list --count main..HEAD 2>/dev/null || echo "0"

# Check for uncommitted changes
git status --porcelain

# Get last commit info (if any commits exist)
git log -1 --pretty=format:"%h %s" 2>/dev/null || echo ""
```

**Parse results:**

- Store branch name
- Count commits on branch
- Parse git status to identify staged/unstaged changes
- Store last commit hash and message (if exists)

### 2. Check TASKS.md Status

Read TASKS.md from the project root (if it exists).

**Handle scenarios:**

- **File doesn't exist**: Flag as missing
- **File empty or only has heading**: Flag as no tasks
- **File has tasks**: Parse to extract:
  - Current task (first `##` heading after `# Tasks`)
  - Task context (paragraph(s) after heading)
  - Total task count (count all `##` headings)

**Parsing approach:**

Read line by line:

1. Skip until `# Tasks` heading found
2. Next `##` heading is the current/next task
3. Lines after that heading (until next `##`) are task context
4. Count all `##` headings for total

Extract just the task title from lines like:

- `## Task title` → "Task title"
- `## [IN PROGRESS] Task title` → "[IN PROGRESS] Task title"
- `## [BLOCKED] Task title` → "[BLOCKED] Task title"

### 3. Determine Workflow State

Use decision logic to determine current state:

#### State 1: No TASKS.md

- Condition: TASKS.md file doesn't exist
- Suggest: `/task:decompose`
- Reason: "Create task list from PLANNING.md"

#### State 2: All tasks completed

- Condition: TASKS.md exists but has no task headings
- Suggest: Completion message
- Reason: "All tasks are done!"

#### State 3: Uncommitted changes exist

- Condition: Git status shows modified/added/deleted files
- Suggest: `/task:done`
- Reason: "Review implementation, run tests, and create commit"

#### State 4: Clean state with tasks

- Condition: No uncommitted changes AND tasks exist
- Check if recent commit exists:
  - If yes: Suggest `/task:sync` (validate tasks after commit)
  - If no: Suggest `/task:plan` (research next task)

### 4. Display Status

Present clear, structured output:

```text
📋 Task Management Status
━━━━━━━━━━━━━━━━━━━━━━━━

Git Status:
  Branch: [branch-name]
  Commits: [count] on this branch
  [IF last commit exists: Last: [hash] [message]]

  Working Directory:
  [IF clean: ✅ Clean - no uncommitted changes]
  [IF dirty: ⚠️  Uncommitted changes detected
    - [count] modified files
    - [count] new files]

Task Status:
  [IF no TASKS.md:
    ❌ No TASKS.md found

    Create one with /task:decompose]

  [IF tasks exist:
    Current Task: [task title]
    [First 1-2 lines of task context]

    Remaining: [count] task(s) in TASKS.md]

  [IF all done:
    ✅ All tasks completed!]

━━━━━━━━━━━━━━━━━━━━━━━━
💡 Suggested Next Step
━━━━━━━━━━━━━━━━━━━━━━━━

[SUGGESTED_COMMAND]

[Explanation of why this command is appropriate]

[Additional context or tips based on state]

━━━━━━━━━━━━━━━━━━━━━━━━
🔧 Available Commands
━━━━━━━━━━━━━━━━━━━━━━━━

/task:decompose  - Break down PLANNING.md into ordered tasks
/task:plan       - Deep research and planning for current task
/task:done       - Review implementation, run tests, create commit
/task:sync       - Validate task list after commits

━━━━━━━━━━━━━━━━━━━━━━━━
📖 Quick Workflow Reference
━━━━━━━━━━━━━━━━━━━━━━━━

1. /task:decompose → Generate TASKS.md from PLANNING.md
2. /task:plan → Research and plan first task
3. [Implement] → Write code, run tests locally
4. /task:done → Review quality, commit with tests
5. /task:sync → Validate remaining tasks
6. Repeat steps 2-5 until all tasks complete
```

### 5. Handle Edge Cases

**Not in git repository:**

- Show error: "Not in a git repository"
- Suggest: "Initialize git or navigate to project root"

**On main/master branch:**

- Note in display: "⚠️ Working on main branch"
- Suggest: "Consider creating a feature branch"

**Malformed TASKS.md:**

- Try to extract what you can
- Show warning: "⚠️ TASKS.md may be malformed"
- Still suggest appropriate action

**No PLANNING.md and no TASKS.md:**

- Suggest: "Create PLANNING.md first to outline your work"
- Offer: "Or use /task:decompose with inline planning"

## Example Outputs

### Example 1: Fresh Start

```text
📋 Task Management Status
━━━━━━━━━━━━━━━━━━━━━━━━

Git Status:
  Branch: feature/monitoring-alerts
  Commits: 0 on this branch

  Working Directory:
  ✅ Clean - no uncommitted changes

Task Status:
  ❌ No TASKS.md found

  Create one with /task:decompose

━━━━━━━━━━━━━━━━━━━━━━━━
💡 Suggested Next Step
━━━━━━━━━━━━━━━━━━━━━━━━

/task:decompose

Create TASKS.md from your PLANNING.md file. This will break down your
high-level plan into concrete, dependency-ordered tasks.

First time? Create a PLANNING.md file describing what you want to build,
then run /task:decompose to generate the task list.
```

### Example 2: Ready to Work

```text
📋 Task Management Status
━━━━━━━━━━━━━━━━━━━━━━━━

Git Status:
  Branch: feature/monitoring-alerts
  Commits: 3 on this branch
  Last: fda633e fix(monitoring): adjust alerts for ZFS systems

  Working Directory:
  ✅ Clean - no uncommitted changes

Task Status:
  Current Task: Test alert delivery via email
  Trigger a test alert and confirm email is received at
  kyle@ondy.org with correct formatting and content.

  Remaining: 3 task(s) in TASKS.md

━━━━━━━━━━━━━━━━━━━━━━━━
💡 Suggested Next Step
━━━━━━━━━━━━━━━━━━━━━━━━

/task:plan

Begin deep research and planning for the current task. This will:
- Explore existing codebase patterns
- Identify files to modify
- Plan the implementation approach
- Determine testing strategy

Run this before starting implementation to avoid mistakes.
```

### Example 3: Work in Progress

```text
📋 Task Management Status
━━━━━━━━━━━━━━━━━━━━━━━━

Git Status:
  Branch: feature/monitoring-alerts
  Commits: 4 on this branch
  Last: a1b2c3d test(monitoring): verify email delivery

  Working Directory:
  ⚠️  Uncommitted changes detected
    - 2 modified files
    - 1 new file

Task Status:
  Current Task: Document alerting configuration in CLAUDE.md
  Add section explaining how alerts are configured, how to add
  new alerts, and how to test them.

  Remaining: 2 task(s) in TASKS.md

━━━━━━━━━━━━━━━━━━━━━━━━
💡 Suggested Next Step
━━━━━━━━━━━━━━━━━━━━━━━━

/task:done

You have uncommitted changes. Time to:
1. Review your implementation for simplicity and correctness
2. Run tests to ensure everything works
3. Create a well-crafted commit
4. Remove the completed task from TASKS.md

This command handles all of these steps automatically.
```

### Example 4: All Complete

```text
📋 Task Management Status
━━━━━━━━━━━━━━━━━━━━━━━━

Git Status:
  Branch: feature/monitoring-alerts
  Commits: 7 on this branch
  Last: def789a docs(monitoring): document alerting configuration

  Working Directory:
  ✅ Clean - no uncommitted changes

Task Status:
  ✅ All tasks completed!

━━━━━━━━━━━━━━━━━━━━━━━━
💡 Suggested Next Step
━━━━━━━━━━━━━━━━━━━━━━━━

🎉 Excellent work! All tasks are complete.

Consider these next steps:
- Review all work: git log main..HEAD
- Run full test suite to verify everything
- Create pull request (or merge to main)
- Deploy changes to production

Start a new feature? Create a new PLANNING.md and run /task:decompose
```

## Tips for Best Results

### Start each work session with `/task`

- Quickly orient yourself
- Know exactly what to do next
- Avoid running the wrong command

### Trust the suggestions

- The command analyzes your state
- Suggests the most appropriate next step
- Guides you through the proper workflow

### Use other commands directly when needed

- If you know what you need: run it directly
- If uncertain: run `/task` first for guidance

### Keep TASKS.md clean

- Let the commands manage it
- Manual edits are fine but keep format consistent
- First task is always the current/next task
