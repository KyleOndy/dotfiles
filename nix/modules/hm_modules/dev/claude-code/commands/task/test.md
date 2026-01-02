---
allowed-tools: Read, Bash(pytest:*), Bash(go test:*), Bash(npm test:*), Bash(cargo test:*), Bash(make test:*), Bash(git:*), AskUserQuestion
description: Run tests and verify implementation before commit
---

# Task Testing

Run automated tests and perform manual verification to ensure the implementation works correctly. This command can be run iteratively while fixing issues.

## Core Philosophy

Testing should happen **before** committing. This phase is for:

- Running automated tests multiple times as you fix issues
- Following manual verification steps defined in the plan
- Ensuring everything works before code review
- Iterating quickly without commit pressure

## Workflow

### 1. Check for Work to Test

Use `git status` to verify there are uncommitted changes to test.

**If no changes:**

```text
⚠️ No uncommitted changes detected

Nothing to test yet. Implement the task first, then run /task:test.

Run /task for guidance.
```

**If changes exist:** Proceed to testing.

### 2. Read Current Task

Use the Read tool to read `TASKS.md` from project root.

Extract the first task (the one marked `[IN PROGRESS]` or the first task if no markers).

Display clearly:

```text
🧪 Testing Task:
[Task Title]
[Task Context]
```

### 3. Load Testing Strategy from Plan

**Find the task plan file:**

Use Glob to list files in `.claude/task-plans/` and find the most recent plan file (highest number).

**If plan exists:**

Read the plan file and extract the "Testing Strategy" section (or similar section with automated tests, manual verification, validation commands).

**If no plan exists:**

Generate testing strategy on the fly:

- Detect project type from files (look for package.json, go.mod, requirements.txt, Cargo.toml, etc.)
- Suggest appropriate test commands
- Create basic manual verification checklist based on changed files

### 4. Run Automated Tests

**Detect test command:**

Based on project files and plan:

- Python: `pytest` (with optional coverage)
- Go: `go test ./...`
- JavaScript/Node: `npm test` or `yarn test`
- Rust: `cargo test`
- Make-based: `make test`
- Custom: Use command from plan if specified

**Execute tests:**

Run the test command using Bash tool with appropriate timeout (tests can take time).

**Display results clearly:**

```text
🧪 Running Automated Tests
Command: pytest -v

[test output]

✅ All tests passed (15 passed)
OR
❌ Tests failed (3 failed, 12 passed)

Failed tests:
- test_email_validation: AssertionError
- test_duplicate_check: Expected 400, got 500
- test_edge_case: TypeError
```

### 5. Manual Verification Checklist

**Display manual steps from plan:**

If the plan includes manual verification steps, show them as a checklist:

````text
📋 Manual Verification Steps

From your task plan, please verify:

- [ ] Test registration form with invalid email in browser
- [ ] Verify 400 error response shows correct message
- [ ] Check error displays in UI properly
- [ ] Test with curl command below

Validation Commands:
```bash
curl -X POST http://localhost:5000/api/register \
  -H "Content-Type: application/json" \
  -d '{"email": "invalid", "password": "test"}'
````

Have you completed all manual verification steps?

**If no manual steps in plan:**

Check what was changed:

- If only code/tests changed: "No manual verification needed - code-only changes"
- If UI/API/config changed: Generate sensible manual checks based on files

```text
📋 Manual Verification

Based on your changes, please verify:

- [ ] Test the modified functionality works as expected
- [ ] Check for any unexpected side effects
- [ ] Verify error handling works correctly

Have you completed these verification steps?
```

### 6. Confirm Manual Verification

**If automated tests PASSED:**

Use the AskUserQuestion tool:

**Question:** "Automated tests passed. Have you completed the manual verification steps?"
**Header:** "Manual Tests"
**Options:**

- Label: "Yes, all verified"
  Description: "Manual testing complete - ready to commit"
- Label: "Still testing"
  Description: "I need more time to verify manually"
- Label: "Found issues"
  Description: "Manual testing revealed problems to fix"

**Handle responses:**

- "Yes, all verified" → Proceed to success summary, ready for /task:done
- "Still testing" → Remind them of the checklist, end session
- "Found issues" → Ask what issues they found, note them for fixing

**If automated tests FAILED:**

Skip asking about manual verification and go straight to failure summary.

### 7. Test Results Summary

**If all passed (automated + manual confirmed):**

```text
✅ All Tests Passed

Automated Tests: ✅ 15/15 passed
Manual Verification: ✅ Completed

🎉 Ready for commit!

Next step: Run /task:done to review code quality and create commit
```

**If tests failed:**

```text
❌ Tests Failed

Automated Tests: ❌ 3 failed, 12 passed
Manual Verification: ⏸️  Skipped (fix automated tests first)

Failed tests:
- test_email_validation: AssertionError at line 45
- test_duplicate_check: Expected 400, got 500
- test_edge_case: TypeError in validator

Next steps:
1. Fix the failing tests
2. Run /task:test again (you can run this as many times as needed)

Tip: Focus on one failing test at a time
```

**If automated passed but manual not confirmed:**

```text
⚠️ Testing Incomplete

Automated Tests: ✅ 15/15 passed
Manual Verification: ⏸️  Not completed yet

Please complete the manual verification steps, then run /task:test again.

Or if manual testing found issues:
1. Fix the issues
2. Run /task:test again to verify
```

## Error Handling

**If TASKS.md doesn't exist:**

```text
❌ TASKS.md not found

You need a task list before testing.

Run /task to see your status and guidance.
```

**If no task is marked IN PROGRESS:**

```text
⚠️ No task in progress

The first task in TASKS.md isn't marked [IN PROGRESS].

Did you run /task:plan yet? Run /task for guidance.
```

**If tests command not found:**

```text
❌ Test command not found: pytest

This project may not have tests configured yet.

Options:
1. Install test framework (e.g., pip install pytest)
2. Skip automated tests and focus on manual verification
3. Check if tests use a different command

Run /task:plan to see the testing strategy defined in your plan.
```

## Advanced Usage

**Running specific tests:**

If the project supports it, you can run specific test files or patterns:

```bash
# Python
pytest tests/unit/test_email.py -v

# Go
go test ./pkg/auth/... -v

# JavaScript
npm test -- --testNamePattern="email validation"
```

The command should detect if the user has made changes since last test run and re-run automatically.

## Tips

- **Run often**: Don't wait to fix all issues before running tests again
- **One thing at a time**: Fix one failing test, run `/task:test`, repeat
- **Read error messages**: Test output tells you exactly what's wrong
- **Manual testing matters**: Automated tests can't catch everything
- **No shame in iteration**: Professional developers run tests dozens of times

## Example Complete Flow

**First run (tests fail):**

```text
🧪 Testing Task: Add email validation to registration

🧪 Running Automated Tests
Command: pytest tests/unit/ -v

tests/unit/test_email.py::test_valid_email PASSED
tests/unit/test_email.py::test_invalid_format FAILED
tests/unit/test_email.py::test_missing_email PASSED

❌ Tests Failed (1 failed, 2 passed)

Failed: test_invalid_format
  AssertionError: Expected 400, got 500

Next steps:
1. Fix the validation error handling
2. Run /task:test again
```

**Second run (tests pass):**

```text
🧪 Testing Task: Add email validation to registration

🧪 Running Automated Tests
Command: pytest tests/unit/ -v

tests/unit/test_email.py::test_valid_email PASSED
tests/unit/test_email.py::test_invalid_format PASSED
tests/unit/test_email.py::test_missing_email PASSED

✅ All tests passed (3/3)

📋 Manual Verification Steps
- [ ] Test registration with invalid email in browser
- [ ] Verify error message displays correctly

Have you completed all manual verification steps?
```

### After user confirms manual testing

```text
✅ All Tests Passed

Automated Tests: ✅ 3/3 passed
Manual Verification: ✅ Completed

🎉 Ready for commit!

Next step: Run /task:done to review code quality and create commit
```

---

**Next Step:** When testing is complete, run `/task:done` to review quality and commit.
