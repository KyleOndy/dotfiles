---
description: Investigation and debugging mode - analyze without making changes
---

# Research Mode

Use this skill when the user wants to investigate, debug, or understand without making changes.

## Trigger Phrases

- "debug this"
- "what's going on here?"
- "explain this code"
- "help me understand"
- "/skill:research" or "research mode"

## Core Rule

**NEVER suggest or perform file modifications.** Period.

If you find something that needs fixing:

1. Describe the issue clearly
2. Show the relevant code with file:line citations
3. Explain what the fix would be
4. Ask: "Want me to fix this? (Say 'yes' or '/mode code' to enable edits)"

## Investigation Workflow

### 1. Information Gathering

Use these tools freely:

- `read` - Source code, configs, logs
- `bash` - Run diagnostic commands (grep, find, ps, df, etc.)
- `grep` - Search patterns across files
- `find` - Locate files by name/type

### 2. Present Findings

Structure your response:

```
## Summary
[One sentence: what you found]

## Details
[Specific facts with citations]
- File `src/main.py:L45` defines function X
- Variable Y is initialized at `src/config.py:L12`

## Root Cause (if debugging)
[What you believe is causing the issue]

## Evidence
[Relevant code snippets, error messages, or command output]

## Recommended Next Steps
1. [Option A with tradeoffs]
2. [Option B with tradeoffs]

## To Fix (if applicable)
[Description of what changes would fix this - but don't make them yet]

Want me to proceed with any changes?
```

## Scope Control

**If user says "just fix it" or "do it":**

- Confirm: "Switching to code mode to make changes. Proceed?"
- Then: Switch to "/mode code" or /skill:none and execute

**If user says "stop suggesting fixes":**

- Acknowledge: "Staying in research mode. Will not suggest modifications."
- Continue investigation only

## Special Cases

### Debugging

- Always check logs first (`logs/`, `journalctl`, container logs)
- Look for stack traces, error patterns
- Check recent changes (`git log --oneline -20`)
- Verify environment (versions, env vars, configs)

### Code Review

- Focus on: correctness, security, performance, maintainability
- Cite specific lines
- Distinguish "nitpicks" from "real issues"
- Ask if they want severity ranking

### Architecture Questions

- Draw linkages between components
- Note coupling and boundaries
- Identify tech debt without being prescriptive about fixes

## Escape Hatches

User commands that override research mode:

- "switch to code mode" → Switch to /mode code or exit skill
- "/mode code" → Honor the command
- "I want you to edit" → Confirm, then switch modes
