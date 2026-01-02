---
allowed-tools: Read, Write, Edit, Bash(npm:*), Bash(yarn:*), Bash(make:*), Bash(pytest:*), Bash(go test:*), Bash(./bin/*:*), AskUserQuestion
argument-hint: [--type api|database|service] [--service service-name]
description: Create comprehensive integration test suite for API endpoints, database interactions, external services, and inter-component communication
---

# Integration Tests

Comprehensive integration test suite creation for API endpoints, database interactions, external services, and inter-component communication. Ensures system components work together correctly in realistic scenarios.

## Requirements

- Integration testing framework configured
- Test database or service mocking available
- API testing tools (REST, GraphQL, etc.)
- External service test environments or mocks

## Workflow

### Initial Setup

**Determine integration test focus:**

If no `--type` argument was provided, use the AskUserQuestion tool:

**Question:** "Which integration test type should I create?"
**Header:** "Test Type"
**Options:**

- Label: "All integration types (Recommended)"
  Description: "Create API, database, and service integration tests"
- Label: "API tests only"
  Description: "Focus on HTTP endpoint and GraphQL testing"
- Label: "Database tests only"
  Description: "Focus on database operations and transactions"
- Label: "Service tests only"
  Description: "Focus on inter-service communication and messaging"

**Handle responses:**

- "All integration types" → Create all test types (steps 3-5)
- "API tests only" → Focus on API Integration Tests (step 3)
- "Database tests only" → Focus on Database Integration Tests (step 4)
- "Service tests only" → Focus on Service Integration Tests (step 5)

### Workflow Steps

1. **Integration Points Analysis**
   - Map service boundaries and interfaces
   - Identify API contracts and schemas
   - Catalog external service dependencies
   - Document data flow between components

2. **Test Environment Setup**
   - Configure test databases and services
   - Set up service mocks and stubs
   - Create test data fixtures
   - Initialize test infrastructure

3. **API Integration Tests**
   - Test HTTP endpoints with various inputs
   - Validate request/response schemas
   - Test authentication and authorization
   - Verify error handling and status codes

4. **Database Integration Tests**
   - Test CRUD operations
   - Validate data consistency
   - Test transaction handling
   - Verify migration scripts

5. **Service Integration Tests**
   - Test inter-service communication
   - Validate message queue operations
   - Test event handling and processing
   - Verify distributed transaction behavior

6. **End-to-End Workflow Tests**
   - Test complete user journeys
   - Validate business process flows
   - Test error recovery scenarios
   - Verify performance under load

## Success Criteria

- [ ] All integration points tested
- [ ] API contracts validated
- [ ] Database operations verified
- [ ] External services tested
- [ ] Error scenarios covered
- [ ] Performance requirements met
- [ ] Test data management working
- [ ] CI/CD integration successful

## Examples

```bash
# Generate integration tests for current feature
/test:integration-tests

# Created test suites:
# - API endpoint tests
# - Database interaction tests
# - External service integration
# - Error handling scenarios
```

```bash
# Focus on specific integration type
/test:integration-tests --type=api

# API-focused testing:
# - REST endpoint validation
# - GraphQL query testing
# - Authentication flows
# - Rate limiting verification
```

```bash
# Test specific service integration
/test:integration-tests --service=payment-gateway

# Service-specific testing:
# - Payment processing flows
# - Error handling scenarios
# - Webhook verification
# - Transaction validation
```
