---
allowed-tools: Read, Write, Grep, Glob, Bash(npm test:*), Bash(pytest:*), Bash(go test:*), Bash(cargo test:*), Bash(make test:*), AskUserQuestion
description: Generate comprehensive test suite with unit, integration, and end-to-end tests following testing best practices
---

# Generate Tests

Comprehensive test suite generation with unit, integration, and end-to-end tests. Analyzes existing code patterns and generates thorough test coverage following testing best practices and project conventions.

## Requirements

- Testing framework configured (Jest, Mocha, pytest, Go test, etc.)
- Test utilities and mocking libraries available
- Code coverage tools configured
- CI/CD pipeline supports test execution

## Workflow

### Initial Setup

**Determine test types to generate:**

Use the AskUserQuestion tool to determine which test types should be generated:

**Question:** "Which test types should I generate?"
**Header:** "Test Types"
**Options:**

- Label: "All types (Recommended)"
  Description: "Generate unit, integration, and end-to-end tests for comprehensive coverage"
- Label: "Unit tests only"
  Description: "Generate unit tests for individual functions and methods"
- Label: "Integration tests only"
  Description: "Generate integration tests for component interactions"
- Label: "E2E tests only"
  Description: "Generate end-to-end tests for user workflows"

**Handle responses:**

- "All types" → Generate all test types (steps 3-5)
- "Unit tests only" → Focus on Unit Test Generation (step 3)
- "Integration tests only" → Focus on Integration Test Creation (step 4)
- "E2E tests only" → Focus on End-to-End Test Development (step 5)

### Workflow Steps

1. **Code Analysis**
   - Analyze function signatures and interfaces
   - Identify public APIs and entry points
   - Map dependencies and external services
   - Detect edge cases and error conditions

2. **Test Strategy Planning**
   - Determine test types needed (unit, integration, e2e)
   - Identify testing boundaries and isolation points
   - Plan mock strategies for dependencies
   - Define test data requirements

3. **Unit Test Generation**
   - Generate tests for individual functions
   - Create positive and negative test cases
   - Add boundary condition testing
   - Include error handling verification

4. **Integration Test Creation**
   - Test component interactions
   - Verify API contract compliance
   - Test database operations
   - Validate external service integration

5. **End-to-End Test Development**
   - Create user journey tests
   - Test complete workflows
   - Validate UI interactions
   - Test cross-browser compatibility

**Confirm test file locations:**

Before writing test files, use the AskUserQuestion tool to confirm locations:

**Question:** "Ready to write test files to the project?"
**Header:** "Confirm"
**Options:**

- Label: "Write all test files (Recommended)"
  Description: "Create test files in appropriate test directories"
- Label: "Show test content first"
  Description: "Display generated tests without writing files"
- Label: "Write unit tests only"
  Description: "Create only unit test files (skip integration and e2e)"

**Handle responses:**

- "Write all test files" → Create all generated test files in project
- "Show test content first" → Display test content for review, ask again before writing
- "Write unit tests only" → Create only unit test files

### Infrastructure Setup

1. **Test Infrastructure**
   - Set up test fixtures and data
   - Configure test environment
   - Create test utilities and helpers
   - Set up continuous testing

## Success Criteria

- [ ] All public functions have unit tests
- [ ] Edge cases are covered
- [ ] Error conditions are tested
- [ ] Integration points are validated
- [ ] User workflows are tested
- [ ] Test coverage meets standards
- [ ] Tests are maintainable
- [ ] CI/CD integration works

## Examples

```bash
# Generate tests for current changes
/test:generate-tests

# Generated test types:
# - Unit tests for new functions
# - Integration tests for API changes
# - Updated existing test suites
# - Test data and fixtures
```

```bash
# Generate tests for specific module
/test:generate-tests --module=user-service

# Comprehensive module testing:
# - All service methods tested
# - Database interaction tests
# - External API integration tests
# - Error handling scenarios
```

```bash
# Generate specific test types
/test:generate-tests --types=unit,integration

# Focused test generation:
# - Unit tests only
# - Integration tests only
# - Custom test combinations
```
