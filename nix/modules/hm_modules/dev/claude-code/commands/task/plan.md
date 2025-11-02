---
allowed-tools: Read, Grep, Glob, Bash(git:*), Bash(ls:*), Bash(find:*)
description: Deep research and comprehensive planning for next task
---

# Task Planning

Perform comprehensive research and create a detailed execution plan for the next task. This is the "ultrathink" phase where we understand existing patterns, identify dependencies, and determine exactly what needs to be done - nothing more, nothing less.

## Core Philosophy

> "Stop. The simple solution is usually correct."

This planning phase is about understanding the problem deeply enough to implement the simplest solution that works. Avoid over-engineering by:

- Researching existing patterns in the codebase
- Understanding what already exists before adding new code
- Identifying the minimal changes needed
- Considering where the code will live and why

## Workflow

### 1. Read the Next Task

Use the Read tool to read `TASKS.md` from the project root.

Extract the first task (the one right after the `# Tasks` heading).

Display the task clearly:

```text
🎯 Current Task:
[Task Title]
[Task Context]
```

### 2. Research Existing Codebase

This is critical - understand what already exists before planning new code.

**Search for similar patterns:**

- What similar functionality already exists?
- How was it implemented?
- What patterns/conventions are used?

**Search strategies:**

Use these tools to explore the codebase:

- Grep tool to find similar implementations using relevant patterns
- Glob tool to locate files by extension (e.g., `**/*.js`, `**/*.py`)
- Read tool to study existing implementations in detail

**Key questions:**

- Where do similar features live in the codebase?
- What's the existing architecture/structure?
- What libraries/frameworks are already in use?
- What testing patterns are established?

### 3. Identify Files to Change

Based on research, determine:

**Files to Modify:**

- Which existing files need changes?
- What specific functions/sections will change?

**Files to Create:**

- What new files are needed?
- Where should they live in the project structure?
- What should they be named (following existing conventions)?

**Configuration Changes:**

- Any config files to update?
- Any environment variables needed?

### 4. Map Dependencies and Side Effects

**Direct Dependencies:**

- What existing code does this task depend on?
- What functions/modules will be imported/used?

**Side Effects:**

- What other parts of the codebase are affected?
- Which tests need updating?
- Is documentation needed?

**Integration Points:**

- How does this connect to existing features?
- What interfaces/contracts must be honored?

### 5. Determine the Approach

Now that you understand the context, plan the implementation:

**The Simple Solution:**

- What is the most straightforward way to accomplish this?
- Can we reuse existing patterns rather than creating new ones?
- What's the minimal change that satisfies the requirements?

**Implementation Steps:**

1. [Specific step with file reference]
2. [Another specific step]
3. [Testing step]

**Avoid:**

- Creating new abstractions when existing ones work
- Over-generalizing for hypothetical future needs
- Complex patterns when simple functions suffice

### 6. Plan Testing Strategy

**What to Test:**

- Core functionality (happy path)
- Error conditions
- Edge cases that matter for this feature
- Integration points with existing code

**How to Test:**

- Unit tests for pure logic
- Integration tests for database/API interactions
- Match complexity: simple code = simple tests

**Test Files:**

- Where do tests live? (match existing patterns)
- What's the naming convention?
- What testing framework/libraries are used?

### 7. Identify Risks and Unknowns

**Technical Risks:**

- Are there any parts you're uncertain about?
- Any potential performance implications?
- Security considerations?

**Unknowns:**

- Do you need user input on any decisions?
- Are there multiple valid approaches to choose from?
- Any architecture questions?

**If unknowns exist:** Stop and ask the user for guidance before proceeding.

### 8. Present the Plan

Provide a comprehensive but concise plan:

```text
📋 Implementation Plan

## Summary
[1-2 sentence overview of what will be done]

## Research Findings
- [Key existing patterns found]
- [Relevant files/functions identified]
- [Architectural decisions understood]

## Files to Change

### Modify
- `path/to/file1.ext` - [what changes and why]
- `path/to/file2.ext` - [what changes and why]

### Create
- `path/to/newfile.ext` - [purpose and why here]

## Implementation Approach

1. [Specific step referencing actual files/functions]
2. [Another specific step with details]
3. [Testing approach with test file locations]

## Testing Strategy
- [Unit tests to write]
- [Integration tests if needed]
- [How to verify it works]

## Dependencies
- Uses: [existing functions/modules]
- Affects: [other parts of codebase, if any]

## Risks/Considerations
- [Any technical risks]
- [Performance/security notes]
- [Or "None identified" if truly none]

## Questions for User
- [Any decisions needed]
- [Or "None - ready to implement" if clear]
```

### 9. Mark Task as In Progress

After presenting the plan, update TASKS.md to mark the first task as `[IN PROGRESS]`.

Use the Edit tool to:

1. Find the first `##` heading after `# Tasks`
2. If it doesn't already have a status marker, add `[IN PROGRESS]`
3. Preserve any existing status marker

**Examples:**

- `## Add email validation` → `## [IN PROGRESS] Add email validation`
- `## [IN PROGRESS] Add email validation` → Leave unchanged
- `## [BLOCKED] Fix authentication` → Leave unchanged (already has status)

### 10. Save Plan to Task Plans Directory

Create a persistent copy of the plan for future reference.

**Determine plan filename:**

1. Count existing files in `.claude/task-plans/` (if directory exists)
2. Extract task title and create slug (lowercase, hyphens, max 50 chars)
3. Format: `task-[number]-[slug].md`

**Example:** For task "Add email validation to registration endpoint"
→ Filename: `task-001-add-email-validation.md`

**Create the plan file:**

Use the Write tool to create `.claude/task-plans/task-[number]-[slug].md` with this format:

```markdown
# Task [N]: [Full Task Title]

**Created:** [current timestamp]
**Status:** IN PROGRESS

## Task Description

[Full task context from TASKS.md]

## Research Findings

[All research findings from step 2]

## Files to Change

### Modify

- `path/to/file1` - [changes needed]
- `path/to/file2` - [changes needed]

### Create

- `path/to/newfile` - [purpose]

## Implementation Approach

[Step-by-step plan from step 5]

## Testing Strategy

[Testing approach from step 6]

## Dependencies

- Uses: [dependencies]
- Affects: [side effects]

## Risks and Unknowns

[From step 7]

---

Generated by /task:plan
```

**Handle directory creation:**

If `.claude/task-plans/` doesn't exist, create it first before writing the plan file.

### 11. Wait for User Confirmation

After presenting the plan:

- Wait for user to approve or provide feedback
- Be ready to adjust based on user input
- Don't start implementation without confirmation

## Example Plan Output

```text
📋 Implementation Plan

## Summary
Add email validation to user registration endpoint by reusing existing validator utilities and adding new test cases.

## Research Findings
- Found existing email validation in `src/utils/validators.js` using regex pattern
- Registration endpoint lives in `src/api/routes/auth.js`
- Validation middleware pattern used in `src/api/middleware/validate.js`
- Tests follow pattern in `tests/unit/validators.test.js`

## Files to Change

### Modify
- `src/api/routes/auth.js:45` - Add email validation before user creation
- `src/utils/validators.js:12` - Export existing isValidEmail function (currently private)

### Create
- `tests/unit/api/registration-validation.test.js` - New test file for registration validation

## Implementation Approach

1. Update `validators.js` to export `isValidEmail` function
2. Import validator in `auth.js` registration handler
3. Add validation check before database insert (return 400 if invalid)
4. Write tests covering: valid emails, invalid formats, missing email
5. Run existing tests to ensure no regressions

## Testing Strategy
- Unit tests: valid emails (user@example.com), invalid formats (no @, no domain)
- Edge cases: empty string, null, very long emails
- Integration: register endpoint returns 400 for invalid email
- Use existing test utilities in `tests/helpers/`

## Dependencies
- Uses: existing `isValidEmail` from validators.js
- Affects: registration endpoint behavior, error responses

## Risks/Considerations
- Need to preserve existing email validation behavior in other endpoints
- Should return consistent error format (check existing error responses)

## Questions for User
None - ready to implement
```

## Error Handling

**If TASKS.md doesn't exist:**

```text
❌ TASKS.md not found

You need to create a task list before planning.

Run `/task` to see your status and get guidance on next steps.
Likely you need to run `/task:decompose` first.
```

**If TASKS.md is empty or has no tasks:**

```text
✅ All tasks are complete!

There are no remaining tasks to plan.

Run `/task` to see completion status and next steps.
```

**If there are uncommitted changes:**

```text
⚠️ Uncommitted changes detected

You have work in progress. Complete the current task first.

Run `/task` for guidance - likely you need `/task:done`.
```

## Tips

- **Research first**: Never guess what exists - always search and read
- **Be specific**: Reference actual files, functions, line numbers when possible
- **Match patterns**: Follow existing conventions rather than inventing new ones
- **Question complexity**: If the solution feels complex, there's probably a simpler way
- **Ask when uncertain**: Better to ask than to implement the wrong thing

---

**Next Step:** After user approves the plan, begin implementation and testing. When done, run `/task:done`.
