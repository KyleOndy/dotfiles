---
allowed-tools: Read, Write, Glob, AskUserQuestion
description: Parse PLANNING.md and generate structured TASKS.md
---

# Task Decomposition

Parse a freeform planning document and decompose it into a structured, ordered list of granular tasks. Creates TASKS.md in project root with tasks ordered by dependencies.

## Workflow

### 1. Read Planning Document

Use the Read tool to read `PLANNING.md` from the project root to understand the overall goals, features, and context.

### 2. Analyze and Decompose

Based on the planning document:

- **Identify discrete work items** - Break down features/goals into specific, actionable tasks
- **Determine dependencies** - Understand which tasks must be completed before others
- **Ensure granularity** - Each task should be completable in one focused session (1-2 hours)
- **Add context** - Each task should have brief context explaining why it matters

**Key Principles:**

- When in doubt, be MORE granular (easier to combine than split)
- Each task should have a clear completion criteria
- Tasks should be small enough to result in clean, atomic commits
- Include testing tasks explicitly when needed

### 3. Order Tasks by Dependencies

Arrange tasks in execution order:

1. Foundation/infrastructure tasks first
2. Core functionality next
3. Enhancements and integrations after
4. Testing and documentation throughout (not just at end)

### 4. Generate TASKS.md

Create `TASKS.md` in the project root with this format:

```markdown
# Tasks

## First task title

Brief context about why this task matters and what specifically needs to be done.

## Second task title

Context about this task and any relevant details.

## Third task title

More context here.
```

**Format Rules:**

- Use `##` (H2) for each task title
- No checkboxes, dates, or priority markers
- Keep titles clear and action-oriented
- Context should be 1-3 sentences explaining "why" and "what"
- First task is the next task to work on

### 5. Summary

After creating TASKS.md, provide a summary:

- Total number of tasks created
- General categories of work (e.g., "3 implementation tasks, 2 testing tasks, 1 documentation task")
- Any assumptions or decisions made during decomposition
- Suggest running `/task:sync` next to validate the task list

## Example Output Format

```markdown
# Tasks

## Create database schema for user authentication

Set up the users table with email, password_hash, and timestamps. This is foundation for the auth system.

## Implement password hashing utility

Add bcrypt-based password hashing functions for secure storage. Need this before user registration.

## Build user registration endpoint

Create POST /api/register endpoint that accepts email/password and creates user records.

## Add registration input validation

Validate email format, password strength, and check for duplicate users.

## Write unit tests for registration flow

Cover successful registration, duplicate emails, invalid inputs, and password hashing.

## Create login endpoint

Implement POST /api/login with JWT token generation for authenticated users.

## Add authentication middleware

Create middleware to verify JWT tokens on protected routes.

## Write authentication tests

Test login success, invalid credentials, expired tokens, and middleware protection.
```

## Error Handling

**If PLANNING.md doesn't exist:**

```text
❌ PLANNING.md not found

Before running /task:decompose, you need a planning document in the project root.

Options:
1. Create PLANNING.md manually with your high-level plan
2. If you just finished iterating on a plan with Claude, ask Claude to write it to PLANNING.md before exiting
3. Use /task directly - it will guide you through the workflow

Run `/task` to see your current status and suggested next steps.
```

**If TASKS.md already exists:**

Use the AskUserQuestion tool:

**Question:** "TASKS.md already exists. What would you like to do?"
**Header:** "Overwrite?"
**Options:**

- Label: "Replace with new tasks"
  Description: "Overwrite existing TASKS.md with fresh decomposition from PLANNING.md"
- Label: "Keep existing"
  Description: "Cancel and preserve current task list"
- Label: "Append new tasks"
  Description: "Add new tasks from PLANNING.md after existing tasks"

**Handle responses:**

- "Replace with new tasks" → Overwrite TASKS.md with new decomposition
- "Keep existing" → Cancel operation, no changes made
- "Append new tasks" → Parse PLANNING.md and append to existing TASKS.md

## Tips

- **Be specific**: "Add validation" → "Add email format and password strength validation to registration"
- **Include context**: Explain briefly why each task matters or what it enables
- **Think dependencies**: Ensure foundation is built before advanced features
- **Plan for testing**: Don't save all testing for the end
- **Keep it simple**: The format is intentionally minimal to focus on the work

---

**Next Step:** Run `/task:sync` to validate the task list and begin the work cycle.
