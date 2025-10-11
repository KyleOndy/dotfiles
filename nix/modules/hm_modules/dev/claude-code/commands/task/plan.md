---
allowed-tools: Read, Grep, Glob, Bash(git:*), Bash(ls:*), Bash(find:*)
description: Deep research and comprehensive planning for next task
---

# Task Planning

Perform comprehensive research and create a detailed execution plan for the next task. This is the "ultrathink" phase where we understand existing patterns, identify dependencies, and determine exactly what needs to be done - nothing more, nothing less.

## Core Philosophy

**"Stop. The simple solution is usually correct."**

This planning phase is about understanding the problem deeply enough to implement the simplest solution that works. Avoid over-engineering by:

- Researching existing patterns in the codebase
- Understanding what already exists before adding new code
- Identifying the minimal changes needed
- Considering where the code will live and why

## Workflow

### 1. Read the Next Task

!`Read(TASKS.md)`

Extract the first task (the one right after the `# Tasks` heading).

Display the task clearly:

```
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
!`Grep(relevant-pattern)` - Find similar implementations
!`Glob(**/*.{extension})` - Locate relevant files
!`Read(file)` - Study existing implementations

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

```
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

### 9. Wait for User Confirmation

After presenting the plan:

- Wait for user to approve or provide feedback
- Be ready to adjust based on user input
- Don't start implementation without confirmation

## Example Plan Output

```
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

## Tips

- **Research first**: Never guess what exists - always search and read
- **Be specific**: Reference actual files, functions, line numbers when possible
- **Match patterns**: Follow existing conventions rather than inventing new ones
- **Question complexity**: If the solution feels complex, there's probably a simpler way
- **Ask when uncertain**: Better to ask than to implement the wrong thing

---

**Next Step:** After user approves the plan, begin implementation and testing. When done, run `/task:done`.
