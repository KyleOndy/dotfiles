---
allowed-tools: Read, Grep, Glob, LSP, AskUserQuestion
argument-hint: [--module module-name] [--focus performance|security|maintainability]
description: Analyze code for refactoring opportunities with automated smell detection
---

# Refactor Analysis

Systematic code refactoring analysis with automated detection of code smells, duplication, and improvement opportunities. Provides actionable recommendations with risk assessment and implementation guidance.

## Requirements

- Access to codebase files and structure
- Static analysis tools configured
- Code complexity metrics available
- Version control history for change patterns

## Workflow

### Initial Setup

**Determine analysis focus:**

If no `--focus` argument was provided, use the AskUserQuestion tool to determine the analysis focus:

**Question:** "Which aspect of the code should I focus the refactoring analysis on?"
**Header:** "Focus Area"
**Options:**

- Label: "All areas (Recommended)"
  Description: "Comprehensive analysis covering code smells, architecture, performance, and maintainability"
- Label: "Performance only"
  Description: "Focus on performance bottlenecks, inefficient algorithms, and optimization opportunities"
- Label: "Security only"
  Description: "Focus on security vulnerabilities, unsafe patterns, and risk mitigation"
- Label: "Maintainability only"
  Description: "Focus on code complexity, test coverage, and documentation quality"
- Label: "Architecture only"
  Description: "Focus on module dependencies, coupling, and design patterns"

**Handle responses:**

- "All areas" → Perform all analysis steps (1-6) below
- "Performance only" → Focus on Performance Analysis (step 3) and relevant recommendations
- "Security only" → Focus on security-related code smells and architecture issues
- "Maintainability only" → Focus on Maintainability Assessment (step 4) and code smells
- "Architecture only" → Focus on Architecture Analysis (step 2)

### Analysis Steps

1. **Code Smell Detection**
   - Identify long methods and large classes
   - Detect duplicate code patterns
   - Find complex conditional logic
   - Spot inappropriate coupling

2. **Architecture Analysis**
   - Review module dependencies
   - Identify circular dependencies
   - Analyze layer violations
   - Check separation of concerns

3. **Performance Analysis**
   - Identify performance bottlenecks
   - Detect inefficient algorithms
   - Find memory usage issues
   - Review database query patterns

4. **Maintainability Assessment**
   - Calculate code complexity metrics
   - Assess test coverage gaps
   - Review documentation quality
   - Analyze change frequency patterns

5. **Refactoring Recommendations**
   - Prioritize refactoring opportunities
   - Assess risk levels for each change
   - Provide step-by-step implementation plans
   - Suggest testing strategies

6. **Impact Analysis**
   - Identify affected components
   - Estimate effort and timeline
   - Calculate risk vs benefit
   - Plan rollout strategy

## Success Criteria

- [ ] All code smells identified
- [ ] Architecture issues documented
- [ ] Performance bottlenecks found
- [ ] Refactoring plan is actionable
- [ ] Risk assessment complete
- [ ] Testing strategy defined
- [ ] Implementation steps clear
- [ ] Impact analysis thorough

## Examples

```bash
# Analyze entire codebase
/dev:refactor-analysis

# Output includes:
# - Code complexity heatmap
# - Duplication report
# - Refactoring opportunities
# - Priority recommendations
```

```bash
# Focus on specific module
/dev:refactor-analysis --module=user-service

# Targeted analysis:
# - Module-specific issues
# - Internal dependencies
# - API boundary analysis
# - Performance characteristics
```

```bash
# Analyze for specific issues
/dev:refactor-analysis --focus=performance,security

# Specialized analysis:
# - Performance bottlenecks
# - Security vulnerabilities
# - Optimization opportunities
# - Risk mitigation strategies
```
