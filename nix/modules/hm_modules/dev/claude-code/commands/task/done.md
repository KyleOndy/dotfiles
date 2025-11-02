---
allowed-tools: Read, Write, Edit, Bash(git:*), Bash(make:*), Bash(npm:*), Bash(cargo:*), Bash(pytest:*), Bash(go:*)
description: Review implementation, remove completed task, and create commit
---

# Task Completion

Review the implementation for quality and correctness, remove the completed task from TASKS.md, and create a well-crafted commit with conventional commit format.

## Core Philosophy

Before committing, ensure the solution is:

- **Simple**: Is there a clearer, simpler way to do this?
- **Complete**: Does it fully satisfy the task requirements?
- **Tested**: Are tests written and passing?
- **Clean**: Is the code maintainable and clear?

## Workflow

### 1. Review Implementation Quality

**Check for Simplicity:**

- Is this the simplest solution that works?
- Any unnecessary abstractions or complexity?
- Could this be more explicit/clear?
- Any dead code or commented-out sections to remove?

**Review for Completeness:**

- Does it fully accomplish what the task specified?
- Are all edge cases handled?
- Any missing error handling?
- Documentation needed for complex parts?

**Code Quality Check:**

- Clear, descriptive variable/function names?
- Consistent with existing codebase style?
- No code duplication that should be extracted?

### 2. Verify Tests

**Test Existence:**

Use `git status` to check if test files were created or modified.

**Run Tests:**

Determine the project's test command and run it using the Bash tool:

- For Python: `pytest`
- For Go: `go test ./...`
- For JavaScript/Node: `npm test`
- For Rust: `cargo test`
- For Make-based: `make test`

**Test Quality Check:**

- Do tests cover the core functionality?
- Do tests cover error cases?
- Are test names descriptive?
- Do tests match code complexity? (simple code = simple tests)

**If tests fail:**

1. Show the test failures clearly
2. DO NOT proceed with commit
3. Fix the failures first
4. Return to this command when fixed

### 3. Check for Simpler Approaches

Take a moment to reflect:

**Questions to Ask:**

- Now that you see the full implementation, is there a simpler way?
- Any patterns from the codebase you could have reused better?
- Any over-engineering that snuck in?

**If a simpler approach is apparent:**

1. Explain the simpler approach to the user
2. Ask if they want to refactor before committing
3. Wait for user decision

**If the implementation is good as-is:**

- Proceed to commit preparation

### 4. Prepare Commit

**Read the completed task:**

Use the Read tool to read `TASKS.md` and extract the first task (the one being completed):

```
Task Title: [first heading]
Task Context: [context under first heading]
```

**Review all changes:**

Use git commands to review changes:

- `git status` to see all changed files
- `git diff --cached` if there are staged changes
- `git diff` if there are unstaged changes

**Categorize changes:**

- What files were added?
- What files were modified?
- What was the nature of the changes? (feature, fix, refactor, test, docs, chore)

### 5. Determine Commit Type

**Read user's commit conventions:**

First, check if a git commit template is configured using `git config commit.template`.

**If a template path is returned:**

1. Expand the path (handle `~` if present)
2. Read the template file to understand commit conventions
3. Parse for:
   - Available commit types (feat, fix, chore, etc.)
   - Subject line length limits
   - Capitalization rules
   - Body formatting guidelines

**If no template exists:**
Use conventional commits defaults:

- **feat**: New feature or enhancement
- **fix**: Bug fix
- **refactor**: Code restructuring without behavior change
- **test**: Adding or updating tests
- **docs**: Documentation changes
- **chore**: Build process, dependencies, tooling
- **perf**: Performance improvements
- **style**: Code style changes (formatting, semicolons, etc.)

**Determine scope (optional but recommended):**

- Look at the files changed
- Identify the component/module (e.g., auth, api, ui, db)
- Keep scope concise (one word if possible)

**Follow template guidelines:**

- Subject line length (typically 50-72 characters)
- Capitalization (check template preference)
- Use imperative mood ("add" not "added")
- Explain what and why in body, not how

### 6. Craft Commit Message

**Apply the commit conventions from step 5.**

**Message Structure:**

```
<type>(<scope>): <description>

<body (optional)>

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>
```

**Description Guidelines (follow template if available):**

- Start with lowercase verb (add, fix, update, remove, refactor, etc.)
- Be specific but concise (respect length limits from template)
- Describe WHAT and WHY, not HOW
- Focus on the user-visible or functional change
- Use imperative mood as specified in template

**Body Guidelines (optional, use when needed):**

- Explain the reasoning if not obvious
- Describe any tradeoffs or decisions made
- Reference the task context if helpful
- Respect line wrapping guidelines from template (typically 72 chars)

**Examples:**

Simple feature:

```
feat(auth): add email validation to registration

Validates email format before creating user records. Uses existing
validator utility to maintain consistency across endpoints.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>
```

Bug fix:

```
fix(api): handle null values in user profile endpoint

Previously threw 500 error when optional fields were null. Now returns
empty strings for null values to match API contract.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>
```

Test addition:

```
test(auth): add registration validation test cases

Cover valid emails, invalid formats, missing email, and duplicate
email scenarios. Ensures validation catches common input errors.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>
```

### 7. Update TASKS.md

Remove the completed task from TASKS.md:

Use the Read tool to read `TASKS.md` (if not already read), then remove the first task (heading and its context) entirely. The file should now start with the next task (or be just `# Tasks` if this was the last one).

**Important**: The task heading may contain a status marker (e.g., `## [IN PROGRESS] Task title`). Always remove the entire heading line including any status marker.

Example without status markers:

```markdown
# Before

# Tasks

## Completed task

This task is done.

## Next task

This task is next.

# After

# Tasks

## Next task

This task is next.
```

Example with status markers:

```markdown
# Before

# Tasks

## [IN PROGRESS] Completed task

This task is done.

## Next task

This task is next.

# After

# Tasks

## Next task

This task is next.
```

Note: The next task may or may not have a status marker - preserve it as-is.

### 8. Stage and Commit

**Stage all changes including TASKS.md:**

Use `git add -A` to stage all changes.

**Create commit with crafted message:**

```bash
git commit -m "$(cat <<'EOF'
[commit message here with proper formatting]

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

**Verify commit:**

Use git commands to verify:

- `git log -1 --pretty=format:"%h %s%n%b"` to show the commit message
- `git status` to confirm clean working directory

### 9. Summary

Provide completion summary:

```
✅ Task Completed and Committed

Commit: [hash] [type]([scope]): [description]
Files Changed: [count]
Tests: [Passed/Status]

Remaining Tasks: [count from TASKS.md]

Next Steps:
- Run /task:sync to check if commit affects remaining tasks
- Then run /task:plan to begin next task

[Or if no tasks remain:]
🎉 All tasks completed! Consider:
- Running final test suite
- Updating PLANNING.md with lessons learned
- Creating PR if this is a feature branch
```

## Error Handling

**If tests are failing:**

```
❌ Cannot complete task - tests are failing

Test Failures:
[show failing test output]

Please fix the test failures and run /task:done again when tests pass.
```

**If no changes to commit:**

```text
⚠️ No changes detected

Either the task hasn't been implemented yet, or changes were already committed.
Check: git status

If changes were already committed:
- Run `/task:sync` to update task list
- Skip this /task:done command

If you're unsure what to do, run `/task` for guidance.
```

**If TASKS.md doesn't exist:**

```text
❌ TASKS.md not found

You need to create a task list first.

Run `/task` to see your status and get guidance on next steps.
Likely you need to run `/task:decompose` first.
```

## Tips

- **Don't rush review**: Take time to genuinely assess if there's a simpler way
- **Tests matter**: Never commit without running tests
- **Good commit messages**: Future you will thank present you for clarity
- **Atomic commits**: Each commit should be a complete, working change
- **Remove completed tasks**: Keeps TASKS.md focused on what's left

## Example Complete Flow

```
📋 Implementation Review

✓ Code is simple and clear
✓ Task requirements fully met
✓ Tests written and passing (8 tests, all green)
✓ No simpler approach identified

Completed Task:
## Add email validation to registration endpoint
Validates email format before creating user records.

Changes:
- Modified: src/api/routes/auth.js
- Modified: src/utils/validators.js
- Created: tests/unit/api/registration-validation.test.js

Commit Type: feat(auth)
Description: add email validation to registration

[TASKS.md updated - removed completed task]
[Changes staged and committed]

✅ Task Completed

Commit: a1b2c3d feat(auth): add email validation to registration
Files Changed: 3
Tests: Passed (8/8)
Remaining Tasks: 5

Next: Run /task:sync to continue workflow
```

---

**Next Step:** Run `/task:sync` to check if this commit affects remaining tasks, then `/task:plan` for the next task.
