---
allowed-tools: Read, Grep, Glob, Bash(git log:*), Bash(git diff:*), AskUserQuestion
argument-hint: [--error error-type] [--context context-area] [--type performance|bug|crash]
description: Debug application errors with guided analysis and systematic resolution
---

# Debug Session

Systematic debugging approach with automated issue detection, root cause analysis, and step-by-step resolution. Combines static analysis, runtime debugging, and systematic problem-solving methodologies.

## Requirements

- Access to application logs and error messages
- Debugging tools configured (debugger, profiler, etc.)
- Test environment or reproduction steps
- Source code access and version control

## Workflow

### Initial Setup

**Determine debug type:**

If no `--type` argument was provided, use the AskUserQuestion tool to determine the debug focus:

**Question:** "What type of issue are you debugging?"
**Header:** "Debug Type"
**Options:**

- Label: "Bug/Error (Recommended)"
  Description: "Application crashes, errors, exceptions, or incorrect behavior"
- Label: "Performance issue"
  Description: "Slow response times, high resource usage, or bottlenecks"
- Label: "Data/Logic issue"
  Description: "Incorrect results, data inconsistencies, or business logic failures"
- Label: "Integration issue"
  Description: "External API failures, database connection issues, or service communication problems"

**Handle responses:**

- "Bug/Error" → Focus on Issue Analysis (step 1), Code Analysis (step 3), and stack trace debugging
- "Performance issue" → Focus on Environment Investigation (step 2), profiling, and bottleneck identification
- "Data/Logic issue" → Focus on Data Analysis (step 4) and input/output validation
- "Integration issue" → Focus on Environment Investigation (step 2) and network/API analysis

### Debug Steps

1. **Issue Analysis**
   - Gather error messages and stack traces
   - Identify reproduction steps
   - Analyze error patterns and frequency
   - Classify issue type and severity

2. **Environment Investigation**
   - Check environment variables and configuration
   - Verify dependency versions
   - Analyze system resources and limits
   - Review recent changes and deployments

3. **Code Analysis**
   - Trace code execution paths
   - Identify potential null pointer/undefined access
   - Check boundary conditions and edge cases
   - Review error handling and logging

4. **Data Analysis**
   - Examine input data and parameters
   - Validate data types and formats
   - Check database state and queries
   - Analyze network requests and responses

5. **Root Cause Identification**
   - Isolate the minimal reproduction case
   - Identify the exact failure point
   - Determine underlying cause
   - Assess impact and affected components

**After identifying root cause:**

Use the AskUserQuestion tool to determine next steps:

**Question:** "Root cause identified. How would you like to proceed?"
**Header:** "Next Steps"
**Options:**

- Label: "Implement fix now (Recommended)"
  Description: "Develop and implement the solution with test cases"
- Label: "Get recommendations only"
  Description: "Provide fix strategy and recommendations without implementing"
- Label: "Continue investigation"
  Description: "Dig deeper into the issue or explore alternative causes"

**Handle responses:**

- "Implement fix now" → Proceed to step 6 (Resolution Strategy) and implement the fix
- "Get recommendations only" → Provide detailed fix strategy and exit
- "Continue investigation" → Return to previous steps for deeper analysis

### Resolution

1. **Resolution Strategy**
   - Develop fix implementation plan
   - Create test cases for the issue
   - Implement monitoring and prevention
   - Document lessons learned

## Success Criteria

- [ ] Issue clearly reproduced
- [ ] Root cause identified
- [ ] Fix strategy defined
- [ ] Test cases created
- [ ] Monitoring implemented
- [ ] Documentation updated
- [ ] Similar issues prevented
- [ ] Knowledge shared with team

## Examples

```bash
# Debug current application error
/dev:debug-session

# Interactive debugging:
# - Error analysis
# - Log investigation
# - Code tracing
# - Solution implementation
```

```bash
# Debug specific error with context
/dev:debug-session --error="NullPointerException" --context="user-login"

# Focused debugging:
# - Specific error type analysis
# - Contextual code review
# - Targeted fix implementation
```

```bash
# Debug performance issue
/dev:debug-session --type=performance --metric=response-time

# Performance debugging:
# - Profiling analysis
# - Bottleneck identification
# - Optimization recommendations
# - Performance testing
```
