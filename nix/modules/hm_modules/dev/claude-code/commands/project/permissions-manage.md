---
allowed-tools: all
argument-hint: [--analyze] [--optimize] [--suggest] [--organize]
description: Analyze and optimize Claude Code permissions across settings files
---

# Manage Permissions

Intelligent Claude Code permission management system that analyzes, optimizes, and organizes permissions across settings.json and settings.local.json. Detects redundancies, suggests consolidations, and helps maintain clean permission configurations for shared team settings.

## Requirements

- Access to .claude/settings.json and .claude/settings.local.json
- Understanding of Claude Code permission patterns
- Ability to analyze wildcard patterns and redundancies
- Knowledge of common tool usage patterns in the project

## Workflow

1. **Load Current Settings**

   - Read .claude/settings.json (shared team settings)
   - Read .claude/settings.local.json (personal settings)
   - Extract permissions arrays and MCP configurations
   - Identify all unique permission patterns

2. **Analyze Permission Patterns**

   - Parse each permission string (e.g., "Bash(git:\*)")
   - Extract tool name and pattern
   - Build hierarchy of permission coverage
   - Identify wildcard patterns and their scope

3. **Detect Redundancies**

   - Find permissions covered by wildcards
     - Example: "Bash(git:_)" covers "Bash(git add:_)", "Bash(git commit:\*)"
   - Identify duplicate permissions across files
   - Find overly specific permissions that could be generalized
   - Detect unused or outdated permission patterns

4. **Categorize Permissions**

   - **Version Control**: git, svn operations
   - **Build Tools**: make, npm, yarn, cargo, etc.
   - **File Operations**: ls, find, grep, cat
   - **Project Scripts**: ./bin/\*, scripts in project
   - **Development Tools**: linters, formatters, test runners
   - **MCP Tools**: mcp\_\_\* prefixed tools
   - **Web Operations**: WebFetch, WebSearch
   - **Other**: uncategorized permissions

5. **Optimization Suggestions**

   - Propose wildcard consolidations
     - Multiple "Bash(git ...)" → "Bash(git:\*)"
     - Multiple "./bin/script" → "Bash(./bin/_:_)"
   - Suggest permission removals (redundant entries)
   - Recommend moving personal → shared permissions
   - Identify overly broad permissions to narrow

6. **Generate Recommendations**

   - Create optimized settings.json configuration
   - List permissions to keep in settings.local.json
   - Provide migration commands/instructions
   - Include MCP server configurations

7. **Report Generation**
   - Summary of current permission state
   - Redundancy analysis with specific examples
   - Optimization opportunities ranked by impact
   - Recommended settings.json content
   - Security considerations for broad permissions

## Success Criteria

- [ ] All permissions analyzed
- [ ] Redundancies identified
- [ ] Categories properly assigned
- [ ] Optimizations suggested
- [ ] Security implications considered
- [ ] Migration path clear
- [ ] MCP settings included
- [ ] Documentation provided

## Optimization Rules

**Wildcard Coverage**:

- "Bash(tool:\*)" covers all "Bash(tool ...)" patterns
- "Bash(./path/_:_)" covers all scripts in that path
- "mcp**server**\*" covers all tools from that MCP server

**Common Consolidations**:

- Git operations → "Bash(git:\*)"
- Project scripts → "Bash(./bin/_:_)"
- Build commands → "Bash(make:_)", "Bash(npm:_)"
- File operations → "Read", "Write", "Edit" (no wildcards needed)

**Security Considerations**:

- Avoid "Bash(\*)" - too permissive
- Prefer specific tool wildcards over broad patterns
- Document why broad permissions are needed
- Regularly review and narrow permissions

## Examples

```bash
# Full permission analysis and optimization
/dev:manage-permissions

# Output includes:
# - Current permission summary
# - Redundancy detection
# - Optimization suggestions
# - Recommended settings.json
```

```bash
# Analyze current permission state only
/dev:manage-permissions --analyze

# Shows:
# - Permissions in settings.json
# - Permissions in settings.local.json
# - Permission overlap analysis
# - Usage statistics
```

```bash
# Focus on optimization suggestions
/dev:manage-permissions --optimize

# Provides:
# - Redundant permissions list
# - Consolidation opportunities
# - Wildcard suggestions
# - Security recommendations
```

```bash
# Generate recommended shared settings
/dev:manage-permissions --suggest

# Creates:
# - Optimized settings.json content
# - Migration instructions
# - Remaining local permissions
# - Implementation guide
```

```bash
# Organize permissions by category
/dev:manage-permissions --organize

# Groups permissions:
# - By tool category
# - By usage frequency
# - By security impact
# - By team vs personal
```
